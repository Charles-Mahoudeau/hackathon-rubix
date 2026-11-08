# Compute billing audit (GR5-66)

Reproduce: `tools/compute_audit.sh` rewrites this file's measured sections (`luau tools/compute_audit_report.luau`); `luau tests/test_compute_audit.luau` fails if any check below fails (it also runs in `tools/run_tests.sh`). Fixed seeds, fake network, no key, no internet: the numbers are identical on every run.

## Verdict

| Acceptance item | Result |
|---|---|
| 1,000 tokens/Compute, 40 cr/Compute, packs of 5 (200 cr), round-up to 0.1 per decision, 400,000 tokens per rolling real hour | Confirmed in `config/ai.luau` and by the rounding table; no change. |
| Estimated vs actual tokens, rounded Compute, credits, failed/invalid calls reconcile | Reconciled: records == ledger == balance drop == AiQueue tokens, to the cent, in a stub run and in a scripted provider run (ok, HTTP 500, timeout, prose reply, unknown tool). One billing bug found and fixed (below). |
| Cap uses real time at x1 / x4 / x16 | Confirmed (released exactly one real window later at every speed). Three deviations found and fixed: pause, stalled frame, offline catch-up. |
| Mission 3 and 8 counters agree with the ledger | Agree with the ledger window, the decision records and the balance drop; grants are not counted as spend. |
| Skill execution costs no AI decision | Confirmed: 0 AI records, 0 Compute, 0 tokens over 10 game minutes and over a 1 h offline catch-up; launching a skill costs the one `run_skill` decision. |
| Real provider model, limits, costs | **Not measured: provider unavailable here.** The Axis/Relais path only runs in the engine server (`rtype.Http`, `AXIS_API_KEY` / `AXIS_GATEWAY_KEY` env); the headless runner and the agent runtime have neither a key nor network access. Nothing about the real model, its limits or its costs is recorded because none of it is verified. The scripted section below tests our side of the path (usage fields in, billing out), not the vendor. |

## Fixes in this PR

1. `Sim:onAiResponse` billed an **invalid** reply (prose, unknown tool, bad args) on the estimate even when the provider reported its usage. It now bills and counts toward the hourly cap the real tokens whenever usage is reported; replies with no usage (HTTP error, network error, timeout) are still billed on the estimate (input + 40 output), never free, as `compute.luau` documents.
2. `Clock.advance` now adds real seconds to the AI budget clock itself: time paused and the part of a stalled frame dropped by `maxStepsPerFrame` used to be lost (10 s paused read 0 s; a 60 s stall read 40 s).
3. `Offline.run` counts the whole absence as real time (it used `ticks / speed`: 2 h away at x16 read 7.5 min).

## Open points (not changed, for the owner)

- **Failures cost the player.** A timeout or HTTP 500 still bills input + 40 tokens (0.6 to 0.7 Compute, 24 to 28 cr in the run below). That is the documented design; if outages should be free, `Sim:onAiResponse` is the one place to change, but then a failing provider costs nothing while still burning the hourly cap.
- **The hourly budget is not saved.** `AiQueue.usage` and `realTicks` are not in the save, so quitting and reloading resets the cap. Harmless with the stub; with the real provider the cap must be owned by the server, not the client session ([ENGINE]/server follow-up).
- **Overrun write-off.** A decision is sent when the balance covers the estimate; a bigger real answer can only take the balance to 0, the rest is written off (the ledger and the mission counters still count it). See the probe in section 2.
- **Two estimates.** The `tokens est` log line compares real tokens with the provider's estimate (system + user + 150 max output), the billing on send uses input + 40. Both are intentional; the real-vs-estimate drift should be read from `real_tokens` records once a real run exists.

# Measured output
## 1. Constants and rounding

| tokens | Compute billed | credits | note |
|---:|---:|---:|---|
| 1 | 0.1 | 4 |  |
| 99 | 0.1 | 4 |  |
| 100 | 0.1 | 4 |  |
| 101 | 0.2 | 8 |  |
| 1000 | 1.0 | 40 |  |
| 1001 | 1.1 | 44 |  |
| 1500 | 1.5 | 60 |  |
| 2640 | 2.7 | 108 |  |
| 10000 | 10.0 | 400 |  |

## 2. Stub run: decision records vs ledger

18 stub decisions in 20 game minutes: 11538 tokens, 12.5 Compute in the records, 12.5 in the ledger (`lifetimeTotal`), 12.5 off the balance, queue tokens 11538.

Overrun probe: 1.0 Compute, a decision estimated at 840 tokens (0.9) answered with 2,000 real tokens (2.0): ledger and mission counters see 2.0, the balance only drops 1.0 (it stops at 0), so 1.0 Compute is written off.

## 3. Provider path (scripted fake Axis/Relais): estimate vs actual, failures, invalid replies

| # | outcome | input est | tokens sent est | real in+out | queue/ledger tokens | Compute | credits |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | ok | 900 | 940 | 945 | 945 | 1.0 | 40 |
| 2 | provider error: model_http_500 | 550 | 590 | no usage | 590 | 0.6 | 24 |
| 3 | invalid response: no JSON object in reply | 850 | 890 | 880 | 880 | 0.9 | 36 |
| 4 | ok | 1200 | 1240 | 1260 | 1260 | 1.3 | 52 |
| 5 | provider error: timeout | 608 | 648 | no usage | 648 | 0.7 | 28 |
| 6 | invalid response: unknown or unequipped tool: dig | 780 | 820 | 805 | 805 | 0.9 | 36 |
| 7 | invalid response: unknown or unequipped tool: dig | 780 | 820 | 805 | 805 | 0.9 | 36 |

