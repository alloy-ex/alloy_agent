defmodule AlloyAgent.ServerFailedRunsTest do
  @moduledoc """
  A failed run must leave the history ready for the next message: never
  two user messages in a row because a prompt got no reply.
  """

  use ExUnit.Case, async: true

  alias Alloy.Provider.Test, as: TestProvider
  alias AlloyAgent.Server
  alias AlloyAgent.Test.EchoTool

  defp start_provider(responses) do
    {:ok, pid} = TestProvider.start_link(responses)
    pid
  end

  defp opts(provider_pid, overrides \\ []) do
    Keyword.merge([provider: {TestProvider, agent_pid: provider_pid}, max_retries: 0], overrides)
  end

  defp start_agent_with_pubsub(responses, overrides \\ []) do
    pubsub = :"test_pubsub_fail_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    {:ok, agent} =
      Server.start_link(opts(start_provider(responses), [pubsub: pubsub] ++ overrides))

    Phoenix.PubSub.subscribe(pubsub, "agent:#{Server.export_session(agent).id}:responses")
    agent
  end

  defp roles(agent), do: agent |> Server.messages() |> Enum.map(& &1.role)

  defp contents(agent), do: agent |> Server.messages() |> Enum.map(& &1.content)

  defp assert_alternates(agent) do
    roles = roles(agent)

    refute Enum.any?(Enum.chunk_every(roles, 2, 1, :discard), &(&1 == [:user, :user])),
           "consecutive user messages in #{inspect(roles)}"
  end

  describe "synchronous chat" do
    test "a provider error before any reply drops the prompt, so a retry alternates" do
      pid =
        start_provider([
          TestProvider.error_response(:overloaded),
          TestProvider.text_response("Recovered")
        ])

      {:ok, agent} = Server.start_link(opts(pid))

      assert {:error, %{status: :error, messages: [%{content: "Do it"}]}} =
               Server.chat(agent, "Do it")

      assert Server.messages(agent) == []

      assert {:ok, %{text: "Recovered"}} = Server.chat(agent, "Do it")
      assert roles(agent) == [:user, :assistant]
      assert contents(agent) == ["Do it", "Recovered"]
    end

    test "keeps the usage the failed run reported" do
      pid =
        start_provider([
          TestProvider.tool_use_response([%{id: "c1", name: "echo", input: %{"text" => "x"}}]),
          TestProvider.error_response(:overloaded)
        ])

      {:ok, agent} = Server.start_link(opts(pid, tools: [EchoTool]))

      assert {:error, _} = Server.chat(agent, "Do it")
      assert Server.usage(agent).input_tokens == 10
    end

    test "a failed run that got a reply keeps its messages for a follow-up" do
      pid =
        start_provider([
          TestProvider.tool_use_response([%{id: "c1", name: "echo", input: %{"text" => "x"}}]),
          TestProvider.error_response(:overloaded),
          TestProvider.text_response("Carried on")
        ])

      {:ok, agent} = Server.start_link(opts(pid, tools: [EchoTool]))

      assert {:error, %{status: :error}} = Server.chat(agent, "Use the tool")
      assert roles(agent) == [:user, :assistant, :user]

      assert {:ok, %{text: "Carried on"}} = Server.chat(agent, "continue")
      assert roles(agent) == [:user, :assistant, :user, :user, :assistant]
    end

    test "a successful run commits its prompt and reply" do
      pid = start_provider([TestProvider.text_response("Done")])
      {:ok, agent} = Server.start_link(opts(pid))

      assert {:ok, _} = Server.chat(agent, "Go")
      assert contents(agent) == ["Go", "Done"]
    end
  end

  describe "async requests" do
    test "a provider error before any reply drops the prompt" do
      agent =
        start_agent_with_pubsub([
          TestProvider.error_response(:overloaded),
          TestProvider.text_response("Recovered")
        ])

      {:ok, _} = Server.send_message(agent, "first try")
      assert_receive {:agent_response, %{status: :error}}, 2000
      assert Server.messages(agent) == []

      {:ok, _} = Server.send_message(agent, "second try")
      assert_receive {:agent_response, %{status: :completed}}, 2000
      assert contents(agent) == ["second try", "Recovered"]
    end

    test "a crashed turn leaves the history as it was, so a retry alternates" do
      agent =
        start_agent_with_pubsub([
          TestProvider.text_response("First"),
          :crash_now,
          TestProvider.text_response("Recovered")
        ])

      {:ok, _} = Server.send_message(agent, "hello")
      assert_receive {:agent_response, %{status: :completed}}, 2000

      {:ok, crash_id} = Server.send_message(agent, "crash please")
      assert_receive {:agent_response, %{request_id: ^crash_id, status: :error}}, 2000
      assert contents(agent) == ["hello", "First"]
      assert Server.health(agent).status == :error

      {:ok, _} = Server.send_message(agent, "crash please")
      assert_receive {:agent_response, %{status: :completed}}, 2000

      assert_alternates(agent)
      assert contents(agent) == ["hello", "First", "crash please", "Recovered"]
    end

    test "a cancelled running request leaves no trace in the history" do
      agent =
        start_agent_with_pubsub([
          TestProvider.slow_text_response("Never seen", 500),
          TestProvider.text_response("Answered")
        ])

      {:ok, req} = Server.send_message(agent, "slow one")
      assert :ok = Server.cancel_request(agent, req)

      assert_receive {:agent_response,
                      %{request_id: ^req, error: :cancelled, cancelled_phase: :running}},
                     1000

      assert Server.messages(agent) == []

      {:ok, _} = Server.send_message(agent, "next")
      assert_receive {:agent_response, %{text: "Answered"}}, 2000
      assert contents(agent) == ["next", "Answered"]
    end

    test "the history excludes the in-flight request until it completes" do
      agent = start_agent_with_pubsub([TestProvider.slow_text_response("Later", 200)])

      {:ok, _} = Server.send_message(agent, "in flight")
      assert Server.messages(agent) == []
      assert Server.export_session(agent).messages == []
      assert Server.health(agent).status == :running

      assert_receive {:agent_response, %{status: :completed}}, 2000
      assert contents(agent) == ["in flight", "Later"]
    end
  end
end
