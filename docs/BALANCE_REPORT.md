# GRIDMIND pacing report

Scripted player on the stub AI, 180.0 game-min per run, x1, seeds 1, 2, 3. Targets from spec §6.7, tolerance +/-30%; off by more means tune `balance.luau`, not logic.

## Tier timings (game minutes, median over seeds)

| Tier | Target | Reached | Deviation | Status |
|---|---|---|---|---|
| T2 | - | 5.2 | - | no target |
| T3 | 25.0 | 27.2 | +9% | OK |
| T4 | 60.0 | 58.2 | -3% | OK |
| T5 | 120.0 | 123.4 | +3% | OK |

**Verdict:** every tier is within tolerance.

## Per seed (game minutes at which each tier starts)

| Seed | T2 | T3 | T4 | T5 | Final credits | Decisions |
|---|---|---|---|---|---|---|
| 1 | 5.0 | 27.2 | 58.4 | 121.5 | 100,110 | 223 |
| 2 | 5.2 | 27.5 | 57.6 | 123.4 | 95,256 | 253 |
| 3 | 6.4 | 27.0 | 58.2 | 127.2 | 92,092 | 217 |

## Credits per tier (seed 1)

| Tier | Starts (min) | Credits at start | Revenue at start | Income during tier (cr/min) |
|---|---|---|---|---|
| T1 | 0.0 | 500 | 0 | 338 |
| T2 | 5.0 | 2,192 | 1,692 | 584 |
| T3 | 27.2 | 1,252 | 14,652 | 1,569 |
| T4 | 58.4 | 6,784 | 63,684 | 2,479 |
| T5 | 121.5 | 950 | 220,050 | 1,740 |

## Credits timeline (seed 1)

| Min | Tier | Credits | Lifetime revenue |
|---|---|---|---|
| 5.0 | T2 | 992 | 1,692 |
| 10.0 | T2 | 932 | 3,132 |
| 15.0 | T2 | 4,252 | 7,452 |
| 20.0 | T2 | 7,132 | 10,332 |
| 25.0 | T2 | 9,812 | 13,212 |
| 30.0 | T3 | 2,692 | 16,092 |
| 35.0 | T3 | 5,372 | 18,972 |
| 40.0 | T3 | 2,124 | 21,924 |
| 45.0 | T3 | 4,604 | 28,404 |
| 50.0 | T3 | 3,824 | 36,324 |
| 55.0 | T3 | 12,584 | 49,284 |
| 60.0 | T4 | 6,784 | 63,684 |
| 65.0 | T4 | 21,184 | 78,084 |
| 70.0 | T4 | 38,264 | 95,364 |
| 75.0 | T4 | 55,344 | 112,644 |
| 80.0 | T4 | 68,104 | 125,604 |
| 85.0 | T4 | 80,864 | 138,564 |
| 90.0 | T4 | 99,144 | 157,044 |
| 95.0 | T4 | 113,104 | 171,204 |
| 100.0 | T4 | 118,904 | 177,204 |
| 105.0 | T4 | 127,104 | 185,604 |
| 110.0 | T4 | 139,384 | 198,084 |
| 115.0 | T4 | 145,664 | 204,564 |
| 120.0 | T4 | 156,744 | 215,844 |
| 125.0 | T5 | 4,350 | 223,650 |
| 130.0 | T5 | 7,750 | 227,250 |
| 135.0 | T5 | 21,710 | 241,410 |
| 140.0 | T5 | 31,110 | 251,010 |
| 145.0 | T5 | 38,590 | 258,690 |
| 150.0 | T5 | 41,990 | 262,290 |
| 155.0 | T5 | 52,590 | 273,090 |
| 160.0 | T5 | 64,670 | 285,570 |
| 165.0 | T5 | 76,950 | 298,050 |
| 170.0 | T5 | 83,230 | 304,530 |
| 175.0 | T5 | 86,630 | 308,130 |
| 180.0 | T5 | 100,110 | 321,810 |

## Purchases (seed 1)

drill_mk2 @ 5.0 min, hold_mk2 @ 8.2 min, engine_mk2 @ 10.4 min, warehouse @ 27.2 min, ship2 @ 37.4 min, drill_mk3 @ 43.3 min, hold_mk3 @ 47.0 min, engine_mk3 @ 47.2 min, trading_post @ 51.7 min, logistics_hub @ 58.4 min, command_center @ 121.5 min

## AI load

Seed 1: 223 decisions in 180.0 real min at x1 = 1.2 per real minute; AI tokens counted in the last real hour: 61,729 (cap 400,000 per real hour, spec §10.4).

