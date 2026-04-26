# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-04-26

### Added

- Initial extraction from `alloy` 0.12.x runtime modules into a standalone package.
- `AlloyAgent.Server` — supervised GenServer wrapping `Alloy.run/2` with session state.
- `AlloyAgent.Session` — serializable session container.
- Async dispatch: `send_message/3`, `cancel_request/2`, `max_pending` backpressure queue, PubSub broadcast on `"agent:<id>:responses"`.
- Runtime policies: `fallback_providers`, `max_budget_cents` cost guard, `:session_start`/`:session_end` middleware hooks.
- Default memory stores implementing `Alloy.Memory`:
  - `AlloyAgent.Memory.InMemory` — Agent-backed, process-local.
  - `AlloyAgent.Memory.Disk` — filesystem-backed, session-scoped.

### Not included (correction before first publish)

- **`AlloyAgent.Events` was removed before publishing.** The v1 event envelope module belongs in Alloy itself: `Alloy.Agent.Turn` (the protocol loop) calls it directly, so the envelope format is part of Alloy's protocol surface, not a runtime concern. Use [`Alloy.Events`](https://hexdocs.pm/alloy/Alloy.Events.html) from the `alloy` package instead — it is automatically available because `alloy_agent` depends on `alloy`. This correction shipped in `alloy 0.12.2`.

### Requires

- `{:alloy, "~> 0.12.2"}` — this release uses `Alloy.Events` (introduced in Alloy 0.12.2) and the `Alloy.Memory` behaviour (introduced in 0.12.0). `alloy_agent` will continue to be compatible with `alloy 0.13.x` once that release lands and removes the `Alloy.Agent.Server` / `Alloy.Session` / `Alloy.Agent.Events` deprecated shims.
