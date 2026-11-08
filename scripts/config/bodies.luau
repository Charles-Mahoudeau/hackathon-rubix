-- Look of asteroids (veins), stars and the galaxy backdrop: same shader as planets, other parameters. Art numbers only here.
-- Palette names come from config/planets.luau `palette` (placeholder until GR5-3).

local config = {}

config.asteroid = {
	pixels = 24, -- chunky small rock
	size = 4,
	baseRadius = 10, -- world units at richness 1.0
	richnessScale = 0.5, -- radius multiplier span: radius = base * (1 + (richness - 1) * richnessScale)
	-- Revealed look by richness tier (first tier whose max >= richness). The "glow" tell is the lit colour.
	tiers = {
		{ max = 0.8, land = { "steel", "steel", "deep", "void" } }, -- poor
		{ max = 1.2, land = { "sand", "rust", "deep", "void" } }, -- average
		{ max = 99, land = { "bone", "sand", "rust", "deep" } }, -- rich
	},
	hidden = { land = { "deep", "deep", "void", "void" } }, -- unscanned vein: dark, shown with a "?" by the UI
	seedStep = 1.37, -- seed = veinSeed + index * seedStep
}

config.star = {
	pixels = 32,
	size = 3,
	layer = -95,
	land = { "bone", "bone", "sand", "sand" }, -- flat bright disc, almost no shading
	seed = 2.9,
}

config.galaxy = {
	pixels = 40, -- low detail
	size = 6,
	layer = -100, -- behind everything
	land = { "steel", "deep", "deep", "void" },
	seed = 13.3,
	tilt = 0.9,
	waterLevel = 0,
	cloudCover = 1,
}

return config
