# Spec coverage (GDD_spec_MVP_EN v1, with §15b branches)

Audit of this repo against the spec, written for GR5-55. Baseline: `main` at 732aa8f (2026-11-08). Gap backlog parent: **GR5-70**.

Status key: **DONE** (code and a named test agree), **PARTIAL**, **MISSING**, **UNVERIFIED** (not checked in the real engine). Update the "Issue" column and the status when a gap issue closes.

## Headline

The headless suite is green (37 suites) and the sim covers most of the spec. The **running game is not playable end to end**: the client builds `Sim.new()` (`scripts/client/main.luau`) but never calls `sim:setDecider(Ai.decide)`, so no agent ever acts; the Debug panel, Station panel, emergency-advance button and save/load are not wired to the client. The first five issues below remove those demo blockers. Visual quality of the real render (flat planet disc, no starfield, unreadable nav) is tracked separately in the GR5-48 family (GR5-49..54, 67..69), not here. Pacing / profitability / demo rehearsal are GR5-63, GR5-64, GR5-65 and Compute billing GR5-66.

## Ranked gap backlog (demo-path value, §18)

| Rank | Issue | Gap | Assignee | Status |
|---|---|---|---|---|
| 1 | GR5-71 | Client never sets the decider: agents are inert in the game | Gameplay | todo |
| 2 | GR5-72 | Debug panel not wired (credits, tier, +Compute, reveal, away, reset) | Gameplay | todo |
| 3 | GR5-73 | Station panel empty at T3 (stock, capacity, ships, freighters, Logisticians) | Gameplay | todo |
| 4 | GR5-75 | Tool results (§11) stored as `{}`: `recent` and logs blank | Gameplay | todo |
| 5 | GR5-76 | Stub interpreter incomplete (§10.5) | Gameplay | todo |
| 6 | GR5-74 | Emergency advance has no notification/button | Gameplay | todo |
| 7 | GR5-77 | Save/load, autosave, offline catch-up not wired | Gameplay | in review |
| 8 | GR5-83 | M1/M6/M8 acceptance tests the spec asks for | Gameplay | todo |
| 9 | GR5-80 | Missions 6-8 ignore non-Miner agents; trigger deviations | Gameplay | done |
| 10 | GR5-78 | §8.4 failure counting + Monitor tool gaps | Gameplay | backlog |
| 11 | GR5-86 | Extended T5 demo: prepared save + deplete-vein action | Gameplay | backlog |
| 12 | GR5-89 | Real-runtime check of UI screens the audit could not verify | Gameplay | backlog |
| 13 | GR5-79 | Per-agent home station, dismiss/rename/set_tools | Gameplay | backlog |
| 14 | GR5-87 | Real AI (Axis) reachable from the running game | Gameplay | backlog |
| 15 | GR5-88 | `[Engine]` net/protocol client<->server transport | Engine | backlog |
| 16 | GR5-81 | One Monitor per scope | Gameplay | backlog |
| 17 | GR5-82 | Fidelity: mixed hold, vein hop, rounding, error codes | Gameplay | backlog |
| 18 | GR5-84 | §9.2.5 goldens for all agent types, M10 token ratio | Gameplay | backlog |
| 19 | GR5-85 | Reconcile deliberate deviations (cost, nav tier, naming, hard-coded numbers) | Gameplay | backlog |

## Milestones (§17)

| Milestone | Status | Evidence | Gap / issue |
|---|---|---|---|
| M0 | DONE | `tests/test_m0.luau`, `tools/run_tests.sh`, engine self-test `scripts/server/selftest.luau` (GR5-35) | |
| M1 | DONE | `test_acceptance.luau` sections 1-3: all 12 veins within +-1 s and exact credits, K3 Mk2, A1 Mk3 221.5 s, fifth planet by data only | K3 pays 720 (7.2/unit), see DECISIONS.md |
| M2 | DONE | `test_missions.luau:55-77` (precise < 15 min on every seed, vague fails in >10/20), `test_miner.luau:117`, `test_rules.luau:73-88` | |
| M3 | PARTIAL | Shell: top bar, map, feed, editor with live cost | Decider never set in client (GR5-71) |
| M4 | PARTIAL | `compute_view`, `shop_view`, `logs_view` | Bailout unreachable (GR5-74) |
| M5 | DONE | `test_offline.luau:113` (8 h under 2 s), `skill_studio`, `archive_view` | Studio UI and screens unverified in engine (GR5-89) |
| M6 | PARTIAL | `test_market.luau:111` (250/min seller), `test_acceptance.luau` section 4 (unassisted baseline + 100/min seller) | Real dynamics alone flip only iridium; the criterion holds with a player-sales seller (DECISIONS.md GR5-83). Station panel empty (GR5-73) |
| M7 | DONE | `test_logistics.luau`, `fleet_view`, convoy dots `shell.luau:224` | |
| M7b | PARTIAL | `test_multi.luau` #2-#4 | No `set_home_station`; hold is single-ore (GR5-79, GR5-82) |
| M7c | DONE | `test_monitor.luau` #2-#4 | Single Monitor, not per scope (GR5-81) |
| M8 | DONE | `test_acceptance.luau` section 5: T3 in 20-30 min, T4 60 and T5 120 within +-30% (median of seeds 1-3); `docs/BALANCE_REPORT.md` | Pacing tuning is GR5-63 |
| M9 | DONE (unverified on GPU) | `test_art.luau`, `render/glow.luau`, `render/vfx`, `test_ui_skin.luau` | Real render quality: GR5-48 family |
| M10 | PARTIAL | `ai/axis.luau`, `ai/provider.luau`, `server/axis_http.luau`, `test_ai.luau` | `server/ai_host.luau` required nowhere; no net layer (GR5-87, GR5-88); token ratio not recorded (GR5-84) |
| B-0 | DONE | `test_branches.luau:52` (dummy branch) | |
| B-a Salvage | DONE | `test_salvage.luau:224, :434` | |
| B-b Refining | DONE | `test_refining.luau:323` | Test forces the demand trend by hand |
| B-c Raiding | DONE | `test_raiding.luau:249, :431` | |

