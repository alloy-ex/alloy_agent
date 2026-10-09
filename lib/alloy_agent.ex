defmodule AlloyAgent do
  @moduledoc """
  Supervised OTP runtime for [Alloy](https://hex.pm/packages/alloy).

  `alloy_agent` wraps Alloy's loop in a GenServer that holds conversation
  state, handles async dispatch with backpressure, broadcasts results
  over PubSub, and ships default memory stores. Use it when you want an
  agent running in your supervision tree; use plain `Alloy.run/2` when
  you want the loop as a pure function.

  ## Quick start

      {:ok, pid} = AlloyAgent.start_link(
        provider: {Alloy.Provider.Anthropic, api_key: key, model: "claude-sonnet-5-5"},
        tools: [Alloy.Tool.Core.Read, Alloy.Tool.Core.Write],
        system_prompt: "You are a helpful assistant."
      )

      {:ok, result} = AlloyAgent.chat(pid, "Read mix.exs and tell me the version")

  ## Division of responsibility

  - **Alloy** owns the protocol: loop, providers, tools, memory
    behaviour, compaction mechanism. Pure functions. Use
    `Alloy.run/2` directly when you don't need process ownership.
  - **AlloyAgent** owns the runtime: supervised process, session state,
    PubSub broadcast, backpressure, default memory stores. Elixir has
    OTP — use it.

  The functions here delegate to `AlloyAgent.Server`, which documents
  the options and the full client API.
  """

  alias AlloyAgent.{Server, Session}

  @type result :: Alloy.Result.t()

  @doc """
  Start a supervised, persistent agent process. Delegates to
  `AlloyAgent.Server.start_link/1`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  defdelegate start_link(opts), to: Server

  @doc """
  Send a message and wait for the agent to finish its loop. See
  `AlloyAgent.Server.chat/3`.
  """
  @spec chat(GenServer.server(), String.t(), keyword()) ::
          {:ok, result()} | {:error, result()} | {:error, :busy}
  defdelegate chat(server, message, opts \\ []), to: Server

  @doc """
  Stream text deltas from the agent as they arrive. See
  `AlloyAgent.Server.stream_chat/4`.
  """
  @spec stream_chat(GenServer.server(), String.t(), (String.t() -> term()), keyword()) ::
          {:ok, result()} | {:error, result()} | {:error, :busy}
  defdelegate stream_chat(server, message, on_chunk, opts \\ []), to: Server

  @doc """
  Fire a non-blocking async request; the result is delivered via PubSub.
  See `AlloyAgent.Server.send_message/3`.
  """
  @spec send_message(GenServer.server(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, :busy | :queue_full | :no_pubsub}
  defdelegate send_message(server, message, opts \\ []), to: Server

  @doc """
  Cancel an async request by `request_id`. See
  `AlloyAgent.Server.cancel_request/2`.
  """
  @spec cancel_request(GenServer.server(), binary()) :: :ok | {:error, :not_found}
  defdelegate cancel_request(server, request_id), to: Server

  @doc """
  Return the full conversation history.
  """
  @spec messages(GenServer.server()) :: [Alloy.Message.t()]
  defdelegate messages(server), to: Server

  @doc """
  Return accumulated token usage across all turns.
  """
  @spec usage(GenServer.server()) :: Alloy.Usage.t()
  defdelegate usage(server), to: Server

  @doc """
  Clear conversation history. Config, tools and usage are preserved.
  """
  @spec reset(GenServer.server()) :: :ok | {:error, :busy}
  defdelegate reset(server), to: Server

  @doc """
  Switch the provider mid-session. See `AlloyAgent.Server.set_model/2`.
  """
  @spec set_model(GenServer.server(), keyword()) :: :ok | {:error, :busy}
  defdelegate set_model(server, provider_opts), to: Server

  @doc """
  Export the current conversation as a serializable `AlloyAgent.Session`.
  """
  @spec export_session(GenServer.server()) :: Session.t()
  defdelegate export_session(server), to: Server

  @doc """
  Health summary map for the agent process.
  """
  @spec health(GenServer.server()) :: Server.health()
  defdelegate health(server), to: Server

  @doc """
  Stop the agent process.
  """
  @spec stop(GenServer.server()) :: :ok
  defdelegate stop(server), to: Server
end
