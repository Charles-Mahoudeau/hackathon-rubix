-- Planet look: the theme palette, and one fixed entry per MVP planet. Balance/art numbers live here only.

local Theme = require("@scripts/config/theme")

local config = {}

-- The 8-colour theme (config/theme.luau) is the only palette: looks below name its colours, lit to shadow.
config.palette = Theme.palette

config.planetRender = {
	pixels = 64, -- pixel grid of a planet
	shaderPath = "shaders/planet.glsl",
	texturePath = "textures/white.png",
	textureSize = 4, -- pixels of that texture
	rotationSpeed = 0.012, -- noise scrolled per second: one full turn in a few minutes
	octaves = 3,
	size = 5, -- continents noise scale, a whole number
	light = { x = 0.3, y = 0.3 },
	lightBorders = { x = 0.4, y = 0.6 },
	rimWidth = 0.03, -- outline ring of a planet that has `rim`, as a fraction of its diameter (~2 pixels of its grid)
}

-- Stable seeds: picked once, never regenerated. Colours are theme names, lit to shadow: a neon accent on the lit side,
-- falling off through dim and panel into bg. A locked planet uses `locked` instead (greyed, no neon).
-- `rim` = { lit side, shadow side }: the outline that keeps the globe readable against the dark backdrop; the shadow
-- ramp ends on panel, not bg, for the same reason (bg IS the space behind the planet).
-- waterLevel 0 = all land; cloudCover >= 1 = no clouds. Trade planets get the same treatment as harvest ones.
config.locked = { land = { "dim", "panel", "panel", "panel" }, water = { "panel", "panel" }, cloud = { "dim", "panel" }, rim = { "dim", "dim" } }

config.planets = {
	kessa = { -- harvest (Kessa): barren rock, the player's home: cyan
		seed = 3.17,
		tilt = 0.4,
		phase = 11,
		waterLevel = 0,
		cloudCover = 1,
		land = { "cyan", "dim", "panel", "panel" },
		rim = { "cyan", "dim" },
		water = { "dim", "panel" },
		cloud = { "text", "dim" },
	},
	varn = { -- harvest (Varn): cobalt world, pale and cold
		seed = 7.61,
		tilt = -0.3,
		phase = 47,
		waterLevel = 0,
		cloudCover = 1,
		land = { "text", "dim", "panel", "panel" },
		rim = { "text", "dim" },
		water = { "dim", "panel" },
		cloud = { "text", "dim" },
	},
	ashfall = { -- harvest: volcanic, amber seams
		seed = 4.29,
		tilt = 0.25,
		phase = 59,
		waterLevel = 0,
		cloudCover = 1,
		land = { "amber", "dim", "panel", "panel" },
		rim = { "amber", "dim" },
		water = { "amber", "bg" },
		cloud = { "text", "dim" },
	},
	lumen = { -- harvest: data-crystal world, acid green
		seed = 8.12,
		tilt = -0.35,
		phase = 83,
		waterLevel = 0,
		cloudCover = 1,
		land = { "green", "dim", "panel", "panel" },
		rim = { "green", "dim" },
		water = { "dim", "panel" },
		cloud = { "text", "dim" },
	},
	meridian = { -- trade (Meridian Institute): oceans and clouds
		seed = 5.43,
		tilt = 0.15,
		phase = 23,
		waterLevel = 0.45,
		cloudCover = 0.55,
		land = { "text", "dim", "panel", "bg" },
		water = { "cyan", "panel" },
		cloud = { "text", "dim" },
	},
	halcyon = { -- trade (Halcyon Shipyards): ice world
		seed = 9.08,
		tilt = -0.2,
		phase = 71,
		waterLevel = 0.38,
		cloudCover = 0.7,
		land = { "text", "dim", "panel", "bg" },
		water = { "dim", "panel" },
		cloud = { "text", "dim" },
	},
}

return config
