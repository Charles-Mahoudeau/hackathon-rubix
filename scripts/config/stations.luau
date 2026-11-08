-- Station visuals config (GR5-18, GR5-52). Data only: no logic, no engine calls.
-- Sprites are the Wenrexa "Space Modular Buildings" pack (CC0), files assets/stations/raw/RandomBuildings/<sprite>.png,
-- turrets assets/stations/raw/DifferentTurrets, decoration assets/stations/raw/MiniAsteroids (credits: CREDITS_STATIONS.md).

return {
	-- Only the idle/active swap, the turret cycle and the stage a station has reached change its look.
	animated = true,

	spriteDir = "stations/raw/RandomBuildings/",
	turretDir = "stations/raw/DifferentTurrets/",
	debrisDir = "stations/raw/MiniAsteroids/",
	layer = -80, -- in front of planets (-90), behind the UI
	turretLayer = -79, -- turrets sit on the hull

	-- Bloom only on emissive pixels; the pass itself is render/vfx/bloom (params scaled by state).
	bloom = { emissiveOnly = true, intensityIdle = 0.35, intensityActive = 1.0 },

	-- Per-state swap, passed to assets/shaders/palette_remap.glsl: `brightness` scales the whole sprite, `emissiveScale`
	-- only its emissive pixels (windows, beacons). The palette itself stays the same.
	states = {
		idle   = { brightness = 0.85, emissiveScale = 0.7 },
		active = { brightness = 1.0,  emissiveScale = 1.0 },
	},

	-- The pack is coloured, not greyscale: these luminance cuts (bg|panel, panel|neon, neon|text) decide which pixels
	-- become the corporation neon. Grey-plated sprites need a higher neon cut or the whole hull turns neon.
	-- Dark hulls (the markets, the lumen outpost) turn neon from 0.3; the grey-plated ones (depot, varn, ashfall, plating at
	-- 0.5-0.6) from 0.5, and their highlights above 0.72 go white. The old 0.68 cut left the whole hull on the panel colour.
	steps = {
		default = { 0.1, 0.3, 0.75 },
		hmc_depot = { 0.1, 0.5, 0.72 }, outpost_varn = { 0.1, 0.5, 0.72 }, outpost_ashfall = { 0.1, 0.5, 0.72 },
	},

	-- Which corporation tints each station (a key of config/theme.luau `corps`). Outposts are the player's.
	corp = {
		hmc_depot = "player", orbis_exchange = "rivalA", halcyon_shipyards = "player", meridian_institute = "rivalB",
		outpost_varn = "player", outpost_ashfall = "player", outpost_lumen = "player",
	},

	-- Animated turrets (the [PLAYER] sets of the pack, 64x64 frames). A strip is { dir, prefix, from, to, digits } (numbered
	-- files) or { dir, file } (one file). A turret loops `idle` for `idleHold` seconds, opens, fires `fireLoops` times, repeats.
	turrets = {
		fps = 12,
		idleHold = 4,
		fireLoops = 2,
		kinds = {
			XN22 = {
				idle = { dir = "Turret_XN22[PLAYER]/AnimIdle/", prefix = "XN22Idle", from = 30, to = 38, digits = 5 },
				open = { dir = "Turret_XN22[PLAYER]/AnimoOpen/", prefix = "XN22Open", from = 0, to = 8, digits = 4 },
				fire = { dir = "Turret_XN22[PLAYER]/AnimFire/", prefix = "XN22Fire", from = 8, to = 16, digits = 4 },
			},
			DX41 = {
				idle = { dir = "Turret_DX41[PLAYER]/AnimIdle/", file = "DX41Idle.png" },
				open = { dir = "Turret_DX41[PLAYER]/AnimOpen/", prefix = "DX41Open", from = 0, to = 12, digits = 4 },
				fire = { dir = "Turret_DX41[PLAYER]/AnimFire/", prefix = "DX41Fire", from = 15, to = 30, digits = 4 },
			},
			MK531 = {
				idle = { dir = "Turret_MK531[PLAYER]/AnimIdle/", file = "MK531Idle.png" },
				open = { dir = "Turret_MK531[PLAYER]/AnimOpen/", prefix = "MK531Open", from = 0, to = 12, digits = 4 },
				fire = { dir = "Turret_MK531[PLAYER]/AnimFire/", prefix = "MK531Fire", from = 19, to = 30, digits = 4 },
			},
			-- The pack names the G79 idle and fire frames after other turrets; these are the files as shipped.
			G79 = {
				idle = { dir = "Turret_G79[PLAYER]/AnimIdle/", file = "MK531Default.png" },
				open = { dir = "Turret_G79[PLAYER]/AnimOpen/", prefix = "TG79Open", from = 0, to = 9, digits = 4 },
				fire = { dir = "Turret_G79[PLAYER]/AnimFire/", prefix = "TG79Open", from = 0, to = 11, digits = 4 },
			},
		},
		frame = 64, -- px, square
		boost = 1.5, -- an animated turret is drawn this much bigger than the hull scale, so it reads on the map
	},

	-- Where a station sits on the system map (view pixels from its node), and how big a sprite pixel is there.
	-- Planet stations hang off the planet; market stations stand above their node (the node and label stay as the hit area).
	map = {
		-- `scale` is the biggest world unit per sprite pixel; a station shrinks below it so that its whole extent (modules, turrets,
		-- debris) fits `fit` (px), which is how the depot stays on the map as the command centre grows it.
		home = { station = "hmc_depot", planet = "kessa", dx = 96, dy = -108, scale = 0.5, fit = { w = 200, h = 240 }, label = "HMC DEPOT" },
		outposts = {
			varn = { station = "outpost_varn", dx = 80, dy = -84, scale = 0.32, fit = { w = 130, h = 120 }, label = "VARN OUTPOST" },
			ashfall = { station = "outpost_ashfall", dx = 80, dy = -84, scale = 0.32, fit = { w = 130, h = 120 }, label = "ASHFALL OUTPOST" },
			lumen = { station = "outpost_lumen", dx = -80, dy = -84, scale = 0.32, fit = { w = 130, h = 120 }, label = "LUMEN OUTPOST" },
		},
		markets = {
			-- `side`: where the station stands against its node: "up" (default), "left" or "right", whichever keeps clear of the
			-- planets and their labels.
			orbis = { station = "orbis_exchange", scale = 0.3, side = "right" },
			halcyon = { station = "halcyon_shipyards", scale = 0.3 },
			meridian = { station = "meridian_institute", scale = 0.3, side = "left" },
		},
		marketGap = 18, -- px between the node centre and the nearest edge of its station
		edge = 8, -- px a station keeps from the edge of the main panel
		dock = { gap = 4, spacing = 9 }, -- the dock line from a planet to its depot: dash spacing, and the clearance at the planet rim
	},

	-- Stations: `modules` always, then each `stages` entry once the player has that upgrade (`when` = a key of sim.upgrades).
	-- A module is a sprite of RandomBuildings with its size and an offset in px from
	-- the hub sprite centre (+x right, +y down); `corp` (a key of theme corps) draws that module in another neon, the amber accents. `turrets`: animated { kind, x, y, phase } or static { still, w, h, x, y }.
	-- `debris`: { sprite, w, h, x, y } of MiniAsteroids. Each sprite is used once in the whole file (tests/test_stations.luau).
	stations = {
		-- The player's depot at Kessa: grows with the warehouse (T3), trading post, logistics hub (T4) and command centre (T5).
		hmc_depot = { label = "HMC Depot",
			modules = {
				{ sprite = "B08", w = 195, h = 195, role = "hub",   x = 0,    y = 0 },
				{ sprite = "B14", w = 79, h = 100, role = "dock",  x = 137,  y = 0, corp = "rivalB" },
			},
			turrets = { { kind = "XN22", x = -78, y = -78, phase = 0 } },
			stages = {
				{ when = "warehouse", label = "Warehouse",
					modules = { { sprite = "B05", w = 196, h = 91, role = "cargo", x = 0, y = 143 } },
					turrets = { { kind = "DX41", x = 78, y = 78, phase = 1.7 }, { still = "Turret09", w = 78, h = 119, x = -80, y = 80 } } },
				{ when = "tradingPost", label = "Trading post",
					modules = { { sprite = "B15", w = 116, h = 90, role = "wing", x = -155, y = 0, corp = "rivalB" } },
					turrets = { { kind = "MK531", x = -155, y = -30, phase = 3.1 } } },
				{ when = "hub", label = "Logistics hub",
					modules = {
						{ sprite = "B07", w = 195, h = 143, role = "hangar", x = 0, y = -169, corp = "rivalB" },
						{ sprite = "Platform[PLAYER]/P01", w = 128, h = 128, role = "pad", x = -170, y = 125 },
						{ sprite = "Platform[PLAYER]/P02", w = 128, h = 128, role = "pad", x = 170, y = 125 },
					},
					turrets = { { kind = "G79", x = 78, y = -200, phase = 0.9 }, { still = "Turret10", w = 70, h = 69, x = -78, y = -200 } } },
				{ when = "commandCenter", label = "Command center",
					modules = {
						{ sprite = "B25", w = 187, h = 187, role = "command", x = 0, y = -334 },
						{ sprite = "B24", w = 198, h = 158, role = "ops", x = -200, y = -200 },
						{ sprite = "B23", w = 130, h = 240, role = "mast", x = 250, y = -190 },
					},
					turrets = { { kind = "XN22", x = 250, y = -320, phase = 2.2 }, { kind = "MK531", x = -200, y = -290, phase = 4.4 } } },
			},
		},
		orbis_exchange = { label = "Orbis Exchange", modules = {
			{ sprite = "B10", w = 135, h = 135, role = "hub",    x = 0,    y = 0 },
			{ sprite = "B09", w = 119, h = 118, role = "market", x = 127,  y = 0 },
			{ sprite = "B11", w = 99, h = 134, role = "vault",  x = -117, y = 0 },
			{ sprite = "B26", w = 70, h = 78, role = "beacon", x = 0,    y = 106 },
			{ sprite = "Platform[PLAYER]/P06", w = 128, h = 128, role = "pad", x = 0, y = 215 },
		}, turrets = {
			{ still = "Turret01", w = 81, h = 124, x = -70, y = -70 },
			{ still = "Turret02", w = 84, h = 124, x = 70, y = -70 },
		} },
		halcyon_shipyards = { label = "Halcyon Shipyards", modules = {
			{ sprite = "B04", w = 203, h = 202, role = "hub",    x = 0,    y = 0 },
			{ sprite = "B01", w = 106, h = 94, role = "dock",   x = 154,  y = 0 },
			{ sprite = "B02", w = 123, h = 123, role = "dock",   x = -163, y = 0 },
			{ sprite = "B16", w = 124, h = 123, role = "gantry", x = 0,    y = 163 },
			{ sprite = "Platform[PLAYER]/P07", w = 128, h = 128, role = "pad", x = 0, y = 290 },
		}, turrets = {
			{ still = "Turret03", w = 68, h = 118, x = -80, y = -80 },
			{ still = "Turret04", w = 63, h = 117, x = 80, y = -80 },
		} },
		meridian_institute = { label = "Meridian Institute", modules = {
			{ sprite = "B12", w = 178, h = 171, role = "hub",  x = 0,    y = 0 },
			{ sprite = "B13", w = 117, h = 179, role = "lab",  x = 148,  y = 0 },
			{ sprite = "B19", w = 85, h = 142, role = "lab",  x = -132, y = 0 },
			{ sprite = "B18", w = 85, h = 82, role = "relay", x = 0,   y = 126 },
			{ sprite = "Platform[PLAYER]/P08", w = 128, h = 128, role = "pad", x = 0, y = 230 },
		}, turrets = {
			{ still = "Turret05", w = 69, h = 126, x = -75, y = -75 },
			{ still = "Turret06", w = 84, h = 136, x = 75, y = -75 },
		} },

		-- Outposts (spec D21), one look per planet, drawn once built. A small sentry and a drifting rock each.
		outpost_varn = { label = "Varn outpost", modules = {
			{ sprite = "B20", w = 118, h = 118, role = "hub",  x = 0,   y = 0 },
			{ sprite = "B17", w = 85, h = 112, role = "silo", x = 100, y = 0 },
			{ sprite = "Platform[PLAYER]/P03", w = 128, h = 128, role = "pad", x = -120, y = 20 },
		}, turrets = { { kind = "XN22", x = 0, y = -62, phase = 0.4 } },
			debris = { { sprite = "01", w = 111, h = 103, x = 110, y = -90 } } },
		outpost_ashfall = { label = "Ashfall outpost", modules = {
			{ sprite = "B21", w = 152, h = 118, role = "hub",  x = 0,   y = 0 },
			{ sprite = "B06", w = 143, h = 143, role = "silo", x = 150, y = 0 },
			{ sprite = "Platform[PLAYER]/P04", w = 128, h = 128, role = "pad", x = -145, y = 20 },
		}, turrets = { { kind = "DX41", x = 0, y = -64, phase = 2.5 }, { still = "Turret07", w = 69, h = 130, x = 90, y = -70 } },
			debris = { { sprite = "02", w = 98, h = 105, x = 150, y = -100 } } },
		outpost_lumen = { label = "Lumen outpost", modules = {
			{ sprite = "B22", w = 130, h = 151, role = "hub",  x = 0,   y = 0 },
			{ sprite = "B03", w = 148, h = 202, role = "silo", x = -140, y = 0 },
			{ sprite = "Platform[PLAYER]/P05", w = 128, h = 128, role = "pad", x = 135, y = 20 },
		}, turrets = { { kind = "G79", x = 0, y = -78, phase = 3.6 }, { still = "Turret08", w = 78, h = 117, x = -140, y = -105 } },
			debris = { { sprite = "03", w = 110, h = 106, x = 130, y = -105 } } },
	},

}
