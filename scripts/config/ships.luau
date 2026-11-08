-- Ship visual definitions (GR5-19). Balance/visual numbers live here, never in logic.
-- Source pack: Foozle Void Fleet Pack 1 (CC0), Kla'ed faction. Sprites are coloured in the pack; the
-- palette-swap shader (GR5-3) remaps them to the 8-colour theme and the neon colour is the
-- `corp_tint` shader parameter (corporation-driven). Until GR5-3 lands they render as-is.
local K = "ships/Kla'ed/" -- relative to assets/, like every other texture path

return {
	pack = { name = "Void Fleet Pack 1", author = "Foozle", license = "CC0", credits_required = false },

	-- Colour comes from corporation ownership, passed as a shader uniform, never baked in.
	corp_tint = { player = "cyan", rival_a = "magenta", rival_b = "amber" },

	-- All pack sheets are 64px-tall horizontal strips (128px for Battlecruiser/Dreadnought bases).
	frame_px = 64,

	-- Remap luminance thresholds for these (coloured, not pure grey) sprites. The shader default (0.25/0.5/0.85) sends
	-- ~60% of a hull to the background colour; these keep the silhouette. `tier_glow` (0..1) lowers all three by
	-- `glow_shift` so higher miner tiers read brighter.
	remap = { steps = { 0.15, 0.30, 0.60 }, glow_shift = 0.08 },

	-- Draw layers (engine strip sits behind the hull) and engine-strip animation.
	layers = { engine = 9, hull = 10 },
	engine_fps = 12,
	-- Hull size in world units at scale 1.
	size = 64,

	ships = {
		miner = {
			hull = { source = "Support ship", sheet = K .. "Base/PNGs/Kla'ed - Support ship - Base.png" },
			engine = { sheet = K .. "Engine/PNGs/Kla'ed - Support ship - Engine.png", frames = 10 },
			destruction = { sheet = K .. "Destruction/PNGs/Kla'ed - Support ship - Destruction.png", frames = 10 },
			-- The pack has no isolated module overlays (Support ship has no Weapons sheet; other Weapons
			-- sheets embed the whole hull), so tiers share the hull and differ by engine overlay size
			-- and the shader's `tier_glow` parameter. Dedicated Mk2/Mk3 module art is a later polish pass.
			tiers = {
				[1] = { engine_scale = 0.8, tier_glow = 0.0 },
				[2] = { engine_scale = 1.0, tier_glow = 0.5 },
				[3] = { engine_scale = 1.3, tier_glow = 1.0 },
			},
			map_icon = { shape = "diamond", size_px = 6 },
			map_scale = 1.6,
		},
		freighter = {
			-- Larger, distinct silhouette (T4, GR5-12).
			hull = { source = "Frigate", sheet = K .. "Base/PNGs/Kla'ed - Frigate - Base.png" },
			engine = { sheet = K .. "Engine/PNGs/Kla'ed - Frigate - Engine.png", frames = 12 },
			destruction = { sheet = K .. "Destruction/PNGs/Kla'ed - Frigate - Destruction.png", frames = 9 },
			scale = 1.6,
			map_icon = { shape = "wide_rect", size_px = 9 },
			map_scale = 1.4,
		},
		-- Rival convoy hauler (raiding branch, GR5-45): Bomber hull. Its shield flickers while it is under attack.
		convoy = {
			hull = { source = "Bomber", sheet = K .. "Base/PNGs/Kla'ed - Bomber - Base.png" },
			engine = { sheet = K .. "Engine/PNGs/Kla'ed - Bomber - Engine.png", frames = 10 },
			destruction = { sheet = K .. "Destruction/PNGs/Kla'ed - Bomber - Destruction.png", frames = 8 },
			shield = { sheet = K .. "Shield/PNGs/Kla'ed - Bomber - Shield.png", frames = 6 },
			map_icon = { shape = "wide_rect", size_px = 7 },
			map_scale = 1.5,
		},
		-- The player's Scavenger (salvage branch, GR5-104): the Bomber hull, in the player's neon. It has no shield or weapons use.
		scavenger = {
			hull = { source = "Bomber", sheet = K .. "Base/PNGs/Kla'ed - Bomber - Base.png" },
			engine = { sheet = K .. "Engine/PNGs/Kla'ed - Bomber - Engine.png", frames = 10 },
			destruction = { sheet = K .. "Destruction/PNGs/Kla'ed - Bomber - Destruction.png", frames = 8 },
			map_icon = { shape = "wide_rect", size_px = 7 },
			map_scale = 1.5,
		},
		-- The player's interceptors (privateer) and the escorts of a convoy: Fighter hull. `weapons` embeds the hull (see
		-- the miner note), so it replaces the hull sprite while the ship fires.
		privateer = {
			hull = { source = "Fighter", sheet = K .. "Base/PNGs/Kla'ed - Fighter - Base.png" },
			engine = { sheet = K .. "Engine/PNGs/Kla'ed - Fighter - Engine.png", frames = 10 },
			destruction = { sheet = K .. "Destruction/PNGs/Kla'ed - Fighter - Destruction.png", frames = 9 },
			shield = { sheet = K .. "Shield/PNGs/Kla'ed - Fighter - Shield.png", frames = 10 },
			weapons = { sheet = K .. "Weapons/PNGs/Kla'ed - Fighter - Weapons.png", frames = 6 },
			map_icon = { shape = "diamond", size_px = 6 },
			map_scale = 1.9,
		},
	},

	-- Projectile strips (all point up, like the hulls). fw x fh is one frame; the sheet is `frames` of them side by side.
	projectiles = {
		bullet = { sheet = K .. "Projectiles/PNGs/Kla'ed - Bullet.png", frames = 4, fw = 4, fh = 16 },
		big_bullet = { sheet = K .. "Projectiles/PNGs/Kla'ed - Big Bullet.png", frames = 4, fw = 8, fh = 16 },
		torpedo = { sheet = K .. "Projectiles/PNGs/Kla'ed - Torpedo.png", frames = 3, fw = 11, fh = 32 },
		ray = { sheet = K .. "Projectiles/PNGs/Kla'ed - Ray.png", frames = 4, fw = 18, fh = 38 },
		wave = { sheet = K .. "Projectiles/PNGs/Kla'ed - Wave.png", frames = 6, fw = 64, fh = 64 },
	},

	-- Moving ships on the system map (GR5-51). View pixels and seconds; nothing here is sim balance.
	map_fx = {
		smoothing = 8, -- 1/s: how fast a drawn ship follows the pose the sim gives it (ticks are 10 Hz, frames are not)
		dock = { pad = 30, speed = 0.35, step = 0.9 }, -- parked ships circle their planet: radius beyond the planet disc, rad/s, spacing in rad
		mining = { pad = 22, speed = 0.9 }, -- a miner at its vein circles close and fast
		idle_engine_fps = 6, -- engine strip speed while parked (moving ships use engine_fps)
		leader_corp = "player",
		corp_of = { korvax = "rivalA", helion = "rivalB", dunmere = "rivalA" }, -- raiding corporation -> a key of corp_tint
		escort_gap = 50, -- escorts fly this far to the side of their convoy
		alongside = { gap = 54 }, -- an interceptor next to its target
		shield_fps = 12,
		weapons_fps = 14,
		fire = { interval = 0.35, flight = 0.5, per_ship = 2 }, -- one shot every `interval` s, in the air `flight` s, at most `per_ship` at once
		torpedo = { interval = 1.6, flight = 0.9 }, -- the first interceptor adds a torpedo now and then
		ray_flight = 0.6,
		projectile_scale = 2.4,
		wave_scale = 1.3,
		explosion = { fps = 14, scale = 1.0 },
		layers = { shield = 11, projectile = 12, explosion = 13, wave = 14, trail = 8 },
		-- The depot: the player's dock next to Kessa (the station of GR5-52 sits here). Ships of the home planet leave from and
		-- return to this point, offset from the planet centre in view pixels; parked ships circle it at `ring`.
		depot = { dx = 74, dy = -46, ring = 34 },
		-- Engine trail: pixel squares (assets/textures/white.png, 4 px) behind a moving ship, drawn in the corporation's neon.
		trail = { sheet = "textures/white.png", px = 4, count = 7, length = 46, rate = 1.8, size = 0.8, spread = 5, rear = 17, steps = { 0.15, 0.3, 2.0 } },
		-- GR5-104: the choreography of GR5-103. Pixels are view pixels, times are seconds.
		life = {
			hull_art = 28, -- px of art inside a 64 px frame; times map_scale it is the hull's box for spacing
			hover = { amp = 2, period = 3 }, -- idle / working hover (real time, off in reduced motion)
			quads = { count = 2, size = 2, life = 0.3, every = 0.6 }, -- mining sparks at the vein
			caps = { hulls = 16, stations = 16, quads = 48 },
			clear = { hull = 12, station = 8, label = 6 }, -- gaps between hulls, to station boxes, around labels
			berth = { start = -0.6 }, -- angle (rad) of the first berth on a ring
			badge = { size = 10, label_w = 72, label_h = 16, labelled_max = 6, marker = 14 }, -- labels show for the selected, alerts and when few
			turret = { range = 260 }, -- a station turret only reacts to a real fight this close
			reveal = { total = 2.0, reduced = 0.5, ring = { 0.3, 1.1 }, ringReach = 20, label = { 0.6, 1.4 } },
		},
	},

	-- Stretch (B-0+): candidates noted only, no remap work until a branch is greenlit (raiding ships are drawn, GR5-51).
	-- Names are the pack's actual ship types (no "Battleship" in this pack).
	stretch_candidates = { salvage = "Scout", refining = "Battlecruiser" },

	-- Bloom is emissive-only: engine trail + running lights.
	bloom = { engine_trail = true, running_lights = true, hull = false },
}
