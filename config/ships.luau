-- Ship visual definitions (GR5-19). Balance/visual numbers live here, never in logic.
-- Source pack: Foozle Void Fleet Pack 1 (CC0). Sprites are greyscale/white and remapped by the
-- palette-swap shader; the neon colour is the `corp_tint` shader parameter (corporation-driven).
-- `source` names are the pack's ship names; exact sheet files are filled in once the zip is imported.
return {
	pack = { name = "Void Fleet Pack 1", author = "Foozle", license = "CC0", credits_required = false },

	-- Colour comes from corporation ownership, passed as a shader uniform, never baked in.
	corp_tint = { player = "cyan", rival_a = "magenta", rival_b = "amber" },

	ships = {
		miner = {
			-- One hull + tier module overlay (cheapest way to show Mk1..Mk3).
			hull = { source = "Support Ship", sheet = "assets/ships/miner_hull.png" },
			tiers = {
				[1] = { module = nil },
				[2] = { module = "assets/ships/miner_mod_drill.png" },
				[3] = { module = "assets/ships/miner_mod_drill_scanner.png" },
			},
			map_icon = { shape = "diamond", size_px = 6 },
		},
		freighter = {
			-- Larger, distinct silhouette (T4, GR5-12).
			hull = { source = "Frigate", sheet = "assets/ships/freighter_hull.png" },
			scale = 1.6,
			map_icon = { shape = "wide_rect", size_px = 9 },
		},
	},

	-- Stretch (B-0+): candidates noted only, no remap work until a branch is greenlit.
	stretch_candidates = {
		salvage = "Scout", refining = "Battleship", interceptor = "Fighter", privateer = "Bomber",
	},

	-- Bloom is emissive-only: engine trail + running lights.
	bloom = { engine_trail = true, running_lights = true, hull = false },
}
