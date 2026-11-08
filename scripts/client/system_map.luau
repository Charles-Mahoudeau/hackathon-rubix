-- World side of the system map (GR5-3): one slowly rotating pixel planet per harvest planet, lit in its colour when the
-- player can reach it and greyed (config.planets.locked) when not. Labels, routes and convoys are UI (ui/shell.luau) and
-- use the same positions (Shell.planetPositions), so the two layers line up. Client only.
local Planets = require("@scripts/config/planets")
local Screens = require("@scripts/config/screens")
local Planet = require("@scripts/client/planet")
local Shell = require("@scripts/ui/shell")
local Model = require("@scripts/ui/shell_model")

local SystemMap = {}

-- The look of a planet: its own when lit, its seed and shape in the locked colours when not.
function SystemMap.look(id: string, lit: boolean)
	local def = Planets.planets[id]
	if lit then return def end
	local look = table.clone(def)
	look.land, look.water, look.cloud, look.rim = Planets.locked.land, Planets.locked.water, Planets.locked.cloud, Planets.locked.rim
	return look
end

-- Entity descriptions for the 4 harvest planets, in World.planetOrder. `lit` per id comes from Model.map.
function SystemMap.entities(sim)
	local positions, out = Shell.planetPositions(), {}
	for _, p in ipairs(Model.map(sim).planets) do
		local key = p.lit and p.id or (p.id .. ".locked")
		out[#out + 1] = Planet.fromDef(key, SystemMap.look(p.id, p.lit), Screens.map.planetRadius, positions[p.id])
	end
	return out
end

-- Changes only when a planet unlocks: the world layer is respawned then, not every refresh.
function SystemMap.signature(sim)
	local parts = {}
	for _, p in ipairs(Model.map(sim).planets) do parts[#parts + 1] = p.id .. (p.lit and "+" or "-") end
	return table.concat(parts, ",")
end

return SystemMap
