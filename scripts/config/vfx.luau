-- VFX balance/look numbers (GR5-22). No literals of this kind live in render/vfx/*.
return {
	bloom = {
		threshold = 0.72, -- luminance above which a pixel counts as neon
		neonTagOnly = true, -- only pixels tagged neon (alpha-channel/mask) bloom
		intensity = 0.9,
		blurPasses = 3,
		blend = "additive",
	},
	glitch = {
		duration = 0.35, -- seconds, one short flicker
		holdFrames = 2, -- brief frame-hold at the start
		rgbSplitPx = 4,
		scanlineAlpha = 0.25,
		sliceCount = 3,
		maxSliceShiftPx = 10,
		seed = 22022,
		allowedSources = { ai_error = true }, -- the ONLY trigger (art direction, GR5-3)
	},
	route = {
		safe = "cyan", -- palette name (config/theme.luau): the cool, safe route
		risky = "amber", -- the warm, risky route
		idleAlpha = 0.35,
		activeAlpha = 1.0,
		dashLength = 12,
		gapLength = 8,
		pulseSpeed = 40, -- px/s along the line when active
		riskyThreshold = 0.5, -- risk in [0,1] at or above this draws orange
	},
	halo = {
		idle = { color = "dim", alpha = 0.2, pulseHz = 0.0, radius = 1.0 },
		pending = { color = "amber", alpha = 0.6, pulseHz = 1.5, radius = 1.15 },
		executing = { color = "green", alpha = 0.9, pulseHz = 0.0, radius = 1.25 },
	},
	trail = {
		maxPoints = 12,
		sampleInterval = 0.05, -- seconds between trail points
		lifetime = 0.6,
		color = "cyan",
		startWidth = 3,
	},
}
