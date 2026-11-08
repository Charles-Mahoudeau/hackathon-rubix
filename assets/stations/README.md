# Station sprites — Wenrexa Space Modular Buildings

Source: https://wenrexa.itch.io/space-full-assets-pack (177 PNG modules).
License: CC0 1.0 per the itch.io page and the OpenGameArt mirror, and the author's "FULL FREE" devlog (no attribution required).
Verified from search results on 2026-11-07; re-check the itch page at download time. Credits are optional; we list the author anyway.

Pipeline: raw PNG -> `shaders/palette_remap` (shared with GR5-3, 8-colour theme) -> emissive-only bloom. No raw pack colours may be drawn.
Config: `config/stations.luau`. Raw files go in `assets/stations/raw/` (not committed until picked).

Status (2026-11-08): sprites imported under `assets/stations/raw/` (RandomBuildings B01–B26 + Platform[PLAYER]; DifferentTurrets, Bullets, MiniAsteroids and Ship_01/02_Player are out of scope for GR5-18, kept for reuse). Module subsets and offsets per station are filled in `config/stations.luau`.
Pending GR5-3: `shaders/palette_remap` and the 8-colour palette don't exist yet, so remap + emissive bloom and the idle/active swap are config-only until it lands. Raw pack colours (red/grey/cyan) must not ship drawn directly.
