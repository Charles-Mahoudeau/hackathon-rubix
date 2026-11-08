-- The cyber-clean theme (GR5-3): the ONLY place a colour is written. 8 colours, as 0xRRGGBB.
-- Everything else (UI, planets, backgrounds, asteroids, sprite remap) names a colour from `palette` and nothing else.
-- tools/check_palette.sh fails the build if another file spells a hex colour.
return {
  palette = {
    bg = 0x05070F,      -- screen background
    panel = 0x0C1222,   -- panel fill
    text = 0xE8F0FF,    -- primary text
    dim = 0x7C8BAA,     -- secondary text, borders (alpha), locked things; 5:1 over panel (tests/test_ui_lint.luau)
    cyan = 0x19E6FF,    -- the player's corporation
    magenta = 0xFF2BD6, -- rival corporation A
    amber = 0xFFB020,   -- rival corporation B, warnings, errors (with the glitch)
    green = 0x9CFF2E,   -- success, positive deltas
  },

  -- Alphas laid over the palette, so no extra colour is needed: a border is `dim` at 0.28 over `panel`.
  -- chromeFill: the opaque backing of a skinned panel (the skin itself is hollow), so the world never shows through the UI.
  alpha = { panelFill = 0.88, chromeFill = 1.0, line = 0.28, hover = 0.14, pressed = 0.24, locked = 0.55 },

  -- One neon per corporation. Sprites are greyscale and remapped onto the ramp of their corporation by the shader.
  corps = { player = "cyan", rivalA = "magenta", rivalB = "amber" },
  -- Greyscale remap ramp, dark to light; the neon name is filled in per corporation (assets/shaders/palette_remap.glsl).
  remapRamp = { "bg", "panel", "$neon", "text" },

  semantic = { success = "green", warning = "amber", error = "amber", neutral = "dim", player = "cyan" },

  -- Design tokens (M9): what each palette colour MEANS on screen. Screens name a token, never a raw colour, so a branch row,
  -- an agent light and an alert read the same everywhere. Values are palette names, checked by tests/test_art.luau.
  tokens = {
    surface = { screen = "bg", panel = "panel", field = "bg", row = "panel", border = "dim" },
    text = { primary = "text", secondary = "dim", accent = "cyan", disabled = "dim" },
    -- One accent per branch row; raiding takes magenta, the rival-A neon, because that is where the player meets rivals.
    branch = { mining = "cyan", refining = "text", salvage = "green", raiding = "magenta" },
    -- Agent and ship lights. `acting` and `active` are the same light; unknown states fall back to `idle`.
    state = { idle = "dim", acting = "cyan", active = "cyan", pending = "amber", executing = "green", paused_error = "amber",
      no_compute = "amber", locked = "dim" },
    alert = { info = "cyan", success = "green", warning = "amber", error = "amber" },
  },

  font = { path = "fonts/jetbrains_mono.json" }, -- the single font of the game (SIL OFL 1.1, assets/fonts/OFL.txt)
  type = { title = 22, heading = 16, body = 14, small = 12 },

  -- Screen layout in view pixels. The window and the engine's virtual resolution are `view` (project.luau).
  -- Pixel Holo UI skin (Helianthus Games, itch.io), nine-patches over the greyscale art. `slice` is the border kept at native
  -- size { left, top, right, bottom } in texture pixels (the corner pieces of the pack); `tint` names a palette colour
  -- multiplied over the art: the art is a light-grey line around a dark navy fill, so the `dim` tint gives a slate hairline
  -- around a near-black fill, `cyan` a cyan line around deep blue.
  panelSkin = { texture = "ui/pixel_holo_ui/button_simple/Normal/button_normal.png", slice = { 3, 2, 3, 2 }, tint = "dim" },
  -- Buttons: the `button` set (double line). Only the tint changes with the state (the engine recolours, it does not swap
  -- textures): rest = the button's own colour (`dim` idle, `cyan` selected), hover = `text`, pressed = `cyan` (`dim` if cyan).
  -- The selected one also takes the lighter `active` texture.
  buttonSkin = { normal = "ui/pixel_holo_ui/button/Normal/button_normal.png", active = "ui/pixel_holo_ui/button/Hover/button_hover.png",
    slice = { 5, 6, 5, 6 }, hover = "text", pressed = "cyan" },
  -- Gauges: the horizontal scrollbar pieces, 8 px tall (3 + 2 + 3), as track and as fill.
  gaugeSkin = { track = "ui/pixel_holo_ui/scrollbar_horizontal/Normal/scrollbar_horizontal.png",
    fill = "ui/pixel_holo_ui/scrollbar_horizontal/Clicked/scrollbar_horizontal_clicked.png", slice = { 3, 3, 3, 3 }, trackTint = "dim" },
  -- Plain (non-skinned) buttons lean this much towards their accent colour on hover / press.
  mix = { hover = 0.25, pressed = 0.45 },

  layout = { view = { w = 1280, h = 720 }, topBar = 48, nav = 176, feed = 132, gap = 8, pad = 12, radius = 4 },
}
