# Command-center price counterfactual (GR5-63)

Scripted player, stub AI, 180.0 game-min, x1. Targets T3 25 / T4 60 / T5 120 min, +/-30%. Only `shop.items.command_center.cost` differs between rows.

## Missions: no claim

| Price | Seed | T3 | T4 | T5 | Rev@T5 | Rep@T5 | Compute billed@T5 (cr) | Compute billed total (cr) | Final rev | Final rep | Missions done (min) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 160,000 | 1 | 24.4 | 51.6 | 125.6 | 221,599 | 3 | 4,612 | 8,292 | 305,136 | 3 | 1@6.6 |
<!-- seed 1 purchases at 160,000: drill_mk2@5.0, hold_mk2@8.2, engine_mk2@10.4, warehouse@24.4, ship2@34.2, drill_mk3@40.4, hold_mk3@42.7, engine_mk3@44.7, trading_post@46.0, logistics_hub@51.6, command_center@125.6 -->
| 160,000 | 2 | 24.7 | 51.3 | 127.0 | 223,787 | 3 | 4,692 | 8,084 | 307,666 | 3 | 1@6.9 |
| 160,000 | 3 | 24.6 | 52.0 | 122.3 | 222,969 | 3 | 4,364 | 8,684 | 294,867 | 3 | 1@6.4 |
| 160,000 | median | 24.6 | 51.6 | 125.6 | | | | | | | |
| 15,000 | 1 | 24.4 | 51.6 | 58.6 | 75,199 | 2 | 1,348 | 8,292 | 305,136 | 3 | 1@6.6 |
<!-- seed 1 purchases at 15,000: drill_mk2@5.0, hold_mk2@8.2, engine_mk2@10.4, warehouse@24.4, ship2@34.2, drill_mk3@40.4, hold_mk3@42.7, engine_mk3@44.7, trading_post@46.0, logistics_hub@51.6, command_center@58.5 -->
| 15,000 | 2 | 24.7 | 51.3 | 57.3 | 76,953 | 2 | 1,300 | 8,084 | 307,666 | 3 | 1@6.9 |
| 15,000 | 3 | 24.6 | 52.0 | 57.8 | 75,426 | 2 | 1,516 | 8,684 | 294,867 | 3 | 1@6.4 |
| 15,000 | median | 24.6 | 51.6 | 57.8 | | | | | | | |

## Missions: auto-claim

| Price | Seed | T3 | T4 | T5 | Rev@T5 | Rep@T5 | Compute billed@T5 (cr) | Compute billed total (cr) | Final rev | Final rep | Missions done (min) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 160,000 | 1 | 23.9 | 51.2 | 120.8 | 222,127 | 3 | 4,484 | 9,060 | 306,420 | 3 | 1@6.6 |
| 160,000 | 2 | 21.7 | 52.0 | 127.0 | 220,479 | 3 | 4,756 | 8,660 | 308,200 | 3 | 1@6.9 |
| 160,000 | 3 | 22.8 | 47.6 | 121.9 | 220,329 | 3 | 4,524 | 9,036 | 305,242 | 3 | 1@6.4 |
| 160,000 | median | 22.8 | 51.2 | 121.9 | | | | | | | |
| 15,000 | 1 | 23.9 | 51.2 | 58.1 | 76,209 | 2 | 1,380 | 9,060 | 306,420 | 3 | 1@6.6 |
| 15,000 | 2 | 21.7 | 52.0 | 56.9 | 80,903 | 2 | 1,332 | 8,660 | 308,200 | 3 | 1@6.9 |
| 15,000 | 3 | 22.8 | 47.6 | 55.3 | 76,113 | 2 | 1,324 | 9,036 | 305,242 | 3 | 1@6.4 |
| 15,000 | median | 22.8 | 51.2 | 56.9 | | | | | | | |

## Sensitivity sweep (no claim, median of seeds)

| Price | T5 median (min) | vs 120 target | Rep at T5 (seed 1) | Revenue at T5 (seed 1) |
|---|---|---|---|---|
| 15,000 | 57.8 | -52% | 2 | 75,199 |
| 40,000 | 66.3 | -45% | 2 | 104,479 |
| 80,000 | 79.7 | -34% | 2 | 139,115 |
| 120,000 | 101.0 | -16% | 2 | 182,709 |
| 160,000 | 125.6 | +5% | 3 | 221,599 |
| 200,000 | 152.6 | +27% | 3 | 262,350 |