7 settled decisions (5 failed or invalid) over 600 real seconds; ledger 6.3 Compute = 252 cr; balance drop 6.3; queue tokens 5933.

## 4. Hourly token cap against real time at x1 / x4 / x16

The cap is exercised with a 6,000-token / 120 s window (same code, smaller numbers, so a run takes seconds). The first 6,000 tokens are spent through the queue at real second 0; then real time is fed in 0.25 s frames.

| speed | agent while capped | game s when released | real s when released | queue clock after 600 real s |
|---:|---|---:|---:|---:|
| x1 | no_compute, server budget message | 120.0 | 120.00 | 600.00 |
| x4 | no_compute, server budget message | 480.0 | 120.00 | 600.00 |
| x16 | no_compute, server budget message | 1920.0 | 120.00 | 600.00 |

Deviations the pre-fix clock had (steps only, 1/speed each): paused time and dropped stall time were not counted (10 s paused read 0 s, a 60 s stall read 40 s at x1), and an absence counted ticks/speed (2 h away at x16 read 7.5 min). Fixed in `sim/clock.luau` and `sim/offline.luau`; the budget itself is still not saved (see Open points).

## 5. Mission 3 and 8 counters vs the ledger

Mission 3 after 150 game seconds: counter shows `312 / 1000 cr revenue  -  Compute 1.4 / 15`; ledger window 1.4, decision records 1.4, balance drop 1.4.
Mission 8 after two pauses: counter shows `2 / 3 alerts resolved  -  Monitor Compute 1.2 / 10`; Monitor ledger window 1.2, Monitor decision records 1.2.

## 6. Skills and offline cost nothing

Skill run, 10 game minutes: 8 skill-step records, 0 AI records, ledger 0.0 -> 0.0 Compute, queue tokens 0 -> 0, revenue +2100 cr.
Same 10 minutes with the stub AI deciding instead: 5.5 Compute, revenue +1558 cr.

## Checks

| result | check |
|---|---|
| PASS | config: 1,000 tokens per Compute |
| PASS | config: 40 credits per Compute, packs of 5 (200 cr) |
| PASS | config: per-decision round-up step 0.1 |
| PASS | config: 400,000 tokens per rolling real hour |
| PASS | rounding: every sample is rounded UP to the 0.1 step |
| PASS | pack: 1 pack = 200 cr for 5 Compute |
| PASS | pack: refused without credits and for fractional packs |
| PASS | stub run: ran decisions |
| PASS | stub run: records' Compute == ledger lifetime total |
| PASS | stub run: ledger == balance drop |
| PASS | stub run: AiQueue tokens == settled tokens in the records |
| PASS | stub run: every decision billed on the 0.1 step |
| PASS | stub run: 2 packs cost 400 cr and add 10 Compute |
| PASS | overrun: balance never goes negative, the ledger keeps the full bill |
| PASS | provider run: scripted failures and invalid replies happened |
| PASS | provider run: every decision's Compute == round-up of its settled tokens |
| PASS | provider run: ledger == records' Compute |
| PASS | provider run: ledger == balance drop (no clamp) |
| PASS | provider run: queue tokens == settled tokens |
| PASS | provider run: an invalid reply that reports usage is billed on the real tokens |
| PASS | provider run: a reply with no usage (500, timeout) is billed on the estimate, never free |
| PASS | cap x1: blocked with the server message while capped |
| PASS | cap x1: released after exactly one real window (120 s), not game time |
| PASS | cap x1: the agent decides again after the release |
| PASS | cap x1: queue clock == real seconds fed (600.00 of 600) |
| PASS | cap x4: blocked with the server message while capped |
| PASS | cap x4: released after exactly one real window (120 s), not game time |
| PASS | cap x4: the agent decides again after the release |
| PASS | cap x4: queue clock == real seconds fed (600.00 of 600) |
| PASS | cap x16: blocked with the server message while capped |
| PASS | cap x16: released after exactly one real window (120 s), not game time |
| PASS | cap x16: the agent decides again after the release |
| PASS | cap x16: queue clock == real seconds fed (600.00 of 600) |
| PASS | cap: real time keeps passing while paused (10 s paused -> clock 10 s) |
| PASS | cap: a stalled 60 s frame at x16 still counts 60 real seconds |
| PASS | cap: a 2 h absence counts 2 real hours at any speed |
| PASS | mission 3: opens after 1 and 2 are claimed |
| PASS | mission 3: shown counter == ledger window |
| PASS | mission 3: shown counter == sum of decision records since it opened |
| PASS | mission 3: shown counter == balance drop |
| PASS | mission 3: counter is above zero (the run really decided) |
| PASS | mission 3: a Compute grant is not counted as spend |
| PASS | mission 3: over 15 Compute fails the mission |
| PASS | mission 8: opens once the command center is built |
| PASS | mission 8: shown counter == Monitor ledger window |
| PASS | mission 8: shown counter == sum of Monitor decision records since it opened |
| PASS | mission 8: the Monitor really spent Compute |
| PASS | mission 8: other agents' decisions are not counted |
| PASS | skill run: the skill earned |
| PASS | skill run: skill steps were logged |
| PASS | skill run: no AI decision, no Compute, no tokens |
| PASS | skill run: the same minutes with an AI agent do cost Compute (control) |
| PASS | offline catch-up: no Compute, no tokens |
| PASS | skill run: calling run_skill bills the one decision that launched it, the loop after it is free |
