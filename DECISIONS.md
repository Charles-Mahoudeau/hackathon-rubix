# Decisions

- 2026-11-07 — Sim modules live in `config/` and `sim/` (outside `scripts/`), because the engine auto-loads every file in `scripts/`; the engine entry will require them later. Reason: keeps headless sim testable with plain Lua.
- 2026-11-07 — GR5-2 foundation uses a single `config/balance.luau` table; to be split into `config/*.luau` per subsystem as milestones add content. Reason: simplest for M0.
