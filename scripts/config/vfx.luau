-- Global (no require in AYLO); sorted-load puts scripts/config/* before scripts/render/*.
-- VFX balance/look numbers (GR5-22). No literals of this kind live in render/vfx/*.
VfxConfig = {
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
		safe = { 0.25, 0.65, 1.0, 1.0 }, -- blue
		risky = { 1.0, 0.55, 0.15, 1.0 }, -- orange
		idleAlpha = 0.35,
		activeAlpha = 1.0,
		dashLength = 12,
		gapLength = 8,
		pulseSpeed = 40, -- px/s along the line when active
		riskyThreshold = 0.5, -- risk in [0,1] at or above this draws orange
	},
	halo = {
		idle = { color = { 0.4, 0.6, 0.8, 1.0 }, alpha = 0.2, pulseHz = 0.0, radius = 1.0 },
		pending = { color = { 1.0, 0.75, 0.2, 1.0 }, alpha = 0.6, pulseHz = 1.5, radius = 1.15 },
		executing = { color = { 0.2, 1.0, 0.7, 1.0 }, alpha = 0.9, pulseHz = 0.0, radius = 1.25 },
	},
	trail = {
		maxPoints = 12,
		sampleInterval = 0.05, -- seconds between trail points
		lifetime = 0.6,
		color = { 0.5, 0.85, 1.0, 1.0 },
		startWidth = 3,
	},
}
