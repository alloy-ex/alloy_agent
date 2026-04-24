defmodule AlloyAgent.ServerSmokeTest do
  @moduledoc """
  Sanity checks that the extracted `AlloyAgent.Server` still wraps
  `Alloy.Agent.Turn.run_loop/2` correctly, using Alloy's scripted
  test provider. Not a full Server test suite — that comes later.
  """

  use ExUnit.Case, async: true

  alias Alloy.Provider.Test, as: TestProvider

  test "start_link + chat + messages + stop lifecycle" do
    {:ok, provider_pid} =
      TestProvider.start_link([
        TestProvider.text_response("Hello back")
      ])

    {:ok, agent} =
      AlloyAgent.start_link(provider: {TestProvider, agent_pid: provider_pid})

    assert {:ok, result} = AlloyAgent.chat(agent, "Hi")
    assert result.text == "Hello back"
    assert result.status == :completed

    # Conversation history persisted
    assert [user_msg, _assistant_msg] = AlloyAgent.messages(agent)
    assert user_msg.role == :user
    assert Alloy.Message.text(user_msg) == "Hi"

    # Usage accumulates
    assert AlloyAgent.usage(agent).input_tokens >= 0

    # Health check
    health = AlloyAgent.health(agent)
    assert health.status in [:completed, :idle, :running]
    assert health.message_count == 2
    refute health.busy

    # Export session
    session = AlloyAgent.export_session(agent)
    assert %AlloyAgent.Session{} = session
    assert session.messages == AlloyAgent.messages(agent)

    # Reset clears messages but keeps config
    assert :ok = AlloyAgent.reset(agent)
    assert AlloyAgent.messages(agent) == []

    assert :ok = AlloyAgent.stop(agent)
  end

  test "subsequent chat calls use the next scripted response" do
    {:ok, provider_pid} =
      TestProvider.start_link([
        TestProvider.text_response("First"),
        TestProvider.text_response("Second")
      ])

    {:ok, agent} =
      AlloyAgent.start_link(provider: {TestProvider, agent_pid: provider_pid})

    {:ok, r1} = AlloyAgent.chat(agent, "hi")
    {:ok, r2} = AlloyAgent.chat(agent, "again")

    assert r1.text == "First"
    assert r2.text == "Second"

    AlloyAgent.stop(agent)
  end
end
