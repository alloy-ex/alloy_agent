defmodule AlloyAgentTest do
  use ExUnit.Case, async: true

  test "module exposes the runtime API via delegation to AlloyAgent.Server" do
    Code.ensure_loaded!(AlloyAgent)
    exports = AlloyAgent.__info__(:functions)

    for {name, arity} <- [
          start_link: 1,
          chat: 3,
          stream_chat: 4,
          send_message: 3,
          cancel_request: 2,
          messages: 1,
          usage: 1,
          reset: 1,
          set_model: 2,
          export_session: 1,
          health: 1,
          stop: 1
        ] do
      assert {name, arity} in exports, "AlloyAgent.#{name}/#{arity} should be exported"
    end
  end
end