## Numbered sections

| § | Status | Evidence | Gap / issue |
|---|---|---|---|
| 3 tick, speeds, pause | DONE | `balance.luau` tick 0.1 s, speeds {1,4,16}; `clock.luau`; `test_speed.luau` | |
| 3 tick order | PARTIAL | `Sim:step` | Markets before ships; skills/triggers merged. No gameplay effect (GR5-85 records it) |
| 3 autosave / on quit | DONE (window-close path unverified in engine) | `client/save.luau` autosave every 30 s real + save on `rtype.Closed`; `tests/test_save.luau`, engine selftest, real client run (DECISIONS GR5-77) | GR5-77 |
| 4.1-4.4 resources, planets, veins, markets | DONE | `world.luau`, `test_market.luau` §1 | |
| 4.5 freighter routes / risk | PARTIAL | Routes match; risk only cosmetic in `config/screens.luau` | Allowed by spec |
| 5.1 stats, travel, crowding | DONE | `travelTicks`, `crowdingFor`, `test_multi.luau:59` | |
| 5.1 vein-to-vein hop | MISSING | `world.minVeinHopSeconds` unused; `mine` refused while mining | GR5-82 |
| 5.1 hold "all resources combined" | PARTIAL | `sim.luau:397` single-ore | GR5-82 |
| 5.2 freighter, 5.3 fleet size | DONE | `stepFreighters`, `claimShips`, `test_logistics.luau` | |
| 6.1 start state, 6.4 Compute | DONE | `config/ai.luau`, `compute.luau` | Compute billing semantics: GR5-66 |
| 6.2 channels | PARTIAL | HMC, Orbis, freighters | Sale totals use unrounded unit price (GR5-82) |
| 6.3 saturation, demand, events, trends, rivals | DONE | `config/market.luau`, `sim/market.luau`, `test_market.luau` §1-6 | |
| 6.5 shop, command capacity | PARTIAL | Costs and prerequisites match | `command_center` 160,000 vs 15,000 (DECISIONS GR5-30; GR5-85, GR5-63) |
| 6.6 tiers | PARTIAL | Thresholds match | Team nav at T2, spec T5 (GR5-85) |
| 6.7 reputation | DONE | `reputationLevels` | Dead `sim.resources.reputation` (GR5-85) |
| 7 stations | PARTIAL | Storage, freighter caps, per-station stock, max 2 Logisticians | No per-agent home station (GR5-79) |
| 7 station panel | MISSING | `config/screens.luau:15` declares it, `shell.luau` routes to `empty()` | GR5-73 |
| 8.1 team, types | PARTIAL | One Monitor per company | GR5-81 |
| 8.2 agent state | PARTIAL | camelCase fields; no `prompt_version`/`metrics` on agent | GR5-85 |
| 8.3 AI triggers | DONE | `stepAgent`, `thrashAllowed`, `bailoutConditions` | Stub latency 2-4 game s vs 1-3 s real (GR5-78) |
| 8.4 errors and fallbacks | PARTIAL | `noteFailure`, `onAiResponse` | GR5-78 |
| 8.5 anti-softlock | PARTIAL | `acceptEmergencyAdvance`, `balance.bailout` | No UI (GR5-74) |
| 8.6 conflicts and locks | DONE | `monitorLock`, `agent_locked` | |
| 8.7 messages and feed | PARTIAL | Monitor feed tag, inbox max 5 | Cyan tag unverified (GR5-89); inbox has no `sender` (GR5-85) |
| 8.8 team view | UNVERIFIED | Not inspected | GR5-89 |
| 8.9 Monitor tools, alerts | PARTIAL | `monitor.luau`, `alerts.luau`, heartbeat 60-600 | `assign_skill none`, null `set_order`, `previous_error` (GR5-78, GR5-75) |
| 9.1 prompt assembly | PARTIAL | `prompt.luau` order correct | Tools section is a summary, not JSON schema (GR5-85) |
| 9.2 builders, renderers, goldens | PARTIAL | Goldens for Miner (`compute_test.luau:50-89`) and Monitor (`test_monitor.luau:248-263`) | Results blank (GR5-75); Logistician/branch goldens missing, `62` vs `62.0` (GR5-84) |
| 9.3 context settings, 9.4 editor live cost | DONE | `context_settings.luau`, `agent_editor.luau`, `compute_view.luau` | |
| 10.1 provider interface, 10.4 server-only key, 10.5 validation, 10.6 queue/budget | DONE | `ai/provider.luau`, `axis_http.luau`, `ai/validator.luau`, `ai_queue.luau` | |
| 10.2 stub provider / 10.7 interpreter | PARTIAL | `sim/ai.luau` | Thin rules (GR5-76) |
| 10.3 Axis provider | PARTIAL | `ai/axis.luau`, timeout 20 s | Named "axis" vs "rubix"; 20 s vs GR5-15's 10 s (GR5-78, GR5-85); unreachable from game (GR5-87) |
| 11 tools | PARTIAL | All tools exist with error codes | Results not returned, extra/missing error codes (GR5-75, GR5-82) |
| 12.1 DecisionRecord | DONE | `decision_log.luau`, 500 records/agent | `result` empty on success (GR5-75) |
| 12.2 Logs screen | UNVERIFIED | `Log.stats` window 600 s | GR5-89 |
| 12.3 prompt versions, compare | DONE | `versions.luau`, `test_versions.luau` | Compare UI unverified (GR5-89) |
| 13.1-13.4 skills | DONE | `skills.luau`, `checkParams`, `Skills.record`, wake-AI on abort | |
| 13.5 studio UI | UNVERIFIED | `test_studio.luau` | GR5-89 |
| 14 offline | PARTIAL | `offline.luau` cap 8 h, skill-mode only, report | Now run at launch from `client/save.luau`, summary shown as a modal over any screen (GR5-77) |
| 15 missions 1-8 | DONE | `config/missions.luau`, `sim/missions.luau`, `missions_view.luau`, `test_missions.luau` | M4 counts a skill saved before the mission opened (accepted, DECISIONS.md GR5-80) |
| 15b.0 hierarchy | DONE | `sim/branches/*`, `test_branches.luau` | |
| 15b.1 ladders | DONE | `config/branches.luau` | |
| 15b.2 refining, 15b.3 salvage, 15b.4 raiding | DONE | `test_refining.luau`, `test_salvage.luau`, `test_raiding.luau` | Refiner cap 4 not enforced as far as read |
| 15b.5 V1-V3 missions, 15b.6 stubs | DONE | `missions_view.luau`, branch tests | |
| 16.1 folder layout | PARTIAL | Real layout `scripts/{config,sim,ai,ui,client,server,render}` | Mapping below; GR5-85 |
| 16.2 messages / net protocol | MISSING | No `net/protocol.luau`; client runs a local sim | GR5-88 (Engine), GR5-87, GR5-79 |
| 16.3 save | PARTIAL | `persistence.luau` + `client/storage.luau` on `rtype.Persistence`; `test_save.luau`, `server/selftest.luau` | Called at boot, every 30 s and on quit (GR5-77) |
| 16.4 debug panel | PARTIAL | `sim/debug.luau` has 9 actions; `ui/debug.luau` never spawned; `config/debug.luau` hard-codes enabled | GR5-72, GR5-86 |
| 16.5 leave room | PARTIAL | `Sim:deliver` | No `sender` field (GR5-85) |
| 17 demo path | PARTIAL | Speed buttons, editor presets, Shop, Logs->skill, "Simulate 1 h away", warehouse purchase work | Agents inert (GR5-71), no credit boost (GR5-72), Orbis step needs Station panel (GR5-73) |
| 17 extended T5 demo | MISSING | No T5 save, no deplete-vein, no load path | GR5-86 |

## §16.1 layout mapping (spec name -> real file)

| Spec | Actual |
|---|---|
| `sim/world, ships, station, tools, agents, team, progression, metrics` | Merged into `scripts/sim/sim.luau` plus `skills.luau`, `monitor.luau`, `missions.luau`, `offline.luau` |
| `sim/ai/stub` | `scripts/sim/ai.luau` |
| `ai/context_builder, renderer` | `scripts/sim/context_builder.luau`, `context_renderer.luau` |
| `ai/rubix.luau` | `scripts/ai/axis.luau` |
| `net/protocol.luau` | not present (GR5-88) |
| `ui/*` panels | Mostly folded into `scripts/ui/shell.luau` plus `*_view.luau` files |
| `config/*.luau` | `scripts/config/*.luau` |
