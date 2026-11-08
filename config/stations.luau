-- Station visuals config (GR5-18). Data only: no logic, no engine calls.
-- Sprite names refer to files of the Wenrexa "Space Modular Buildings" pack, to be dropped in
-- assets/stations/raw/ (see assets/stations/README.md).

return {
	-- Stations are static sprites (not rotating bodies). Only the idle/active swap changes their look.
	animated = false,

	-- Shared with the ship/corporation palette-remap shader (GR5-3): same 8-colour theme, same shader.
	remapShader = "shaders/palette_remap",

	-- Bloom is applied only to pixels the remap flags as emissive (windows, beacons).
	bloom = { emissiveOnly = true, intensityIdle = 0.35, intensityActive = 1.0 },

	-- Per-state emissive/brightness swap; the palette itself stays the same.
	states = {
		idle   = { brightness = 0.75, emissiveScale = 0.35 },
		active = { brightness = 1.0,  emissiveScale = 1.0 },
	},

	-- Modules: sprite (under assets/stations/raw/RandomBuildings/), role, and offset in px from the hub
	-- sprite centre (+x right, +y down). Each module is used by one station only. Hub is drawn first.
	stations = {
		hmc_depot = { label = "HMC Depot", modules = {
			{ sprite = "B08", role = "hub",   x = 0,    y = 0 },
			{ sprite = "B05", role = "cargo", x = 0,    y = 143 },
			{ sprite = "B14", role = "dock",  x = 137,  y = 0 },
			{ sprite = "B15", role = "wing",  x = -155, y = 0 },
		} },
		orbis_exchange = { label = "Orbis Exchange", modules = {
			{ sprite = "B10", role = "hub",    x = 0,    y = 0 },
			{ sprite = "B09", role = "market", x = 127,  y = 0 },
			{ sprite = "B11", role = "vault",  x = -117, y = 0 },
			{ sprite = "B26", role = "beacon", x = 0,    y = 106 },
		} },
		halcyon_shipyards = { label = "Halcyon Shipyards", modules = {
			{ sprite = "B04", role = "hub",    x = 0,    y = 0 },
			{ sprite = "B01", role = "dock",   x = 154,  y = 0 },
			{ sprite = "B02", role = "dock",   x = -163, y = 0 },
			{ sprite = "B16", role = "gantry", x = 0,    y = 163 },
		} },
		meridian_institute = { label = "Meridian Institute", modules = {
			{ sprite = "B12", role = "hub",  x = 0,    y = 0 },
			{ sprite = "B13", role = "lab",  x = 148,  y = 0 },
			{ sprite = "B19", role = "lab",  x = -132, y = 0 },
			{ sprite = "B18", role = "relay", x = 0,   y = 126 },
		} },
	},
}
