-- UI colour helpers over config/theme.luau. The engine's UI colours are linear { r, g, b, a } (docs/Ui.md), the theme's are
-- sRGB hex, so every UI colour goes through here. Nothing else in the UI spells a colour.
local Theme = require("@scripts/config/theme")

local UiTheme = {}

local function toLinear(c: number)
	if c <= 0.04045 then return c / 12.92 end
	return ((c + 0.055) / 1.055) ^ 2.4
end

-- Palette name -> { r, g, b } as sRGB 0..1 (what a shader writes to an sRGB-agnostic output).
function UiTheme.srgb(name: string)
	local hex = Theme.palette[name]
	assert(hex, "UiTheme: '" .. tostring(name) .. "' is not in the theme palette")
	return { bit32.extract(hex, 16, 8) / 255, bit32.extract(hex, 8, 8) / 255, bit32.extract(hex, 0, 8) / 255 }
end

-- Palette name (+ alpha, default 1) -> sRGB { r, g, b, a } for sprite tints and VFX.
function UiTheme.rgba(name: string, alpha: number?)
	local c = UiTheme.srgb(name)
	return { c[1], c[2], c[3], alpha or 1 }
end

-- Palette name (+ alpha, default 1) -> linear { r, g, b, a } for engine.ui.
function UiTheme.color(name: string, alpha: number?)
	local c = UiTheme.srgb(name)
	return { toLinear(c[1]), toLinear(c[2]), toLinear(c[3]), alpha or 1 }
end

-- The translucent panel fill, the hairline border (dim at low alpha) and the hover/pressed tints.
function UiTheme.panel() return UiTheme.color("panel", Theme.alpha.panelFill) end
function UiTheme.line() return UiTheme.color("dim", Theme.alpha.line) end
function UiTheme.hover(name: string?) return UiTheme.color(name or "cyan", Theme.alpha.hover) end
function UiTheme.pressed(name: string?) return UiTheme.color(name or "cyan", Theme.alpha.pressed) end

-- A palette colour moved `t` (0..1) towards another, in linear space; alpha stays the base's.
function UiTheme.mix(baseName: string, accentName: string, t: number, alpha: number?)
	local a, b = UiTheme.color(baseName), UiTheme.color(accentName)
	return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, alpha or 1 }
end

-- The UiButton of a plain (background) node. The engine paints the node with `normal` / `hovered` / `pressed` and the
-- default `normal` is opaque white, so a button must always spell its resting colour: opts.normal (the colour the node is
-- drawn with), else `base` (default "panel") at `alpha` (default 1). Transparent hit areas (alpha 0) get a faint accent
-- wash on hover; opaque ones lean towards the accent.
function UiTheme.button(action: string, accent: string, opts)
	opts = opts or {}
	local base, alpha = opts.base or "panel", opts.alpha or 1
	local normal = opts.normal or UiTheme.color(base, alpha)
	local hovered, pressed
	if alpha == 0 and not opts.normal then
		hovered, pressed = UiTheme.hover(accent), UiTheme.pressed(accent)
	else
		hovered = UiTheme.mix(base, accent, Theme.mix.hover, alpha)
		pressed = UiTheme.mix(base, accent, Theme.mix.pressed, alpha)
	end
	return { action = action, normal = normal, hovered = hovered, pressed = pressed, disabled = UiTheme.color("dim", Theme.alpha.locked) }
end

-- The UiButton of a skinned button: its tint at rest is the button's colour, then `text` on hover and `cyan` (`dim` when
-- the button is already cyan) when pressed.
function UiTheme.skinButton(action: string, colorName: string)
	local cfg = Theme.buttonSkin
	return { action = action, normal = UiTheme.color(colorName), hovered = UiTheme.color(cfg.hover),
		pressed = UiTheme.color(colorName == cfg.pressed and "dim" or cfg.pressed), disabled = UiTheme.color("dim", Theme.alpha.locked) }
end

local textures = {}
local function texture(path: string)
	textures[path] = textures[path] or engine.assets.texture(path)
	return textures[path]
end

-- The whole Pixel Holo skin (client only, needs the engine's asset registry): the panel nine-patch at the top level
-- (texture, slice, color) plus `button` and `gauge` sets. Headless callers pass no skin at all.
function UiTheme.panelSkin()
	local cfg, btn, gauge = Theme.panelSkin, Theme.buttonSkin, Theme.gaugeSkin
	return {
		texture = texture(cfg.texture), slice = cfg.slice, color = UiTheme.color(cfg.tint, Theme.alpha.panelFill),
		button = { normal = texture(btn.normal), active = texture(btn.active), slice = btn.slice },
		gauge = { track = texture(gauge.track), fill = texture(gauge.fill), slice = gauge.slice, trackColor = UiTheme.color(gauge.trackTint) },
	}
end

function UiTheme.count()
	local n = 0
	for _ in pairs(Theme.palette) do n += 1 end
	return n
end

local font
-- The one font of the game; loaded on first use (client only, needs the Text plugin).
function UiTheme.font()
	font = font or engine.assets.font(Theme.font.path)
	return font
end

return UiTheme
