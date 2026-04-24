# AlloyAgent

**Supervised OTP runtime for [Alloy](https://github.com/alloy-ex/alloy).**

`alloy_agent` is the supervised process wrapper around `Alloy.run/2`. Alloy is
the protocol library — a loop, providers, tools, memory behaviour. `alloy_agent`
is the OTP runtime: a GenServer that holds conversation state, handles async
dispatch with backpressure, broadcasts over PubSub, and ships default memory
stores. Use it when you want an agent running in your supervision tree; skip
it when you want Alloy's loop as a pure function.

```elixir
{:ok, pid} = AlloyAgent.start_link(
  provider: {Alloy.Provider.Anthropic, api_key: key, model: "claude-sonnet-4-6"},
  tools: [Alloy.Tool.Core.Read, Alloy.Tool.Core.Write],
  memory: AlloyAgent.Memory.Disk.new(root: "/var/agent/memories"),
  pubsub: MyApp.PubSub,
  max_budget_cents: 50
)

{:ok, result} = AlloyAgent.chat(pid, "Read mix.exs and tell me the version")
```

## What `alloy_agent` owns

- **Supervised process + session state** — `AlloyAgent.Server` GenServer, `AlloyAgent.Session` struct
- **Async dispatch with backpressure** — `send_message/3`, `cancel_request/2`, `max_pending` queue
- **PubSub broadcast** — results delivered on `"agent:<id>:responses"`
- **Lifecycle + introspection** — `chat/3`, `stream_chat/4`, `messages/1`, `export_session/1`, `reset/1`, `set_model/2`
- **Runtime policies** — `fallback_providers`, `max_budget_cents` cost guard, `:session_start`/`:session_end` hooks
- **Default memory stores** — `AlloyAgent.Memory.InMemory`, `AlloyAgent.Memory.Disk`

## What stays in `alloy`

- The loop: `Alloy.run/2`, `Alloy.stream/3`
- Providers: `Alloy.Provider.{Anthropic, OpenAI, Gemini, XAI, OpenAICompat, Codex}`
- Tools: `Alloy.Tool`, `Alloy.Tool.Core.{Read, Write, Edit, Bash}`
- Memory protocol: `Alloy.Memory`, `Alloy.Memory.Router`
- Data: `Alloy.Message`, `Alloy.Result`, `Alloy.Usage`, `Alloy.ModelMetadata`
- Extension points: `Alloy.Middleware` (loop-level hooks only)
- Compaction mechanism: `Alloy.Context.Compactor` (summary prompt is BYO)

## Installation

```elixir
def deps do
  [
    {:alloy, "~> 0.13"},
    {:alloy_agent, "~> 0.1"}
  ]
end
```

## Why split?

Elixir already has a runtime: OTP. Phoenix.PubSub, Task.Supervisor, Registry,
GenStage are battle-tested primitives every Elixir developer already knows.
Bundling a reinvented runtime into `alloy` would compete with the BEAM, not
complement it. A protocol library (`alloy`) layered beneath an optional runtime
(`alloy_agent`) lets you compose with the OTP primitives you want and opt out
of the ones you don't.

## License

MIT.
