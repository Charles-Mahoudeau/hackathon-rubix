# Decisions

- 2026-11-07 — Planets: one parameterised fragment shader (`assets/shaders/planet.glsl`) rewritten from Deep-Fold's MIT algorithm rather than copying defold-pixel-planets files — that repo has no license file (GitHub reports none), only a credit-to-Deep-Fold README.
- 2026-11-07 — Planets: one shader for all 4 planets (land/water/clouds via uniforms; waterLevel 0 + no clouds = barren/lava), instead of one shader per Deep-Fold variant — simplest, one asset pipeline.
- 2026-11-07 — Planets: drawn as an `rtype.SpriteRenderer` on a shared 4x4 white texture (`assets/textures/white.png`) because `ShapeRenderer` has no material field. That texture is shared by all planets, not a per-planet asset.
- 2026-11-07 — Planets: palette is passed to the shader per material from `GameConfig.palette` (placeholder 8 colours until GR5-3); `Planet.new` asserts every colour name is in the palette, so no second remap pass is needed.
- 2026-11-07 — Trade planets (Meridian Base, Halcyon Port) get the same rotating planet treatment as harvest planets (issue default).
- 2026-11-07 — Config lives in `scripts/config/planets.luau` (only `scripts/` is auto-loaded, no `require`); globals `GameConfig`, `Planet`.
