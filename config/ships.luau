-- Ship visual definitions (GR5-19). Balance/visual numbers live here, never in logic.
-- Source pack: Foozle Void Fleet Pack 1 (CC0), Kla'ed faction. Sprites are coloured in the pack; the
-- palette-swap shader (GR5-3) remaps them to the 8-colour theme and the neon colour is the
-- `corp_tint` shader parameter (corporation-driven). Until GR5-3 lands they render as-is.
local K = "assets/ships/Kla'ed/"

return {
	pack = { name = "Void Fleet Pack 1", author = "Foozle", license = "CC0", credits_required = false },

	-- Colour comes from corporation ownership, passed as a shader uniform, never baked in.
	corp_tint = { player = "cyan", rival_a = "magenta", rival_b = "amber" },

	-- All pack sheets are 64px-tall horizontal strips (128px for Battlecruiser/Dreadnought bases).
	frame_px = 64,

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
		},
		freighter = {
			-- Larger, distinct silhouette (T4, GR5-12).
			hull = { source = "Frigate", sheet = K .. "Base/PNGs/Kla'ed - Frigate - Base.png" },
			engine = { sheet = K .. "Engine/PNGs/Kla'ed - Frigate - Engine.png", frames = 10 },
			destruction = { sheet = K .. "Destruction/PNGs/Kla'ed - Frigate - Destruction.png", frames = 10 },
			scale = 1.6,
			map_icon = { shape = "wide_rect", size_px = 9 },
		},
	},

	-- Stretch (B-0+): candidates noted only, no remap work until a branch is greenlit.
	-- Names are the pack's actual ship types (no "Battleship" in this pack).
	stretch_candidates = {
		salvage = "Scout", refining = "Battlecruiser", interceptor = "Fighter", privateer = "Bomber",
	},

	-- Bloom is emissive-only: engine trail + running lights.
	bloom = { engine_trail = true, running_lights = true, hull = false },
}
