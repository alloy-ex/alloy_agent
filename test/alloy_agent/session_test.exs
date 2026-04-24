defmodule AlloyAgent.SessionTest do
  use ExUnit.Case, async: true

  alias Alloy.Message
  alias AlloyAgent.Session

  test "new/0 generates an id and timestamps" do
    session = Session.new()

    assert is_binary(session.id)
    assert byte_size(session.id) > 16
    assert %DateTime{} = session.created_at
    assert %DateTime{} = session.updated_at
    assert session.messages == []
    assert session.metadata == %{}
  end

  test "new/1 accepts overrides" do
    session = Session.new(id: "custom-id", messages: [Message.user("hi")])
    assert session.id == "custom-id"
    assert [%Message{content: "hi"}] = session.messages
  end

  test "update_from_result/2 merges results and refreshes updated_at" do
    session = Session.new(id: "s1")
    original_ts = session.updated_at
    Process.sleep(5)

    result = %{
      messages: [Message.user("hello"), Message.assistant("hi")],
      usage: %Alloy.Usage{input_tokens: 10, output_tokens: 5},
      metadata: %{turns: 1}
    }

    updated = Session.update_from_result(session, result)

    assert length(updated.messages) == 2
    assert updated.usage.input_tokens == 10
    assert updated.metadata == %{turns: 1}
    assert DateTime.compare(updated.updated_at, original_ts) == :gt
  end
end
