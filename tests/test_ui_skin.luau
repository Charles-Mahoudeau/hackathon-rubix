-- GR5-50 gate (skin wiring; text fit lives in test_ui_lint.luau): the Pixel Holo skin is wired so nothing renders white or unreadable. Static lint over every screen spec, with
-- and without a skin. Headless: no engine calls (the skin textures are fake strings).
local Theme = require("@scripts/config/theme")
local Sim = require("@scripts/sim/sim")
local UiTheme = require("@scripts/ui/theme")
local Model = require("@scripts/ui/shell_model")
local Shell = require("@scripts/ui/shell")

local function eq(a, b) for i = 1, 4 do if math.abs(a[i] - b[i]) > 1e-6 then return false end end return true end

-- WCAG contrast of two palette colours.
local function lum(name)
  local c = UiTheme.srgb(name)
  local function lin(v) return v <= 0.03928 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4 end
  return 0.2126 * lin(c[1]) + 0.7152 * lin(c[2]) + 0.0722 * lin(c[3])
end
local function contrast(a, b) local x, y = lum(a), lum(b) if x < y then x, y = y, x end return (x + 0.05) / (y + 0.05) end

-- every text colour of the game stays readable on the panel fill and on the screen background
for _, name in ipairs({ "text", "dim", "cyan", "magenta", "amber", "green" }) do
  assert(contrast(name, "panel") >= 4.5, name .. " text on panel: " .. contrast(name, "panel"))
  assert(contrast(name, "bg") >= 4.5, name .. " text on bg: " .. contrast(name, "bg"))
end

-- skin config: 4-number slices, palette tints, nine-patch pieces of the pack
local function checkSlice(s, where) assert(#s == 4, where .. " slice") for _, v in ipairs(s) do assert(type(v) == "number" and v >= 1, where .. " slice") end end
checkSlice(Theme.panelSkin.slice, "panel") checkSlice(Theme.buttonSkin.slice, "button") checkSlice(Theme.gaugeSkin.slice, "gauge")
for _, name in ipairs({ Theme.panelSkin.tint, Theme.buttonSkin.hover, Theme.buttonSkin.pressed, Theme.gaugeSkin.trackTint }) do assert(Theme.palette[name], "skin tint " .. tostring(name)) end
assert(Theme.panelSkin.tint ~= "text", "panels are tinted dark, not left at the art's own grey-purple")

local skin = {
  texture = "fake-panel", slice = Theme.panelSkin.slice, color = UiTheme.color(Theme.panelSkin.tint, Theme.alpha.panelFill),
  button = { normal = "fake-btn", active = "fake-btn-active", slice = Theme.buttonSkin.slice },
  gauge = { track = "fake-track", fill = "fake-fill", slice = Theme.gaugeSkin.slice, trackColor = UiTheme.color(Theme.gaugeSkin.trackTint) },
}

local palette = {}
for name in pairs(Theme.palette) do palette[name] = UiTheme.color(name) end
local function paletteName(c) for name, p in pairs(palette) do if eq(p, { c[1], c[2], c[3], 1 }) then return name end end return nil end

local buttons, texts, images = 0, 0, 0
local function lint(spec, where, skinned)
  if spec.button then
    buttons += 1
    local b = spec.button
    assert(b.normal and b.hovered and b.pressed, where .. ": button " .. tostring(b.action) .. " spells every state")
    assert(not eq(b.normal, { 1, 1, 1, 1 }), where .. ": button " .. tostring(b.action) .. " rests white")
    local drawn = (spec.image and spec.image.color) or (spec.background and spec.background.color)
    assert(drawn and eq(drawn, b.normal), where .. ": button " .. tostring(b.action) .. " is drawn in a colour other than its `normal`")
    assert(not (spec.image and spec.background), where .. ": a button has one fill")
  end
  if spec.image then
    images += 1
    assert(spec.image.texture and #spec.image.slice == 4, where .. ": image slice")
  end
  if spec.text then
    texts += 1
    local c = spec.text.color
    local name = paletteName(c)
    assert(name and c[4] == 1, where .. ": text '" .. spec.text.text .. "' must be an opaque palette colour")
    assert(contrast(name, "panel") >= 4.5, where .. ": text '" .. spec.text.text .. "' unreadable")
  end
  for _, child in ipairs(spec.children or {}) do lint(child, where, skinned) end
end

local sim = Sim.new()
for tier = 1, 5 do
  sim.tier = tier
  for _, e in ipairs(Model.nav(tier, "map")) do
    for _, withSkin in ipairs({ false, true }) do
      local spec = Shell.spec(sim, e.id, { skin = withSkin and skin or nil })
      lint(spec, ("T%d/%s/%s"):format(tier, e.id, withSkin and "skin" or "plain"), withSkin)
    end
  end
end
assert(buttons > 100 and texts > 500 and images > 50, "the lint saw the shell")

-- skinned shell: nav, top bar buttons and the compute gauge use the pack
local function collect(spec, pred, out) out = out or {} if pred(spec) then out[#out + 1] = spec end for _, c in ipairs(spec.children or {}) do collect(c, pred, out) end return out end
sim.tier = 5
local spec = Shell.spec(sim, "map", { skin = skin })
local navButtons = collect(spec, function(n) return n.button and n.button.action:match("^nav%.") end)
assert(#navButtons >= 5, "nav buttons exist")
local active = 0
for _, n in ipairs(navButtons) do
  assert(n.image and (n.image.texture == "fake-btn" or n.image.texture == "fake-btn-active"), "nav button uses the button sprite")
  if n.image.texture == "fake-btn-active" then active += 1 end
end
assert(active == 1, "exactly the current screen is highlighted")
assert(#collect(spec, function(n) return n.image and n.image.texture == "fake-track" end) == 1, "compute gauge uses the pack track")
for _, n in ipairs(collect(spec, function(n) return n.image and n.image.texture == "fake-fill" end)) do
  assert(n.style.minWidth and n.style.minWidth >= Theme.gaugeSkin.slice[1] * 2, "a gauge fill never gets narrower than its two borders")
end

print("ui skin ok", buttons, texts, images)
