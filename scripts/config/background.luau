-- Space backgrounds: one shader (assets/shaders/background.glsl), a few stacked layers per screen. Art numbers only here.
-- Colours are palette names (config/theme.luau). Ramp is empty space to dense core.

local config = {}

config.backgroundRender = {
	shaderPath = "shaders/background.glsl",
	texturePath = "textures/white.png",
	textureSize = 4, -- pixels of that texture
	pixels = 160, -- pixel grid of a layer
	octaves = 4,
}

-- Layers are listed back to front. mode 0 = nebula, 1 = dust and stars. layer = sprite draw layer (behind the galaxy at -100).
-- drift is noise scrolled per second: a faster front layer over a slower back one reads as parallax.
config.backgrounds = {
	default = {
		{ mode = 0, seed = 2.3, size = 5, drift = { x = 0.0015, y = 0 }, layer = -130, ramp = { "bg", "panel", "panel", "dim" } },
		{ mode = 1, seed = 6.1, size = 7, drift = { x = 0.004, y = 0 }, layer = -120, ramp = { "bg", "panel", "panel", "dim" }, starDensity = 0.012, stars = { "text", "dim" } },
	},
	map = {
		{ mode = 0, seed = 4.7, size = 6, drift = { x = 0.0012, y = 0.0004 }, layer = -130, ramp = { "bg", "panel", "dim", "dim" } },
		{ mode = 1, seed = 8.4, size = 8, drift = { x = 0.0035, y = 0.001 }, layer = -120, ramp = { "bg", "panel", "panel", "dim" }, starDensity = 0.015, stars = { "text", "cyan" } },
	},
}

return config
