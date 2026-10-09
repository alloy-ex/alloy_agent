# AlloyAgent

**Supervised OTP runtime for [Alloy](https://github.com/alloy-ex/alloy).**

Alloy is the protocol library: the agent loop, providers, tools, the memory
behaviour. `alloy_agent` is the OTP runtime on top of it: a GenServer that
holds conversation state, runs requests asynchronously with backpressure,
broadcasts results over PubSub, and ships default memory stores. Use it when
you want an agent in your supervision tree; use `Alloy.run/2` directly when
you want the loop as a pure function.

## Installation

```elixir
def deps do
  [
    {:alloy_agent, "~> 0.1"},
    # Only needed for send_message/3 and :subscribe (results go over PubSub):
    {:phoenix_pubsub, "~> 2.1"}
  ]
end
```

`alloy_agent` 0.1 works with `alloy` 0.12.5 and later 0.12.x releases, and with
0.13.x. Add `{:alloy, ...}` yourself only if you want to pin it.

## Quick start

```elixir
{:ok, agent} =
  AlloyAgent.start_link(
    provider: {Alloy.Provider.Anthropic, api_key: System.fetch_env!("ANTHROPIC_API_KEY"), model: "claude-sonnet-5-5"},
    tools: [Alloy.Tool.Core.Read, Alloy.Tool.Core.Bash],
    system_prompt: "You are a helpful assistant."
  )

{:ok, result} = AlloyAgent.chat(agent, "List the files in this project")
{:ok, result} = AlloyAgent.chat(agent, "Now read mix.exs")
IO.puts(result.text)

AlloyAgent.messages(agent) # the whole conversation so far
AlloyAgent.usage(agent)    # tokens across every turn
```

`chat/3` returns `{:ok, result}` or `{:error, result}` tagged the same way as
`Alloy.run/2`; `result` is an `Alloy.Result`. `stream_chat/4` does the same
while calling a function with each text delta.

In a supervision tree:

```elixir
children = [
  {Phoenix.PubSub, name: MyApp.PubSub},
  {AlloyAgent.Server,
   name: MyApp.Agent,
   provider: {Alloy.Provider.Anthropic, api_key: System.fetch_env!("ANTHROPIC_API_KEY"), model: "claude-sonnet-5-5"},
   pubsub: MyApp.PubSub}
]
```

## Options

`start_link/1` takes Alloy's loop options (`:provider`, `:tools`,
`:system_prompt`, `:middleware`, `:timeout_ms`, `:context`, `:memory`, ... as
documented for `Alloy.run/2`) plus these runtime options, which the server
keeps for itself:

| Option | Default | |
|---|---|---|
| `:name` | none | Register the process under a name. |
| `:messages` | `[]` | Conversation history to start from. |
| `:pubsub` | `nil` | Name of a running `Phoenix.PubSub`. Required for `send_message/3`. |
| `:subscribe` | `[]` | Topics to subscribe to; an `{:agent_event, message}` broadcast on one runs `message`. Needs `:pubsub`. |
| `:max_pending` | `0` | How many async requests may queue while one runs. |
| `:on_shutdown` | `nil` | `fn %AlloyAgent.Session{} -> ... end`, called when the agent stops. |

Invalid options raise `ArgumentError` from `start_link/1`.

## Async requests over PubSub

A synchronous `chat/3` runs inside the server process, so the agent answers
nothing else until it finishes. `send_message/3` returns at once and runs the
request in a supervised task; the result is broadcast as
`{:agent_response, result}` on `"agent:<session id>:responses"`.

```elixir
{:ok, agent} = AlloyAgent.start_link(provider: provider, pubsub: MyApp.PubSub, max_pending: 5)

%{id: session_id} = AlloyAgent.export_session(agent)
Phoenix.PubSub.subscribe(MyApp.PubSub, "agent:#{session_id}:responses")

{:ok, request_id} = AlloyAgent.send_message(agent, "Summarise the logs")

receive do
  {:agent_response, %{request_id: ^request_id, status: :completed, text: text}} -> IO.puts(text)
  {:agent_response, %{request_id: ^request_id, error: error}} -> IO.inspect(error, label: "failed")
end
```

- The session id is `context: %{session_id: ...}` when you set one, otherwise
  a random id; `export_session/1` returns it.
- While a request runs, the next ones queue up to `:max_pending`; past that
  `send_message/3` returns `{:error, :queue_full}` (or `{:error, :busy}` when
  `:max_pending` is `0`). `health/1` reports `busy` and `pending_count`.
