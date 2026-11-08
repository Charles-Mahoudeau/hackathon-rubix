-- Space backgrounds: one shader (assets/shaders/background.glsl), a few stacked layers per screen. Art numbers only here.
-- Colours are palette names (config/theme.luau). Ramp is empty space to dense core.

local config = {}

config.backgroundRender = {
	shaderPath = "shaders/background.glsl",
	texturePath = "textures/white.png",
	textureSize = 4, -- pixels of that texture
	pixelSize = 2, -- view pixels of one background pixel (square). Planets are ~1.4, so the grids read as one
	octaves = 4,
}

-- Layers are listed back to front. mode 0 = nebula, 1 = dust and stars. layer = sprite draw layer (behind the galaxy at -100).
-- drift is noise scrolled per second: a faster front layer over a slower back one reads as parallax; both are slow.
-- The ramps stop at `panel`: the nebula is never brighter than a panel, so text on it keeps its contrast. Stars are `dim`,
-- sparse (starDensity = share of background pixels) and blink off now and then (twinkle = per second).
config.backgrounds = {
	default = {
		{ mode = 0, seed = 2.3, size = 5, drift = { x = 0.0010, y = 0 }, layer = -130, ramp = { "bg", "bg", "panel", "panel" } },
		{ mode = 1, seed = 6.1, size = 7, drift = { x = 0.0025, y = 0 }, layer = -120, ramp = { "bg", "bg", "bg", "panel" }, starDensity = 0.0004, stars = { "dim", "dim" }, twinkle = 0.12 },
	},
	map = {
		{ mode = 0, seed = 4.7, size = 6, drift = { x = 0.0008, y = 0.0003 }, layer = -130, ramp = { "bg", "bg", "panel", "panel" } },
		{ mode = 1, seed = 8.4, size = 8, drift = { x = 0.0022, y = 0.0006 }, layer = -120, ramp = { "bg", "bg", "bg", "panel" }, starDensity = 0.0005, stars = { "dim", "dim" }, twinkle = 0.15 },
	},
}

return config
