-- Orbital stations (GR5-18): a station is a hub sprite plus attached modules (config/stations.luau), static, recoloured
-- by the palette remap (client/remap.luau) onto its corporation's ramp. idle/active only changes brightness and the
-- emissive fade; the bloom params for that state come from render/vfx/bloom. Client only.
local config = require("@scripts/config/stations")
local Bloom = require("@scripts/render/vfx/bloom")
local Remap = require("@scripts/client/remap")

local Stations = {}

local function assets() return Stations.assets or engine.assets end

-- Params of the emissive-only bloom for a state ("idle" or "active").
function Stations.bloom(state: string)
	assert(config.states[state], "Stations: unknown state '" .. tostring(state) .. "'")
	local b = config.bloom
	return Bloom.params(state == "active" and b.intensityActive or b.intensityIdle)
end

-- The remap material of a station in a state; `corp` overrides the station's configured corporation.
function Stations.material(stationId: string, state: string, corp: string?)
	local s = config.states[state]
	assert(s, "Stations: unknown state '" .. tostring(state) .. "'")
	assert(config.stations[stationId], "Stations: unknown station '" .. tostring(stationId) .. "'")
	return Remap.material(corp or config.corp[stationId], {
		steps = config.steps[stationId] or config.steps.default,
		brightness = s.brightness,
		emissiveScale = s.emissiveScale,
	})
end

-- Entity descriptions (hub first) to pass to ctx.commands:spawn(). position: station centre in world units;
-- scale: world units per sprite pixel.
function Stations.entities(stationId: string, state: string, position, scale: number?, corp: string?)
	local def = config.stations[stationId]
	assert(def, "Stations: unknown station '" .. tostring(stationId) .. "'")
	local material, k, out = Stations.material(stationId, state, corp), scale or 1, {}
	for _, m in ipairs(def.modules) do
		out[#out + 1] = {
			["rtype.Transform"] = {
				position = { x = position.x + m.x * k, y = position.y + m.y * k },
				scale = { x = k, y = k },
			},
			["rtype.SpriteRenderer"] = {
				texture = assets().texture(config.spriteDir .. m.sprite .. ".png"),
				source = { x = 0, y = 0, z = m.w, w = m.h },
				origin = { x = m.w / 2, y = m.h / 2 },
				material = material,
				layer = config.layer,
			},
		}
	end
	return out
end

return Stations
