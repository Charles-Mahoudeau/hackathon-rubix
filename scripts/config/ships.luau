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
			map_scale = 0.5,
		},
		freighter = {
			-- Larger, distinct silhouette (T4, GR5-12).
			hull = { source = "Frigate", sheet = K .. "Base/PNGs/Kla'ed - Frigate - Base.png" },
			engine = { sheet = K .. "Engine/PNGs/Kla'ed - Frigate - Engine.png", frames = 12 },
			destruction = { sheet = K .. "Destruction/PNGs/Kla'ed - Frigate - Destruction.png", frames = 9 },
			scale = 1.6,
			map_icon = { shape = "wide_rect", size_px = 9 },
			map_scale = 0.8,
		},
		-- Rival convoy hauler (raiding branch, GR5-45): Bomber hull. Its shield flickers while it is under attack.
		convoy = {
			hull = { source = "Bomber", sheet = K .. "Base/PNGs/Kla'ed - Bomber - Base.png" },
			engine = { sheet = K .. "Engine/PNGs/Kla'ed - Bomber - Engine.png", frames = 10 },
			destruction = { sheet = K .. "Destruction/PNGs/Kla'ed - Bomber - Destruction.png", frames = 8 },
			shield = { sheet = K .. "Shield/PNGs/Kla'ed - Bomber - Shield.png", frames = 6 },
			map_icon = { shape = "wide_rect", size_px = 7 },
			map_scale = 0.6,
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
			map_scale = 0.5,
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
		dock = { pad = 16, speed = 0.35, step = 0.9 }, -- parked ships circle their planet: radius beyond the planet disc, rad/s, spacing in rad
		mining = { pad = 8, speed = 0.9 }, -- a miner at its vein circles close and fast
		idle_engine_fps = 6, -- engine strip speed while parked (moving ships use engine_fps)
		leader_corp = "player",
		corp_of = { korvax = "rivalA", helion = "rivalB", dunmere = "rivalA" }, -- raiding corporation -> a key of corp_tint
		escort_gap = 22, -- escorts fly this far to the side of their convoy
		alongside = { gap = 26 }, -- an interceptor next to its target
		shield_fps = 12,
		weapons_fps = 14,
		fire = { interval = 0.35, flight = 0.5, per_ship = 2 }, -- one shot every `interval` s, in the air `flight` s, at most `per_ship` at once
		torpedo = { interval = 1.6, flight = 0.9 }, -- the first interceptor adds a torpedo now and then
		ray_flight = 0.6,
		projectile_scale = 1.5,
		wave_scale = 0.7,
		explosion = { fps = 14, scale = 1.0 },
		layers = { shield = 11, projectile = 12, explosion = 13, wave = 14 },
	},

	-- Stretch (B-0+): candidates noted only, no remap work until a branch is greenlit (raiding ships are drawn, GR5-51).
	-- Names are the pack's actual ship types (no "Battleship" in this pack).
	stretch_candidates = { salvage = "Scout", refining = "Battlecruiser" },

	-- Bloom is emissive-only: engine trail + running lights.
	bloom = { engine_trail = true, running_lights = true, hull = false },
}
