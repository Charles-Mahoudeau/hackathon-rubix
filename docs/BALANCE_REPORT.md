# GRIDMIND pacing report

Scripted player on the stub AI, 180.0 game-min per run, x1, seeds 1, 2, 3. Targets from spec §6.7, tolerance +/-30%; off by more means tune `balance.luau`, not logic.

## Tier timings (game minutes, median over seeds)

| Tier | Target | Reached | Deviation | Status |
|---|---|---|---|---|
| T2 | - | 5.2 | - | no target |
| T3 | 25.0 | 24.6 | -2% | OK |
| T4 | 60.0 | 51.6 | -14% | OK |
| T5 | 120.0 | 125.6 | +5% | OK |

**Verdict:** every tier is within tolerance.

## Per seed (game minutes at which each tier starts)

| Seed | T2 | T3 | T4 | T5 | Final credits | Decisions |
|---|---|---|---|---|---|---|
| 1 | 5.0 | 24.4 | 51.6 | 125.6 | 81,236 | 264 |
| 2 | 5.2 | 24.7 | 51.3 | 127.0 | 83,966 | 257 |
| 3 | 6.4 | 24.6 | 52.0 | 122.3 | 70,567 | 276 |

## Credits per tier (seed 1)

| Tier | Starts (min) | Credits at start | Revenue at start | Income during tier (cr/min) |
|---|---|---|---|---|
| T1 | 0.0 | 500 | 0 | 338 |
| T2 | 5.0 | 2,192 | 1,692 | 644 |
| T3 | 24.4 | 772 | 14,172 | 1,582 |
| T4 | 51.6 | 499 | 57,199 | 2,221 |
| T5 | 125.6 | 1,499 | 221,599 | 1,536 |

## Credits timeline (seed 1)

| Min | Tier | Credits | Lifetime revenue |
|---|---|---|---|
| 5.0 | T2 | 992 | 1,692 |
| 10.0 | T2 | 932 | 3,132 |
| 15.0 | T2 | 4,012 | 7,212 |
| 20.0 | T2 | 7,892 | 11,292 |
| 25.0 | T3 | 772 | 14,172 |
| 30.0 | T3 | 4,412 | 18,012 |
| 35.0 | T3 | 1,292 | 20,892 |
| 40.0 | T3 | 4,308 | 24,108 |
| 45.0 | T3 | 488 | 32,988 |
| 50.0 | T3 | 7,299 | 43,999 |
| 55.0 | T4 | 6,499 | 63,199 |
| 60.0 | T4 | 25,499 | 82,399 |
| 65.0 | T4 | 32,979 | 90,079 |
| 70.0 | T4 | 55,975 | 113,275 |
| 75.0 | T4 | 70,375 | 127,675 |
| 80.0 | T4 | 81,415 | 139,115 |
| 85.0 | T4 | 88,975 | 146,875 |
| 90.0 | T4 | 100,359 | 158,459 |
| 95.0 | T4 | 112,609 | 171,109 |
| 100.0 | T4 | 116,809 | 175,509 |
| 105.0 | T4 | 131,027 | 189,927 |
| 110.0 | T4 | 137,827 | 197,127 |
| 115.0 | T4 | 148,339 | 207,839 |
| 120.0 | T4 | 153,539 | 213,439 |
| 125.0 | T4 | 160,299 | 220,399 |
| 130.0 | T5 | 14,499 | 234,799 |
| 135.0 | T5 | 21,633 | 242,133 |
| 140.0 | T5 | 28,238 | 249,138 |
| 145.0 | T5 | 33,306 | 254,806 |
| 150.0 | T5 | 40,650 | 262,350 |
| 155.0 | T5 | 53,950 | 275,850 |
| 160.0 | T5 | 57,688 | 279,788 |
| 165.0 | T5 | 65,938 | 288,438 |
| 170.0 | T5 | 74,012 | 296,912 |
| 175.0 | T5 | 76,233 | 299,733 |
| 180.0 | T5 | 81,236 | 305,136 |

## Purchases (seed 1)

drill_mk2 @ 5.0 min, hold_mk2 @ 8.2 min, engine_mk2 @ 10.4 min, warehouse @ 24.4 min, ship2 @ 34.2 min, drill_mk3 @ 40.4 min, hold_mk3 @ 42.7 min, engine_mk3 @ 44.7 min, trading_post @ 46.0 min, logistics_hub @ 51.6 min, command_center @ 125.6 min

## AI load

Seed 1: 264 decisions in 180.0 real min at x1 = 1.5 per real minute; AI tokens counted in the last real hour: 88,025 (cap 400,000 per real hour, spec §10.4).

