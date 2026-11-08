-- World side of the system map (GR5-3): one slowly rotating pixel planet per harvest planet, lit in its colour when the
-- player can reach it and greyed (config.planets.locked) when not. Labels, routes and convoys are UI (ui/shell.luau) and
-- use the same positions (Shell.planetPositions), so the two layers line up. Client only.
local Planets = require("@scripts/config/planets")
local Screens = require("@scripts/config/screens")
local World = require("@scripts/config/world")
local StationsConfig = require("@scripts/config/stations")
local Planet = require("@scripts/client/planet")
local Stations = require("@scripts/client/stations")
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

-- The stations drawn on the map, in order (GR5-52): { id = station config key, at = view-pixel centre, scale, state, upgrades }.
-- The player's depot at Kessa grows with the upgrades; a built outpost shows on its planet; a market's station shows once the
-- market is unlocked and is active while a freighter is on its way there.
function SystemMap.stations(sim)
	local cfg, planets, out = StationsConfig.map, Shell.planetPositions(), {}
	local upgrades = sim.upgrades or {}
	local home = planets[cfg.home.planet]
	local def = cfg.home
	out[#out + 1] = { id = def.station, at = { x = home.x + def.dx, y = home.y + def.dy }, scale = def.scale, state = "active", upgrades = upgrades }
	for _, pid in ipairs(World.planetOrder) do
		local st, o = sim.stations and sim.stations[pid], cfg.outposts[pid]
		if st and st.kind == "outpost" and o then
			out[#out + 1] = { id = o.station, at = { x = planets[pid].x + o.dx, y = planets[pid].y + o.dy }, scale = o.scale, state = "active" }
		end
	end
	local bound = {}
	for _, f in ipairs(sim.freighters or {}) do
		if f.state == "out" and f.load then bound[f.load.destination] = true end
	end
	for _, mid in ipairs(World.marketOrder) do
		local m, pos = World.markets[mid], cfg.markets[mid]
		if m and pos and sim.tier >= m.unlockTier then
			local node = Screens.map.markets[mid]
			local p = Shell.mapPoint(node.x, node.y)
			local b = Stations.bounds(pos.station, nil, pos.scale)
			out[#out + 1] = { id = pos.station, at = { x = p.x, y = p.y - cfg.marketGap - b.bottom }, scale = pos.scale, state = bound[mid] and "active" or "idle" }
		end
	end
	return out
end

-- Entity descriptions of every station on the map (client/station_fx animates the turrets in them).
function SystemMap.stationEntities(sim)
	local out = {}
	for _, s in ipairs(SystemMap.stations(sim)) do
		for _, desc in ipairs(Stations.entities(s.id, s.state, s.at, s.scale, nil, s.upgrades)) do out[#out + 1] = desc end
	end
	return out
end

-- Changes when a station appears, grows, or flips idle/active: the station layer is respawned then.
function SystemMap.stationSignature(sim)
	local parts = {}
	for _, s in ipairs(SystemMap.stations(sim)) do
		local stages = {}
		for _, stage in ipairs(StationsConfig.stations[s.id].stages or {}) do
			if s.upgrades and s.upgrades[stage.when] then stages[#stages + 1] = stage.when end
		end
		parts[#parts + 1] = s.id .. ":" .. s.state .. ":" .. table.concat(stages, "+")
	end
	return table.concat(parts, ",")
end

return SystemMap
