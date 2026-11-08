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

local skinTexture
-- The panel nine-patch texture (client only, needs the engine's asset registry). Headless callers pass no skin at all.
function UiTheme.panelSkin()
	local cfg = Theme.panelSkin
	skinTexture = skinTexture or engine.assets.texture(cfg.texture)
	return { texture = skinTexture, slice = cfg.slice, color = UiTheme.color(cfg.tint, Theme.alpha.panelFill) }
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
