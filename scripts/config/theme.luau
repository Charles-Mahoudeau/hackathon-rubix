-- The cyber-clean theme (GR5-3): the ONLY place a colour is written. 8 colours, as 0xRRGGBB.
-- Everything else (UI, planets, backgrounds, asteroids, sprite remap) names a colour from `palette` and nothing else.
-- tools/check_palette.sh fails the build if another file spells a hex colour.
return {
  palette = {
    bg = 0x05070F,      -- screen background
    panel = 0x0C1222,   -- panel fill
    text = 0xE8F0FF,    -- primary text
    dim = 0x6B7A99,     -- secondary text, borders (alpha), locked things
    cyan = 0x19E6FF,    -- the player's corporation
    magenta = 0xFF2BD6, -- rival corporation A
    amber = 0xFFB020,   -- rival corporation B, warnings, errors (with the glitch)
    green = 0x9CFF2E,   -- success, positive deltas
  },

  -- Alphas laid over the palette, so no extra colour is needed: a border is `dim` at 0.28 over `panel`.
  alpha = { panelFill = 0.88, line = 0.28, hover = 0.14, pressed = 0.24, locked = 0.55 },

  -- One neon per corporation. Sprites are greyscale and remapped onto the ramp of their corporation by the shader.
  corps = { player = "cyan", rivalA = "magenta", rivalB = "amber" },
  -- Greyscale remap ramp, dark to light; the neon name is filled in per corporation (assets/shaders/palette_remap.glsl).
  remapRamp = { "bg", "panel", "$neon", "text" },

  semantic = { success = "green", warning = "amber", error = "amber", neutral = "dim", player = "cyan" },

  font = { path = "fonts/jetbrains_mono.json" }, -- the single font of the game (SIL OFL 1.1, assets/fonts/OFL.txt)
  type = { title = 22, heading = 16, body = 14, small = 12 },

  -- Screen layout in view pixels. The window and the engine's virtual resolution are `view` (project.luau).
  -- Panel skin: Pixel Holo UI (Helianthus Games, itch.io), the Clean panel as a nine-patch. `slice` is the border kept at
  -- native size { left, top, right, bottom } in texture pixels; `tint` names a palette colour multiplied over the art.
  panelSkin = { texture = "ui/pixel_holo_ui/panel/Clean/panel.png", slice = { 15, 4, 15, 4 }, tint = "text" },

  layout = { view = { w = 1280, h = 720 }, topBar = 48, nav = 176, feed = 132, gap = 8, pad = 12, radius = 4 },
}
