defmodule AlloyAgent.Server do
  @moduledoc """
  OTP-backed persistent agent process.

  Wraps Alloy's stateless loop (`Alloy.Agent.Turn.run_loop/2`) in a
  GenServer so the agent can hold conversation history across multiple
  calls, be supervised, and run concurrently with other agents.

  ## Usage

      {:ok, pid} = AlloyAgent.Server.start_link(
        provider: {Alloy.Provider.Anthropic, api_key: "sk-ant-...", model: "claude-sonnet-5-5"},
        tools: [Alloy.Tool.Core.Read, Alloy.Tool.Core.Bash],
        system_prompt: "You are a helpful assistant."
      )

      {:ok, r1} = AlloyAgent.Server.chat(pid, "List the files in this project")
      {:ok, r2} = AlloyAgent.Server.chat(pid, "Now read mix.exs")
      IO.puts(r2.text)

      AlloyAgent.Server.stop(pid)

  ## Options

  The server keeps these options for itself:

  - `:name` - register the process under a name (see `GenServer.start_link/3`)
  - `:messages` - conversation history to start from, such as the
    `:messages` of an exported `AlloyAgent.Session` (default: `[]`)
  - `:pubsub` - the name of a running `Phoenix.PubSub`. Required for
    `send_message/3`; results are broadcast on `"agent:<session id>:responses"`
    (default: `nil`)
  - `:subscribe` - PubSub topics to subscribe to at start. A
    `{:agent_event, message}` broadcast on one of them runs `message` as
    an async request. Requires `:pubsub` (default: `[]`)
  - `:max_pending` - how many `send_message/3` requests may queue while
    one runs (default: `0`, which rejects them with `{:error, :busy}`)
  - `:on_shutdown` - a 1-arity function called with the exported
    `AlloyAgent.Session` when the agent stops (default: `nil`)

  Every other option configures the loop and is passed to
  `Alloy.Agent.Config.from_opts/1`, so it accepts the options
  `Alloy.run/2` documents (`:provider`, `:tools`, `:system_prompt`,
  `:middleware`, `:timeout_ms`, `:context`, ...). Invalid options raise
  `ArgumentError` from `start_link/1`.

  `:session_start` and `:session_end` middleware hooks run when the
  agent starts and stops. Setting `:session_id` in `:context` (from the
  options or in `:session_start` middleware) fixes the id used for the
  PubSub topic and the exported session.

  ## Supervision

      children = [
        {AlloyAgent.Server, [
          name: :my_agent,
          provider: {Alloy.Provider.Anthropic, api_key: System.get_env("ANTHROPIC_API_KEY"), model: "claude-sonnet-5-5"}
        ]}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)
  """

  use GenServer

  alias Alloy.Agent.{Config, State, Turn}
  alias Alloy.{Message, Middleware, Result, Usage}
  alias AlloyAgent.Session

  require Logger

  # :phoenix_pubsub is an optional dependency; start_link/1 checks it is
  # loaded before :pubsub can be used, so it must not warn at compile time.
  @compile {:no_warn_undefined, Phoenix.PubSub}

  # Options the server owns. Alloy's Config.from_opts/1 rejects keys it
  # does not know, so these must never reach it.
  @runtime_defaults [messages: [], pubsub: nil, subscribe: [], max_pending: 0, on_shutdown: nil]
  @runtime_keys Keyword.keys(@runtime_defaults)
  @runtime_expected %{
    messages: "a list of Alloy.Message structs",
    pubsub: "the name of a Phoenix.PubSub server",
    subscribe: "a list of topic strings",
    max_pending: "a non-negative integer",
    on_shutdown: "a 1-arity function or nil"
  }

  # A synchronous chat may still be finishing its last tool round or
  # building its result after the loop's provider deadline, so callers wait
  # a little longer than :timeout_ms before giving up.
  @call_timeout_margin_ms 10_000
  @default_call_timeout_ms struct(Config).timeout_ms + @call_timeout_margin_ms

  @enforce_keys [:agent]
  defstruct [
    :agent,
    pubsub: nil,
    subscribe: [],
    max_pending: 0,
    on_shutdown: nil,
    current_task: nil,
    pending_requests: :queue.new()
  ]

  @type result :: Result.t()

  @typedoc """
  The summary `health/1` returns.
  """
  @type health :: %{
          status: State.status(),
          turns: non_neg_integer(),
          message_count: non_neg_integer(),
          usage: Usage.t(),
          uptime_ms: integer(),
          busy: boolean(),
          pending_count: non_neg_integer(),
          max_pending: non_neg_integer()
        }

  @typep async_task :: %{ref: reference(), pid: pid(), request_id: String.t()}

  @typep t :: %__MODULE__{
           agent: State.t(),
           pubsub: atom() | nil,
           subscribe: [String.t()],
           max_pending: non_neg_integer(),
           on_shutdown: (Session.t() -> term()) | nil,
           current_task: async_task() | nil,
           pending_requests: :queue.queue({String.t(), String.t()})
         }

  # ── Client API ────────────────────────────────────────────────────────────

  @doc """
  Start a supervised, persistent agent process.

  See the module docs for the options. Raises `ArgumentError` when an
  option is invalid.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    {runtime, agent_opts} = Keyword.split(opts, @runtime_keys)

    runtime =
      @runtime_defaults
      |> Keyword.merge(runtime)
      |> Map.new(fn {key, value} -> {key, validate_runtime!(key, value)} end)
      |> validate_subscribe_needs_pubsub!()

    GenServer.start_link(__MODULE__, {Config.from_opts(agent_opts), runtime}, gen_opts)
  end

  @doc """
  Send a message and wait for the agent to finish its full loop.

  Blocks until the model reaches `end_turn` (including all tool calls).
  Conversation history is preserved for subsequent calls.

  The result is tagged like `Alloy.run/2` (see `Alloy.Result.wrap/1`):
  `{:ok, result}` for `:completed` and `:max_turns`, `{:error, result}`
  otherwise. Returns `{:error, :busy}` while an async request runs.

  The loop runs inside the server process, so every other call to this
  agent, including `health/1` and `cancel_request/2`, waits until it
  finishes. Use `send_message/3` when the agent must stay responsive.

  ## Options

    - `:timeout` - GenServer call timeout in milliseconds (default: the
      agent's `:timeout_ms` plus #{div(@call_timeout_margin_ms, 1_000)} seconds; see
      `default_call_timeout/1`). A caller that gives up earlier does not
      stop the run, which still commits its messages to the history.
  """
  @spec chat(GenServer.server(), String.t(), keyword()) ::
          {:ok, result()} | {:error, result()} | {:error, :busy}
  def chat(server, message, opts \\ []) when is_binary(message) do
    timeout = Keyword.get_lazy(opts, :timeout, fn -> default_call_timeout(server) end)
    GenServer.call(server, {:chat, message}, timeout)
  end

  @doc """
  The call timeout `chat/3` and `stream_chat/4` use when `:timeout` is not
  given: the agent's `:timeout_ms` plus a #{div(@call_timeout_margin_ms, 1_000)}-second margin, so a
  caller does not give up on a turn that is still running and will still
  commit to the history.

  Waits for a `chat/3` already running on this agent, for at most the
  default agent's timeout plus the margin.
  """
  @spec default_call_timeout(GenServer.server()) :: pos_integer()
  def default_call_timeout(server) do
    GenServer.call(server, :default_call_timeout, @default_call_timeout_ms)
  end

  @doc """
  Return the full conversation message history.

  While an async request from `send_message/3` runs, this includes its
  user message; the reply appears when it completes.
  """
  @spec messages(GenServer.server()) :: [Message.t()]
  def messages(server) do
    GenServer.call(server, :messages)
  end

  @doc """
  Return accumulated token usage across all turns.
  """
  @spec usage(GenServer.server()) :: Usage.t()
  def usage(server) do
    GenServer.call(server, :usage)
  end

  @doc """
  Clear conversation history. Config, tools and accumulated usage are
  preserved.

  Returns `{:error, :busy}` while an async request from `send_message/3` runs.
  """
  @spec reset(GenServer.server()) :: :ok | {:error, :busy}
  def reset(server) do
    GenServer.call(server, :reset)
  end

  @doc """
  Switch the provider (and its config) mid-session.

  `provider_opts` must hold a `:provider`, in the same format as the
  `:provider` option of `start_link/1`. Conversation history, tools,
  system prompt, and all other config fields are preserved.

  ## Examples

      Server.set_model(pid, provider: {Alloy.Provider.Anthropic, api_key: key, model: "claude-haiku-4-5"})
      Server.set_model(pid, provider: Alloy.Provider.OpenAI)

  Returns `{:error, :busy}` while an async request from `send_message/3` runs.
  """
  @spec set_model(GenServer.server(), keyword()) :: :ok | {:error, :busy}
  def set_model(server, provider_opts) when is_list(provider_opts) do
    GenServer.call(server, {:set_model, Keyword.fetch!(provider_opts, :provider)})
  end

  @doc """
  Send a message with streaming. Calls `on_chunk` for each text delta.
  Returns the same result shape as `chat/3`.

  ## Options

    - `:timeout` - GenServer call timeout in milliseconds (default: the
      agent's `:timeout_ms` plus a margin, as for `chat/3`).
    - `:on_event` - a 1-arity function called with each `Alloy.Events`
      envelope of this run.
  """
  @spec stream_chat(GenServer.server(), String.t(), (String.t() -> term()), keyword()) ::
          {:ok, result()} | {:error, result()} | {:error, :busy}
  def stream_chat(server, message, on_chunk, opts \\ [])
      when is_binary(message) and is_function(on_chunk, 1) do
    timeout = Keyword.get_lazy(opts, :timeout, fn -> default_call_timeout(server) end)
    stream_opts = Keyword.drop(opts, [:timeout])

    case Keyword.get(stream_opts, :on_event) do
      nil -> :ok
      f when is_function(f, 1) -> :ok
      bad -> raise ArgumentError, "on_event must be a 1-arity function, got: #{inspect(bad)}"
    end

    GenServer.call(server, {:stream_chat, message, on_chunk, stream_opts}, timeout)
  end

  @doc """
  Send a message to the agent without blocking the caller.

  Returns `{:ok, request_id}` immediately. The agent runs its full Turn loop
  in a supervised Task, then broadcasts the result via PubSub to
  `"agent:<id>:responses"` as `{:agent_response, result}` where `result`
  includes a `:request_id` field matching the returned ID. `<id>` is the
  `:id` of `export_session/1`.

  Backpressure behavior:

  - If no Turn is running, the request starts immediately.
  - If a Turn is running and `:max_pending > 0`, the request is queued.
  - If the queue is full, returns `{:error, :queue_full}`.
  - If `:max_pending == 0`, returns `{:error, :busy}` while running.

  Returns `{:error, :no_pubsub}` if the agent was started without a `:pubsub`
  option — without PubSub there is no way to receive results.

  ## Options

    - `:request_id` - supply your own correlation ID (binary). Defaults to
      a random URL-safe ID.

  ## Example

      {:ok, agent} = AlloyAgent.Server.start_link(
        provider: {...},
        pubsub: MyApp.PubSub
      )

      %{id: session_id} = AlloyAgent.Server.export_session(agent)
      Phoenix.PubSub.subscribe(MyApp.PubSub, "agent:\#{session_id}:responses")

      {:ok, req_id} = AlloyAgent.Server.send_message(agent, "Summarise the logs")

      receive do
        {:agent_response, %{request_id: ^req_id, text: text}} -> IO.puts(text)
      end
  """
  @spec send_message(GenServer.server(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, :busy | :queue_full | :no_pubsub}
  def send_message(server, message, opts \\ []) when is_binary(message) do
    request_id = Keyword.get_lazy(opts, :request_id, &generate_request_id/0)
    GenServer.call(server, {:send_message, message, request_id}, 30_000)
  end

  @doc """
  Cancel an async request by `request_id`.

  If the request is currently running, the active task is terminated.
  If the request is queued, it is removed from the queue.

  When cancelled, the server broadcasts an `{:agent_response, result}` payload
  with `status: :error`, `error: :cancelled`, the matching `:request_id`,
  and `cancelled_phase: :running | :queued`.

  Only `send_message/3` requests can be cancelled. A synchronous `chat/3`
  or `stream_chat/4` runs inside the server process, so this call waits
  until it finishes.
  """
  @spec cancel_request(GenServer.server(), binary()) :: :ok | {:error, :not_found}
  def cancel_request(server, request_id) when is_binary(request_id) do
    GenServer.call(server, {:cancel_request, request_id})
  end

  @doc """
  Stop the agent process.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  end

  @doc """
  Export the current conversation as a serializable Session struct.

  While an async request from `send_message/3` runs, the exported session
  includes its user message but not the reply.
  """
  @spec export_session(GenServer.server()) :: Session.t()
  def export_session(server) do
    GenServer.call(server, :export_session)
  end

  @doc """
  Returns a health summary map for the agent process.

  Answers immediately while an async `send_message/3` turn runs, but waits
  behind a synchronous `chat/3` or `stream_chat/4`, which run inside the
  server process; it exits if that takes longer than 5 seconds.
  """
  @spec health(GenServer.server()) :: health()
  def health(server) do
    GenServer.call(server, :health, 5_000)
  end

  # ── Server Callbacks ──────────────────────────────────────────────────────

  @impl GenServer
  def init({%Config{} = config, runtime}) do
    Process.flag(:trap_exit, true)

    case Middleware.run(:session_start, State.init(config, runtime.messages)) do
      {:halted, reason} ->
        {:stop, {:middleware_halted, reason}}

      %State{} = agent ->
        server = struct!(__MODULE__, runtime |> Map.delete(:messages) |> Map.put(:agent, agent))
        :ok = subscribe(server)
        {:ok, server}
    end
  end

  @impl GenServer
  def terminate(_reason, %__MODULE__{} = server) do
    # Kill any running async Turn task — prevents orphaned tasks after shutdown.
    :ok = stop_current_task(server.current_task)
    agent = run_session_end(server.agent)
    run_on_shutdown(server.on_shutdown, agent)
  end

  # Reject synchronous chat while an async Turn is in flight — prevents state clobbering.
  @impl GenServer
  def handle_call({:chat, _message}, _from, %__MODULE__{current_task: %{}} = server) do
    {:reply, {:error, :busy}, server}
  end

  @impl GenServer
  def handle_call({:chat, message}, _from, %__MODULE__{} = server) do
    {reply, agent} = run_sync(server.agent, message, [])
    {:reply, reply, %{server | agent: agent}}
  end

  # Reject synchronous stream_chat while an async Turn is in flight.
  @impl GenServer
  def handle_call(
        {:stream_chat, _message, _on_chunk, _stream_opts},
        _from,
        %__MODULE__{current_task: %{}} = server
      ) do
    {:reply, {:error, :busy}, server}
  end

  @impl GenServer
  def handle_call({:stream_chat, message, on_chunk, stream_opts}, _from, %__MODULE__{} = server) do
    turn_opts = Keyword.merge(stream_opts, streaming: true, on_chunk: on_chunk)
    {reply, agent} = run_sync(server.agent, message, turn_opts)
    {:reply, reply, %{server | agent: agent}}
  end

  @impl GenServer
  def handle_call(:default_call_timeout, _from, %__MODULE__{agent: agent} = server) do
    {:reply, agent.config.timeout_ms + @call_timeout_margin_ms, server}
  end

  @impl GenServer
  def handle_call(:messages, _from, %__MODULE__{agent: agent} = server) do
    {:reply, State.messages(agent), server}
  end

  @impl GenServer
  def handle_call(:usage, _from, %__MODULE__{agent: agent} = server) do
    {:reply, agent.usage, server}
  end

  # Reject reset while an async Turn is in flight — prevents state clobbering.
  @impl GenServer
  def handle_call(:reset, _from, %__MODULE__{current_task: %{}} = server) do
    {:reply, {:error, :busy}, server}
  end

  @impl GenServer
  def handle_call(:reset, _from, %__MODULE__{agent: agent} = server) do
    {:reply, :ok, %{server | agent: reset_for_new_run(%{agent | messages: []})}}
  end

  # Reject set_model while an async Turn is in flight — prevents state clobbering.
  @impl GenServer
  def handle_call({:set_model, _provider}, _from, %__MODULE__{current_task: %{}} = server) do
    {:reply, {:error, :busy}, server}
  end

  @impl GenServer
  def handle_call({:set_model, provider}, _from, %__MODULE__{agent: agent} = server) do
    agent = %{agent | config: Config.with_provider(agent.config, provider)}
    {:reply, :ok, %{server | agent: agent}}
  end

  @impl GenServer
  def handle_call(:export_session, _from, %__MODULE__{agent: agent} = server) do
    {:reply, build_export_session(agent), server}
  end

  @impl GenServer
  def handle_call(:health, _from, %__MODULE__{} = server) do
    {:reply, build_health(server), server}
  end

  # Reject if PubSub is not configured — caller would wait forever for a broadcast.
  @impl GenServer
  def handle_call({:send_message, _, _}, _from, %__MODULE__{pubsub: nil} = server) do
    {:reply, {:error, :no_pubsub}, server}
  end

  @impl GenServer
  def handle_call({:send_message, message, request_id}, _from, %__MODULE__{} = server) do
    cond do
      server.current_task == nil ->
        {:reply, {:ok, request_id}, start_async_turn(server, message, request_id)}

      :queue.len(server.pending_requests) < server.max_pending ->
        pending = :queue.in({message, request_id}, server.pending_requests)
        {:reply, {:ok, request_id}, %{server | pending_requests: pending}}

      server.max_pending == 0 ->
        {:reply, {:error, :busy}, server}

      true ->
        {:reply, {:error, :queue_full}, server}
    end
  end

  @impl GenServer
  def handle_call(
        {:cancel_request, request_id},
        _from,
        %__MODULE__{current_task: %{request_id: request_id} = task} = server
      ) do
    case Task.Supervisor.terminate_child(AlloyAgent.TaskSupervisor, task.pid) do
      :ok ->
        Process.demonitor(task.ref, [:flush])
        server = fail_current_task(server, :cancelled)
        broadcast_cancelled(server, request_id, :running)
        {:reply, :ok, maybe_start_next_pending(server)}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, server}
    end
  end

  @impl GenServer
  def handle_call({:cancel_request, request_id}, _from, %__MODULE__{} = server) do
    case remove_pending_request(server, request_id) do
      {:ok, server} ->
        broadcast_cancelled(server, request_id, :queued)
        {:reply, :ok, server}

      :not_found ->
        {:reply, {:error, :not_found}, server}
    end
  end

  # Drop agent_event while an async Turn is in flight — prevents concurrent Turns.
  @impl GenServer
  def handle_info({:agent_event, _message}, %__MODULE__{current_task: %{}} = server) do
    Logger.warning("[AlloyAgent] Dropping agent_event — async Turn already in progress")
    {:noreply, server}
  end

  @impl GenServer
  def handle_info({:agent_event, message}, %__MODULE__{} = server) when is_binary(message) do
    {:noreply, start_async_turn(server, message, generate_request_id())}
  end

  # Task completed — broadcast the result and keep the turn's final state,
  # including its status and turn count, until the next run resets them.
  @impl GenServer
  def handle_info({ref, %State{} = final}, %__MODULE__{current_task: %{ref: ref} = task} = server) do
    Process.demonitor(ref, [:flush])
    result = Result.from_state(final)
    broadcast_response(server.pubsub, final, %{result | request_id: task.request_id})

    {:noreply, maybe_start_next_pending(%{server | agent: final, current_task: nil})}
  end

  # Task crashed — broadcast the error, free the agent so it can recover.
  @impl GenServer
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %__MODULE__{current_task: %{ref: ref} = task} = server
      ) do
    Logger.error(
      "[AlloyAgent] Async Turn crashed (request_id=#{inspect(task.request_id)}): #{inspect(reason)}"
    )

    server = fail_current_task(server, reason)
    result = Result.from_state(server.agent)
    broadcast_response(server.pubsub, server.agent, %{result | request_id: task.request_id})
    {:noreply, maybe_start_next_pending(server)}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, :normal}, server) do
    # Normal exits from linked helpers (e.g., the process that called start_link)
    # are expected and should not stop the agent.
    {:noreply, server}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, reason}, server) do
    {:stop, reason, server}
  end

  @impl GenServer
  def handle_info(msg, server) do
    Logger.debug("[AlloyAgent] Unexpected message: #{inspect(msg)}")
    {:noreply, server}
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp validate_runtime!(:messages, messages) when is_list(messages) do
    if Enum.all?(messages, &is_struct(&1, Message)),
      do: messages,
      else: invalid_runtime!(:messages, messages)
  end

  defp validate_runtime!(:pubsub, nil), do: nil

  defp validate_runtime!(:pubsub, pubsub) when is_atom(pubsub) do
    if Code.ensure_loaded?(Phoenix.PubSub) do
      pubsub
    else
      raise ArgumentError,
            ":pubsub is set but :phoenix_pubsub is not available. " <>
              "Add {:phoenix_pubsub, \"~> 2.1\"} to your mix.exs dependencies."
    end
  end

  defp validate_runtime!(:subscribe, topics) when is_list(topics) do
    if Enum.all?(topics, &is_binary/1), do: topics, else: invalid_runtime!(:subscribe, topics)
  end

  defp validate_runtime!(:max_pending, max) when is_integer(max) and max >= 0, do: max
  defp validate_runtime!(:on_shutdown, nil), do: nil
  defp validate_runtime!(:on_shutdown, fun) when is_function(fun, 1), do: fun
  defp validate_runtime!(key, value), do: invalid_runtime!(key, value)

  defp invalid_runtime!(key, value) do
    raise ArgumentError,
          "#{inspect(key)} must be #{Map.fetch!(@runtime_expected, key)}, got: #{inspect(value)}"
  end

  defp validate_subscribe_needs_pubsub!(%{subscribe: [_ | _], pubsub: nil}) do
    raise ArgumentError, ":subscribe needs :pubsub, the PubSub to subscribe on"
  end

  defp validate_subscribe_needs_pubsub!(runtime), do: runtime

  defp subscribe(%__MODULE__{pubsub: nil}), do: :ok

  defp subscribe(%__MODULE__{pubsub: pubsub, subscribe: topics}) do
    Enum.each(topics, fn topic ->
      case Phoenix.PubSub.subscribe(pubsub, topic) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[AlloyAgent] Failed to subscribe to PubSub topic #{inspect(topic)}: #{inspect(reason)}"
          )
      end
    end)
  end

  defp run_session_end(%State{} = agent) do
    case Middleware.run(:session_end, agent) do
      {:halted, reason} ->
        Logger.warning(
          "[AlloyAgent] :session_end middleware halted during shutdown (#{inspect(reason)})"
        )

        agent

      %State{} = agent ->
        agent
    end
  end

  defp run_on_shutdown(nil, _agent), do: :ok

  # on_shutdown is the caller's code running inside terminate/2. Whatever
  # it raises, throws or exits with, the agent must still finish stopping
  # with its own reason, so the failure is logged rather than re-raised.
  defp run_on_shutdown(on_shutdown, %State{} = agent) do
    _ = on_shutdown.(build_export_session(agent))
    :ok
  catch
    kind, reason ->
      Logger.warning(
        "[AlloyAgent] on_shutdown callback failed:\n" <>
          Exception.format(kind, reason, __STACKTRACE__)
      )
  end

  defp stop_current_task(nil), do: :ok

  defp stop_current_task(%{pid: task_pid}) do
    # terminate_child/2 may return {:error, :not_found} if the Task already
    # finished between the GenServer receiving :stop and terminate/2 running.
    # This is safe to ignore — the Task is gone either way.
    _ = Task.Supervisor.terminate_child(AlloyAgent.TaskSupervisor, task_pid)
    :ok
  end

  defp run_sync(%State{} = agent, message, turn_opts) do
    final = agent |> begin_run(message) |> Turn.run_loop(turn_opts)

    # Keep messages but reset loop counters for the next call.
    {final |> Result.from_state() |> Result.wrap(), reset_for_new_run(final)}
  end

  defp begin_run(%State{} = agent, message) do
    agent = agent |> State.append_messages([Message.user(message)]) |> reset_for_new_run()
    %{agent | status: :running}
  end

  @spec start_async_turn(t(), String.t(), String.t()) :: t()
  defp start_async_turn(%__MODULE__{agent: agent} = server, message, request_id)
       when is_binary(message) and is_binary(request_id) do
    turn_state = begin_run(agent, message)

    task =
      Task.Supervisor.async_nolink(AlloyAgent.TaskSupervisor, fn ->
        Turn.run_loop(turn_state, event_correlation_id: request_id)
      end)

    current_task = %{ref: task.ref, pid: task.pid, request_id: request_id}
    %{server | agent: turn_state, current_task: current_task}
  end

  @spec fail_current_task(t(), term()) :: t()
  defp fail_current_task(%__MODULE__{agent: agent} = server, reason) do
    %{server | agent: %{agent | status: :error, error: reason}, current_task: nil}
  end

  @spec maybe_start_next_pending(t()) :: t()
  defp maybe_start_next_pending(%__MODULE__{current_task: nil} = server) do
    case :queue.out(server.pending_requests) do
      {:empty, _} ->
        server

      {{:value, {message, request_id}}, rest} ->
        start_async_turn(%{server | pending_requests: rest}, message, request_id)
    end
  end

  defp remove_pending_request(%__MODULE__{} = server, request_id) when is_binary(request_id) do
    items = :queue.to_list(server.pending_requests)

    case Enum.reject(items, fn {_msg, rid} -> rid == request_id end) do
      ^items -> :not_found
      filtered -> {:ok, %{server | pending_requests: :queue.from_list(filtered)}}
    end
  end

  defp broadcast_cancelled(%__MODULE__{agent: agent, pubsub: pubsub}, request_id, phase) do
    result =
      agent
      |> Result.from_state()
      |> Map.merge(%{
        status: :error,
        error: :cancelled,
        request_id: request_id,
        cancelled_phase: phase
      })

    broadcast_response(pubsub, agent, result)
  end

  # An {:agent_event, _} sent straight to the process runs without a PubSub.
  defp broadcast_response(nil, _agent, _result), do: :ok

  defp broadcast_response(pubsub, %State{} = agent, result) do
    topic = "agent:#{effective_session_id(agent)}:responses"

    case Phoenix.PubSub.broadcast(pubsub, topic, {:agent_response, result}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[AlloyAgent] PubSub broadcast failed on #{inspect(topic)}: #{inspect(reason)}"
        )
    end
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp reset_for_new_run(%State{} = agent) do
    %{
      agent
      | turn: 0,
        status: :idle,
        error: nil,
        stop_reason: nil,
        tool_calls: [],
        run_metadata: %{}
    }
  end

  defp build_health(%__MODULE__{agent: agent} = server) do
    %{
      status: agent.status,
      turns: agent.turn,
      message_count: length(State.messages(agent)),
      usage: agent.usage,
      uptime_ms: System.monotonic_time(:millisecond) - (agent.started_at || 0),
      busy: server.current_task != nil,
      pending_count: :queue.len(server.pending_requests),
      max_pending: server.max_pending
    }
  end

  # Returns the canonical "effective session ID" used consistently for both
  # PubSub broadcast topics and the exported Session.id.
  #
  # Precedence: context[:session_id] (set by middleware) > agent_id (stable UUID).
  # Using it for both guarantees that subscribers using the exported
  # session ID always receive results on the correct topic.
  defp effective_session_id(%State{} = agent) do
    Map.get(agent.config.context, :session_id) || agent.agent_id
  end

  defp build_export_session(%State{} = agent) do
    Session.new(
      id: effective_session_id(agent),
      messages: State.messages(agent),
      usage: agent.usage,
      metadata: %{
        status: agent.status,
        turns: agent.turn,
        provider: agent.config.provider
      }
    )
  end
end
