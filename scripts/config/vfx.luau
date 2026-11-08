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
		active = { color = "cyan", alpha = 0.7, pulseHz = 0.0, radius = 1.2 },
		error = { color = "amber", alpha = 0.95, pulseHz = 2.5, radius = 1.3 }, -- paused_error: the pulse is the only motion
		selected = { color = "cyan", alpha = 0.8, pulseHz = 0.8, radius = 1.3 }, -- hovered / selected map node
	},
	-- Agent / ship state -> halo above. Anything not listed is `idle`.
	haloOfState = { acting = "active", active = "active", paused_error = "error", no_compute = "pending", pending = "pending", executing = "executing" },
	-- UI glow: a halo is a stack of translucent discs (view pixels), outermost first. Alpha is the halo alpha times `alphaStep`^layer.
	glow = {
		layers = 3,
		spread = 5, -- extra radius per layer
		alphaStep = 0.45,
		dot = 8, -- the state light next to a row
		accentBar = 4, -- width of a branch row accent
		node = 9, -- base radius of a market / station node halo
		planet = { pad = 6, pulseHz = 0.18, lockedAlpha = 0.0 }, -- ring radius beyond the planet disc; slow, so planets feel alive
		routeUnderlay = { size = 5, alpha = 0.18 }, -- soft dots under an active or focused route line
		focusScale = 1.6, -- route dot size multiplier while focused
	},
	-- Error glitch overlay (drawn behind every text, never over the feed strip where the reason is shown).
	glitchOverlay = { barHeight = 2, splitHeight = 2, maxBars = 3, flashAlpha = 0.5 },
	-- One-shot code-drawn pixel cues (cue sheet GR5-98): small palette-coloured quads, durations in real seconds, no assets.
	-- colors: palette names, picked in turn per quad (accent first, neutral highlight second). size / rise / travel are view pixels.
	cues = {
		seed = 31031, -- LCG seed of the particle spread (cosmetic stream, never the sim's RNG)
		credits = { count = 6, size = { 2, 3 }, rise = { 8, 12 }, life = 0.4, cooldown = 0.5, spread = 14, colors = { "green", "text" } },
		-- accent = "player": the corporation neon (config/theme.luau corps) of the one who unlocked it.
		planetUnlock = { count = 12, size = { 2, 4 }, travel = { 12, 24 }, life = 0.8, cooldown = 1.0, colors = { "$corp", "text" }, corp = "player" },
		-- aimed along the turret's outward direction; `muzzle` = fraction of the drawn turret frame from its centre to the muzzle.
		turretFire = { count = 4, size = { 2, 3 }, travel = { 4, 8 }, life = 0.15, cooldown = 0.1, cone = 0.35, muzzle = 0.4, colors = { "$corp", "text" } },
		maxParticles = 96,
	},
	-- Planet reachability reveal (GR5-105, choreography GR5-103): real seconds from the moment a planet turns reachable.
	-- The engine has no world camera (DECISIONS.md), so the 12 px nudge of the spec is not drawn: the dim, ring, burst and label play in place.
	reveal = {
		duration = 2.0, -- one reveal; several at once play one after the other in map order
		dim = { color = "bg", alpha = 0.6, finish = 1.1 }, -- the planet starts dimmed over its disc and reaches its normal look here
		burstAt = 0.3, -- the GR5-100 planet burst (cues.planetUnlock) fires here, once
		ring = { start = 0.3, finish = 1.1, color = "cyan", stroke = 2, endStroke = 1, grow = 20 }, -- one outline ring, planet edge to +grow px, fading
		label = { start = 0.6, finish = 1.4, backingAlpha = 0.92 }, -- locked reason out, name + available state in over a panel backing
		reducedMotion = false, -- true: no ring, no burst, no fade; a static outline and the label for `reducedSeconds` (read once, no settings screen yet)
		reducedSeconds = 0.5,
		refreshSeconds = 0.05, -- the map redraws this often while a reveal plays (otherwise Screens.map.animSeconds)
	},
	trail = {
		maxPoints = 12,
		sampleInterval = 0.05, -- seconds between trail points
		lifetime = 0.6,
		color = "cyan",
		startWidth = 3,
	},
}
