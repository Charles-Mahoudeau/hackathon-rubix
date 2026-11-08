-- Planet look: the theme palette, and one fixed entry per MVP planet. Balance/art numbers live here only.
-- Files of scripts/ load in sorted order, so logic reads these globals at call time, never at load time.

GameConfig = GameConfig or {}

-- The 8-colour theme (GR5-3), as 0xRRGGBB. PLACEHOLDER values until GR5-3 fixes the real ones: change them here only.
GameConfig.palette = {
	void = 0x0B0E1A,
	deep = 0x1F2A44,
	steel = 0x3E5C76,
	ice = 0x9FD3E6,
	sand = 0xD9B26F,
	rust = 0xB5543A,
	moss = 0x5F8F5A,
	bone = 0xF2EBDD,
}

GameConfig.planetRender = {
	pixels = 64, -- pixel grid of a planet
	shaderPath = "shaders/planet.glsl",
	texturePath = "textures/white.png",
	textureSize = 4, -- pixels of that texture
	rotationSpeed = 0.012, -- noise scrolled per second: one full turn in a few minutes
	octaves = 3,
	size = 5, -- continents noise scale, a whole number
	light = { x = 0.3, y = 0.3 },
	lightBorders = { x = 0.4, y = 0.6 },
}

-- Stable seeds: picked once, never regenerated. Colours are palette names, lit to shadow.
-- waterLevel 0 = all land; cloudCover >= 1 = no clouds. Trade planets get the same treatment as harvest ones.
GameConfig.planets = {
	kessa = { -- harvest (Kessa): barren rock
		seed = 3.17,
		tilt = 0.4,
		phase = 11,
		waterLevel = 0,
		cloudCover = 1,
		land = { "sand", "rust", "steel", "deep" },
		water = { "steel", "deep" },
		cloud = { "bone", "ice" },
	},
	varn = { -- harvest (Varn): dark, cooled lava
		seed = 7.61,
		tilt = -0.3,
		phase = 47,
		waterLevel = 0,
		cloudCover = 1,
		land = { "rust", "deep", "deep", "void" },
		water = { "rust", "void" },
		cloud = { "bone", "ice" },
	},
	ashfall = { -- harvest: volcanic, lava seams
		seed = 4.29,
		tilt = 0.25,
		phase = 59,
		waterLevel = 0,
		cloudCover = 1,
		land = { "sand", "rust", "rust", "void" },
		water = { "rust", "void" },
		cloud = { "bone", "ice" },
	},
	lumen = { -- harvest: crystal world, pale and cold
		seed = 8.12,
		tilt = -0.35,
		phase = 83,
		waterLevel = 0,
		cloudCover = 1,
		land = { "ice", "steel", "deep", "void" },
		water = { "steel", "deep" },
		cloud = { "bone", "ice" },
	},
	meridian = { -- trade (Meridian Institute): temperate, oceans and clouds
		seed = 5.43,
		tilt = 0.15,
		phase = 23,
		waterLevel = 0.45,
		cloudCover = 0.55,
		land = { "sand", "moss", "moss", "deep" },
		water = { "ice", "steel" },
		cloud = { "bone", "ice" },
	},
	halcyon = { -- trade (Halcyon Shipyards): ice world
		seed = 9.08,
		tilt = -0.2,
		phase = 71,
		waterLevel = 0.38,
		cloudCover = 0.7,
		land = { "bone", "ice", "steel", "deep" },
		water = { "steel", "deep" },
		cloud = { "bone", "ice" },
	},
}
