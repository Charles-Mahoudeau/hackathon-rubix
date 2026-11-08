-- Station visuals config (GR5-18). Data only: no logic, no engine calls.
-- Sprites are the Wenrexa "Space Modular Buildings" pack (CC0), files assets/stations/raw/RandomBuildings/<sprite>.png.

return {
	-- Stations are static sprites (not rotating bodies). Only the idle/active swap changes their look.
	animated = false,

	spriteDir = "stations/raw/RandomBuildings/",
	layer = -80, -- in front of planets (-90), behind the UI

	-- Bloom only on emissive pixels; the pass itself is render/vfx/bloom (params scaled by state).
	bloom = { emissiveOnly = true, intensityIdle = 0.35, intensityActive = 1.0 },

	-- Per-state swap, passed to assets/shaders/palette_remap.glsl: `brightness` scales the whole sprite, `emissiveScale`
	-- only its emissive pixels (windows, beacons). The palette itself stays the same.
	states = {
		idle   = { brightness = 0.75, emissiveScale = 0.35 },
		active = { brightness = 1.0,  emissiveScale = 1.0 },
	},

	-- The pack is coloured, not greyscale: these luminance cuts (bg|panel, panel|neon, neon|text) decide which pixels
	-- become the corporation neon. Grey-plated sprites need a higher neon cut or the whole hull turns neon.
	steps = { default = { 0.1, 0.45, 0.9 }, hmc_depot = { 0.1, 0.68, 0.9 } },

	-- Which corporation tints each station (a key of config/theme.luau `corps`).
	corp = { hmc_depot = "player", orbis_exchange = "rivalA", halcyon_shipyards = "player", meridian_institute = "rivalB" },

	-- Modules: sprite (under assets/stations/raw/RandomBuildings/), role, and offset in px from the hub
	-- sprite centre (+x right, +y down). Each module is used by one station only. Hub is drawn first.
	stations = {
		hmc_depot = { label = "HMC Depot", modules = {
			{ sprite = "B08", w = 195, h = 195, role = "hub",   x = 0,    y = 0 },
			{ sprite = "B05", w = 196, h = 91, role = "cargo", x = 0,    y = 143 },
			{ sprite = "B14", w = 79, h = 100, role = "dock",  x = 137,  y = 0 },
			{ sprite = "B15", w = 116, h = 90, role = "wing",  x = -155, y = 0 },
		} },
		orbis_exchange = { label = "Orbis Exchange", modules = {
			{ sprite = "B10", w = 135, h = 135, role = "hub",    x = 0,    y = 0 },
			{ sprite = "B09", w = 119, h = 118, role = "market", x = 127,  y = 0 },
			{ sprite = "B11", w = 99, h = 134, role = "vault",  x = -117, y = 0 },
			{ sprite = "B26", w = 70, h = 78, role = "beacon", x = 0,    y = 106 },
		} },
		halcyon_shipyards = { label = "Halcyon Shipyards", modules = {
			{ sprite = "B04", w = 203, h = 202, role = "hub",    x = 0,    y = 0 },
			{ sprite = "B01", w = 106, h = 94, role = "dock",   x = 154,  y = 0 },
			{ sprite = "B02", w = 123, h = 123, role = "dock",   x = -163, y = 0 },
			{ sprite = "B16", w = 124, h = 123, role = "gantry", x = 0,    y = 163 },
		} },
		meridian_institute = { label = "Meridian Institute", modules = {
			{ sprite = "B12", w = 178, h = 171, role = "hub",  x = 0,    y = 0 },
			{ sprite = "B13", w = 117, h = 179, role = "lab",  x = 148,  y = 0 },
			{ sprite = "B19", w = 85, h = 142, role = "lab",  x = -132, y = 0 },
			{ sprite = "B18", w = 85, h = 82, role = "relay", x = 0,   y = 126 },
		} },
	},
}
