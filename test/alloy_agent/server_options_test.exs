defmodule AlloyAgent.ServerOptionsTest do
  use ExUnit.Case, async: true

  alias Alloy.Message
  alias Alloy.Provider.Test, as: TestProvider
  alias AlloyAgent.Server

  defp start_provider(responses) do
    {:ok, pid} = TestProvider.start_link(responses)
    pid
  end

  defp opts(provider_pid, overrides \\ []) do
    Keyword.merge([provider: {TestProvider, agent_pid: provider_pid}], overrides)
  end

  defp start_pubsub(_ctx) do
    name = :"test_pubsub_opts_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: name})
    {:ok, pubsub: name}
  end

  describe "runtime options" do
    setup :start_pubsub

    test "stay with the server and never reach Alloy's config", %{pubsub: pubsub} do
      on_shutdown = fn _session -> :ok end

      {:ok, agent} =
        Server.start_link(
          opts(start_provider([]),
            pubsub: pubsub,
            subscribe: ["tasks"],
            max_pending: 3,
            on_shutdown: on_shutdown,
            messages: [Message.user("earlier"), Message.assistant("reply")]
          )
        )

      server = :sys.get_state(agent)

      assert %{pubsub: ^pubsub, subscribe: ["tasks"], max_pending: 3} = server
      assert server.on_shutdown == on_shutdown

      # Alloy 0.13's Config has none of these fields and 0.12's defaults
      # them, so a leaked option shows up as its value here.
      for {key, leaked} <- [pubsub: pubsub, subscribe: ["tasks"], max_pending: 3] do
        refute Map.get(server.agent.config, key) == leaked, "#{key} reached Alloy's config"
      end

      refute Map.get(server.agent.config, :on_shutdown) == on_shutdown
    end

    test ":messages seeds the conversation history" do
      history = [Message.user("earlier"), Message.assistant("reply")]
      pid = start_provider([TestProvider.text_response("next")])

      {:ok, agent} = Server.start_link(opts(pid, messages: history))
      assert Server.messages(agent) == history

      {:ok, _} = Server.chat(agent, "continue")
      assert length(Server.messages(agent)) == 4
    end

    test "loop options still configure Alloy" do
      {:ok, agent} =
        Server.start_link(opts(start_provider([]), max_turns: 7, context: %{session_id: "s-1"}))

      assert %{agent: %{config: %{max_turns: 7}}} = :sys.get_state(agent)
      assert Server.export_session(agent).id == "s-1"
    end
  end

  describe "start_link/1 validation" do
    test "rejects invalid runtime options with ArgumentError" do
      pid = start_provider([])

      for {key, bad} <- [
            messages: ["not a message"],
            messages: :none,
            pubsub: "MyApp.PubSub",
            subscribe: [:not_a_string],
            subscribe: "topic",
            max_pending: -1,
            max_pending: 1.5,
            on_shutdown: fn -> :ok end
          ] do
        error = assert_raise ArgumentError, fn -> Server.start_link(opts(pid, [{key, bad}])) end
        assert error.message =~ inspect(key)
      end
    end

    test ":subscribe without :pubsub raises" do
      assert_raise ArgumentError, ~r/:subscribe needs :pubsub/, fn ->
        Server.start_link(opts(start_provider([]), subscribe: ["tasks"]))
      end
    end

    test "raises in the caller, before any process starts, for invalid loop options" do
      assert_raise ArgumentError, fn ->
        Server.start_link(opts(start_provider([]), memory: :not_a_tuple))
      end
    end
  end

  describe "set_model/2" do
    test "requires :provider" do
      {:ok, agent} = Server.start_link(opts(start_provider([])))

      assert_raise KeyError, fn -> Server.set_model(agent, model: "other") end
    end
  end

  describe "stream_chat/4" do
    test "streams chunks and passes :on_event through to the loop" do
      pid = start_provider([TestProvider.text_response("Hi")])
      {:ok, agent} = Server.start_link(opts(pid))
      test_pid = self()

      assert {:ok, %{text: "Hi"}} =
               Server.stream_chat(agent, "Hello", &send(test_pid, {:chunk, &1}),
                 on_event: &send(test_pid, {:event, &1})
               )

      assert_received {:chunk, "H"}
      assert_received {:chunk, "i"}
      assert_received {:event, %{event: :text_delta}}
    end

    test "rejects an :on_event that is not a 1-arity function" do
      {:ok, agent} = Server.start_link(opts(start_provider([])))

      assert_raise ArgumentError, ~r/on_event must be a 1-arity function/, fn ->
        Server.stream_chat(agent, "Hello", fn _ -> :ok end, on_event: :nope)
      end
    end
  end

  describe "{:agent_event, message} without a PubSub" do
    test "runs the message and keeps the reply in the history" do
      pid = start_provider([TestProvider.text_response("handled")])
      {:ok, agent} = Server.start_link(opts(pid))

      send(agent, {:agent_event, "do some work"})

      assert eventually(fn -> length(Server.messages(agent)) == 2 end)
      assert [%{content: "do some work"}, %{role: :assistant}] = Server.messages(agent)
    end
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end
end
