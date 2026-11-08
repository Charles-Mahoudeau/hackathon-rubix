# Station sprites — Wenrexa Space Modular Buildings

Source: https://wenrexa.itch.io/space-full-assets-pack (177 PNG modules).
License: CC0 1.0 per the itch.io page and the OpenGameArt mirror, and the author's "FULL FREE" devlog (no attribution required).
Verified from search results on 2026-11-07; re-check the itch page at download time. Credits are optional; we list the author anyway.

Pipeline: raw PNG -> `assets/shaders/palette_remap.glsl` via `scripts/client/remap.luau` (8-colour theme, corporation neon) -> emissive-only bloom params from `scripts/render/vfx/bloom.luau`. Entry point: `scripts/client/stations.luau` (`Stations.entities(id, state, position, scale)`).
Config: `scripts/config/stations.luau` (modules + offsets, luminance cuts, corporation per station, idle/active swap). Gate: `tests/test_stations.luau`.
The pack is coloured, so the remap luminance cuts are per station (grey-plated HMC needs a higher neon cut). idle/active scales the whole sprite (`brightness`) and its emissive pixels (`emissiveScale`) by alpha only, so output stays on the palette.
Not done: no screen places stations yet (the system map only shows harvest planets), and the bloom blur composite is not applied by anything in the repo, only its per-state params exist.
Unused pack folders (Platform[PLAYER], DifferentTurrets, Bullets, MiniAsteroids, Ship_0x_Player) are kept under `raw/` for reuse.
