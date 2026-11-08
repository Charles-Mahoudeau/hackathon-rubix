# Station sprites — Wenrexa Space Modular Buildings

Source: https://wenrexa.itch.io/space-full-assets-pack (177 PNG modules).
License: CC0 1.0 per the itch.io page and the OpenGameArt mirror, and the author's "FULL FREE" devlog (no attribution required).
Verified from search results on 2026-11-07; re-check the itch page at download time. Credits are optional; we list the author anyway.

Pipeline: raw PNG -> `assets/shaders/palette_remap.glsl` via `scripts/client/remap.luau` (8-colour theme, corporation neon) -> emissive-only bloom params from `scripts/render/vfx/bloom.luau`. Entry point: `scripts/client/stations.luau` (`Stations.entities(id, state, position, scale)`).
Config: `scripts/config/stations.luau` (modules + offsets, luminance cuts, corporation per station, idle/active swap). Gate: `tests/test_stations.luau`.
The pack is coloured, so the remap luminance cuts are per station (grey-plated HMC needs a higher neon cut). idle/active scales the whole sprite (`brightness`) and its emissive pixels (`emissiveScale`) by alpha only, so output stays on the palette.
GR5-52: the system map draws them (`scripts/client/system_map.luau` `SystemMap.stations`). The depot at Kessa grows with the warehouse, trading post, logistics hub and command center (`stages` in the config); built outposts show on their planet; Orbis, Halcyon and Meridian show once unlocked. Turrets are animated by `scripts/client/station_fx.luau`. Gate: `tools/check_station_assets.sh` (every file exists). Credits: `CREDITS_STATIONS.md`.
Not drawn: Bullets and the Ship_0x_Player sets (kept under `raw/`). The bloom blur composite is still not applied by anything in the repo, only its per-state params exist.
