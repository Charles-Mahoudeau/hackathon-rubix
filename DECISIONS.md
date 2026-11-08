# Decisions
- 2026-11-07 — Stations are static remapped sprites (no rotation). Reason: not rotating bodies; idle/active is a brightness/emissive swap in the remap pass.
- 2026-11-07 — Station visuals configured in `config/stations.luau` (data only), per "balance/config lives in config/*.luau".
- 2026-11-08 — Station modules picked from RandomBuildings B01–B26 (one distinct set of 4 per station, hub + 3 attached modules): HMC Depot = B08/B05/B14/B15 (grey cargo/utility), Orbis Exchange = B10/B09/B11/B26 (round hub), Halcyon Shipyards = B04/B01/B02/B16 (cross hub + docks), Meridian Institute = B12/B13/B19/B18 (round lab hub). Reason: simplest readable silhouettes per role; Platform[PLAYER] and the turret/ship/bullet sets left unused here.
