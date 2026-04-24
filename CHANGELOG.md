# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

### Added

- Initial extraction from `alloy` 0.12.x runtime modules into a standalone package.
- `AlloyAgent.Server` — supervised GenServer wrapping `Alloy.run/2` with session state.
- `AlloyAgent.Session` — serializable session container.
- `AlloyAgent.Events` — v1 event envelope protocol with correlation IDs and sequence counters.
- Async dispatch: `send_message/3`, `cancel_request/2`, `max_pending` backpressure queue, PubSub broadcast on `"agent:<id>:responses"`.
- Runtime policies: `fallback_providers`, `max_budget_cents` cost guard, `:session_start`/`:session_end` middleware hooks.
- Default memory stores implementing `Alloy.Memory`:
  - `AlloyAgent.Memory.InMemory` — Agent-backed, process-local.
  - `AlloyAgent.Memory.Disk` — filesystem-backed, session-scoped.

### Requires

- `{:alloy, "~> 0.13"}` — this release depends on Alloy having dropped the extracted runtime modules.
