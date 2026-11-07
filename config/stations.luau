-- Station visuals config (GR5-18). Data only: no logic, no engine calls.
-- Sprite names refer to files of the Wenrexa "Space Modular Buildings" pack, to be dropped in
-- assets/stations/raw/ (see assets/stations/README.md). `modules` are TODO until the pack is imported:
-- the 177 file names must be read from the actual download before picking.

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

	stations = {
		hmc_depot          = { label = "HMC Depot",           modules = {} },
		orbis_exchange     = { label = "Orbis Exchange",      modules = {} },
		halcyon_shipyards  = { label = "Halcyon Shipyards",   modules = {} },
		meridian_institute = { label = "Meridian Institute",  modules = {} },
	},
}
