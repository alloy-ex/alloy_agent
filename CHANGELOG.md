# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

The first release: the runtime that leaves `alloy` in 0.13, as a package of
its own. It works with `alloy` 0.12.5 and 0.13.

### Added

- `AlloyAgent.Server`, a supervised GenServer around Alloy's loop that holds
  the conversation across calls: `chat/3`, `stream_chat/4`, `messages/1`,
  `usage/1`, `reset/1`, `set_model/2`, `export_session/1`, `health/1`,
  `stop/1` and `default_call_timeout/1`. The `AlloyAgent` module delegates to
  it.
- Async requests: `send_message/3` runs a request in a supervised task and
  broadcasts `{:agent_response, result}` on `"agent:<session id>:responses"`;
  `:max_pending` bounds the queue; `cancel_request/2` stops a running or queued
  request. `:subscribe` runs `{:agent_event, message}` broadcasts.
- `AlloyAgent.Session`, a plain, serializable conversation struct, and the
  `:on_shutdown` callback that receives one.
- `:session_start` and `:session_end` middleware hooks.
- Memory stores implementing `Alloy.Memory`: `AlloyAgent.Memory.InMemory`
  (process-local) and `AlloyAgent.Memory.Disk` (filesystem, one tree per
  session id).

### Changed from `Alloy.Agent.Server` (alloy 0.12.5)

The server started as a copy of alloy's, including its 0.12.5 fixes:
`chat/3` and `stream_chat/4` wait as long as a turn may run, and results are
tagged like `Alloy.run/2`. Where it now differs:

- The server owns its runtime options (`:pubsub`, `:subscribe`,
  `:max_pending`, `:on_shutdown`, `:messages`) and in-flight state, and
  passes only loop options to `Alloy.Agent.Config.from_opts/1`. Middleware
  can no longer change the PubSub settings, and `:sys.get_state/1` returns
  `%AlloyAgent.Server{agent: %Alloy.Agent.State{}}`.
- A run that fails before the model replies, including a crashed or
  cancelled async request, no longer leaves its prompt in the history, so a
  retry doesn't put two user messages in a row.
- While an async request runs, `messages/1` and `export_session/1` return the
  history from before it started.
- Options are validated in `start_link/1`, which raises `ArgumentError` for
  invalid ones, and `set_model/2` requires `:provider`.
- `:on_shutdown` is typed as taking an `%AlloyAgent.Session{}`
  ([alloy#40](https://github.com/alloy-ex/alloy/issues/40)).
- Each run starts with `stop_reason: nil`, so a result never reports the
  previous run's stop reason.

### Not included

- `:max_budget_cents`. Alloy 0.13 removes it; enforce a budget with a
  `:before_completion` middleware (the "Budget limits" recipe in the `Alloy`
  module docs).
- A PubSub started from application config. Put
  `{Phoenix.PubSub, name: MyApp.PubSub}` in your supervision tree.
- `AlloyAgent.Events`. Event envelopes are part of Alloy's protocol; use
  `Alloy.Events`.
