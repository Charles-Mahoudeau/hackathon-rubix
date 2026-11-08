# Map choreography QA (GR5-104)

Implements GR5-103 (spec) + GR5-61 (art direction) on the real map. Pure rules live in `scripts/client/map_life.luau`,
actors/berths/budgets in `scripts/client/fleet_map.luau`, station chips/turrets in `system_map.luau` / `station_fx.luau`,
nodes in `scripts/ui/shell.luau`. Numbers: `scripts/config/ships.luau` (`map_fx.life`) and `scripts/config/screens.luau`.

## Controlled debug setup
1. Set `qaTour = "map"` in `scripts/config/debug.luau` (temporary; `tests/test_qa_tour.luau` asserts it is `false`).
2. `tools/qa_capture.sh <aylo-runtime> out_dir 72` (one window shot per second; the step name is in the feed header).
3. Put `qaTour` back to `false`.

`Tour.mapSteps` runs on the prepared T5 company: ambient (mining, return, dock), ambient-later, select-ship (halo),
station-alert (fills the depot stock to 97% so the station chip goes FULL from `alertTrack`), pause, pause-later (identical
positions), reduced-motion (`MOTION: REDUCED`), full-motion, raid-setup (a real hostile raid + privateer intercept) and
raid-fight/raid-after (the real `sim.raid.fights` entry; the depot turret only engages within 260 px of it).

## Evidence (`docs/qa/`, real runtime, 1280x720)
- `gr5-104-before-map.png`: baseline (fa71571).
- `-0-ambient`, `-1-working`: MINE badges, role tags (LOG/MON), station IDLE chip, OFF MAP list for unplaced planets.
- `-2-docking-selected`: DOCK badge, selection halo.
- `-3-station-alert-paused`: FULL station alert while paused; frames 20 and 24 of the capture show identical positions.
- `-4-reduced-motion`: reduced motion, positions still follow the sim.
- `-5-raid-fight`, `-6-raid-after`: real combat (FIGHT counter, ATTACKED/HULL badges, turret reacting to the real fight).
- Crowded/overflow (`+N` chips, numbered markers + legend, no hidden names) is covered headless by `tests/test_map_life.luau`
  and `tests/test_fleet_map.luau` (24-ship case).

## Not available in the sim (reported, not faked)
No station-damage state; no station-attacked event (turrets react only to real raid fights); abandoned planets have no map
position (listed under OFF MAP); no inspector for NPC overflow (counts only); no camera, so no off-screen selection nudge.
Muzzle VFX belongs to GR5-100, audio to GR5-99.

## Depot size and gaps (GR5-104 follow-up)

The HMC depot is 64-80 px wide at every stage (`map.home.fit` 80x80, no growth per stage), hangs right of Kessa (dx 116, dy 10) and every pair of stations/planets keeps `map.gap` (24 px). Frames at 1280x720, T5 company: `docs/qa/gr5-104-depot-t5-map.png`, `docs/qa/gr5-104-depot-t5-feed.png` (feed lines read `-> ...`).

Market stations follow the same budget: `markets.*.fit` is 80x80 px, and a station that stands beside its node ends `labelClear` (6 px) above the node's label, so the name and "Tn market" lines never cross a sprite (`tests/test_stations.luau`). Frame: `docs/qa/gr5-104-markets-t5-map.png`.