- `cancel_request/2` stops a running request or removes a queued one, and
  broadcasts a result with `error: :cancelled`.
- `chat/3`, `stream_chat/4`, `reset/1` and `set_model/2` return
  `{:error, :busy}` while an async request runs.

### Failed runs

A run that fails before the model replies leaves the conversation as it was:
its message is removed from the history, so you can send it again without two
user messages in a row. That covers a crashed or cancelled async request and
an `{:error, result}` run whose prompt got no reply. A failed run that got
further, say through a few tool calls, keeps its messages so a follow-up can
build on them. Usage is always kept.

## Sessions

`export_session/1` returns an `AlloyAgent.Session` (id, messages, usage,
metadata), a plain struct you can store anywhere. `:on_shutdown` receives one
when the agent stops. To carry a conversation into a new process, start it
with the stored history:

```elixir
AlloyAgent.start_link(provider: provider, messages: session.messages, context: %{session_id: session.id})
```

`:session_start` and `:session_end` `Alloy.Middleware` hooks run when the
agent starts and stops.

## Memory stores

Two implementations of `Alloy.Memory` for Alloy's `:memory` option (see
`Alloy.Memory` for which providers support it):

```elixir
# Process-local: gone when the store process exits.
{:ok, store} = AlloyAgent.Memory.InMemory.start_link()
memory = {AlloyAgent.Memory.InMemory, store}

# Filesystem: survives restarts, one tree per session id.
memory = AlloyAgent.Memory.Disk.new(root: "/var/agent/memories", session_id: "acct-42")

AlloyAgent.start_link(provider: {Alloy.Provider.Anthropic, ...}, memory: memory)
```

Both also work with `Alloy.run/2`. For Postgres, S3 or encrypted storage,
implement `Alloy.Memory` yourself; it is six callbacks.

## Spending limits

There is no built-in budget option. Price the usage in a `:before_completion`
middleware and halt the run at your limit; the "Budget limits" section of the
[`Alloy` module docs](https://hexdocs.pm/alloy/Alloy.html#module-budget-limits)
has the recipe.

## Migrating from `Alloy.Agent.Server`

Alloy 0.13 removes its runtime: `Alloy.Agent.Server`, `Alloy.Session`,
`Alloy.send_message/3`, `Alloy.cancel_request/2`, the `Alloy.Agent.Events`
shim and the PubSub Alloy started from `config :alloy, :pubsub`.
`alloy_agent` is where the runtime lives now.

1. Add `{:alloy_agent, "~> 0.1"}` (and `{:phoenix_pubsub, "~> 2.1"}` if you
   use async requests).
2. Rename:

   | Before | After |
   |---|---|
   | `Alloy.Agent.Server` | `AlloyAgent.Server` (or the `AlloyAgent` facade) |
   | `Alloy.send_message/3`, `Alloy.cancel_request/2` | `AlloyAgent.send_message/3`, `AlloyAgent.cancel_request/2` |
   | `%Alloy.Session{}`, `Alloy.Session.*` | `%AlloyAgent.Session{}`, `AlloyAgent.Session.*` |
   | `Alloy.Agent.Events` | `Alloy.Events` (stays in Alloy) |

3. Then check for these differences:

   - **PubSub.** `config :alloy, :pubsub` has no equivalent. Put
     `{Phoenix.PubSub, name: MyApp.PubSub}` in your supervision tree and pass
     `pubsub: MyApp.PubSub` to the agent.
   - **`:max_budget_cents`** is gone; use the budget middleware above.
   - **Middleware state.** `:pubsub`, `:subscribe`, `:max_pending` and
     `:on_shutdown` are no longer fields of `state.config`, and
     `:current_task` and `:pending_requests` are no longer fields of the
     `Alloy.Agent.State` middleware receives, so `:session_start` middleware
     can't change the PubSub subscriptions. `:sys.get_state/1` on an agent
     returns `%AlloyAgent.Server{agent: %Alloy.Agent.State{}}`.
   - **Failed runs** drop a prompt that got no reply (see above). With
     `Alloy.Agent.Server` it stayed, and the usual workaround was `reset/1`
     before retrying, which is no longer needed.
   - While an async request runs, `messages/1` and `export_session/1` return
     the history from before it started.
   - Invalid options raise `ArgumentError` from `start_link/1`, and
     `set_model/2` requires `:provider`.
   - The default `chat/3` timeout is the agent's `:timeout_ms` plus 10
     seconds, as in Alloy 0.12.5.

## License

MIT.
