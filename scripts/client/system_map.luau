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
local Theme = require("@scripts/config/theme")
local Model = require("@scripts/ui/shell_model")
local Logistics = require("@scripts/sim/logistics")
local Refining = require("@scripts/sim/refining")
local MapLife = require("@scripts/client/map_life")

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

-- The biggest scale (<= def.scale) at which the station's whole extent fits def.fit (px), if it has one.
local function fitScale(id: string, upgrades, def, maxHeight: number?)
	local e, k = Stations.extent(id, upgrades, 1), def.scale
	if def.fit then
		local grow = (def.fit.perStage or 0) * #Stations.stagesReached(id, upgrades)
		k = math.min(k, (def.fit.w + grow) / (e.right - e.left), (def.fit.h + grow) / (e.bottom - e.top))
	end
	if maxHeight then k = math.min(k, maxHeight / (e.bottom - e.top)) end
	return k
end

-- Moves `at` so the extent of the station (at `k`) stays `edge` px inside the main panel.
local function keepInside(at, e, k: number)
	local m, edge = Shell.layout().main, StationsConfig.map.edge
	local x = math.max(m.x + edge - e.left * k, math.min(m.x + m.w - edge - e.right * k, at.x))
	local y = math.max(m.y + edge - e.top * k, math.min(m.y + m.h - edge - e.bottom * k, at.y))
	return { x = x, y = y }
end

-- The stations drawn on the map, in order (GR5-52): { id = station config key, at = view-pixel hub centre, scale, state, upgrades,
-- planet = the view-pixel centre of the planet it hangs off (the depot and outposts), label }.
-- The player's depot at Kessa grows with the upgrades; a built outpost shows on its planet; a market's station shows once the
-- market is unlocked, above its node, and is active while a freighter is on its way there.
function SystemMap.stations(sim)
	local cfg, planets, out = StationsConfig.map, Shell.planetPositions(), {}
	local upgrades = sim.upgrades or {}
	local function hung(def, planet, ups, state, sid)
		local k = fitScale(def.station, ups, def)
		local e = Stations.extent(def.station, ups, 1)
		local at = keepInside({ x = planet.x + def.dx, y = planet.y + def.dy }, e, k)
		out[#out + 1] = { id = def.station, sid = sid, at = at, scale = k, state = state, upgrades = ups, planet = planet, label = def.label }
	end
	hung(cfg.home, planets[cfg.home.planet], upgrades, "active", cfg.home.planet)
	for _, pid in ipairs(World.planetOrder) do
		local st, o = sim.stations and sim.stations[pid], cfg.outposts[pid]
		if st and st.kind == "outpost" and o then hung(o, planets[pid], nil, "active", pid) end
	end
	local bound = {}
	for _, f in ipairs(sim.freighters or {}) do
		if f.state == "out" and f.load then bound[f.load.destination] = true end
	end
	local panel = Shell.layout().main
	for _, mid in ipairs(World.marketOrder) do
		local m, pos = World.markets[mid], cfg.markets[mid]
		if m and pos and sim.tier >= m.unlockTier then
			local node = Screens.map.markets[mid]
			local p = Shell.mapPoint(node.x, node.y)
			local e, at, k = Stations.extent(pos.station, nil, 1), nil, nil
			if pos.side == "left" or pos.side == "right" then
				k = fitScale(pos.station, nil, pos, panel.h - 2 * cfg.edge)
				local x = pos.side == "left" and p.x - cfg.marketGap - e.right * k or p.x + cfg.marketGap - e.left * k
				at = { x = x, y = p.y - (e.top + e.bottom) / 2 * k }
			else
				k = fitScale(pos.station, nil, pos, p.y - cfg.marketGap - panel.y - cfg.edge)
				at = { x = p.x, y = p.y - cfg.marketGap - e.bottom * k }
			end
			at = keepInside(at, e, k)
			out[#out + 1] = { id = pos.station, at = at, scale = k, state = bound[mid] and "active" or "idle" }
		end
	end
	return out
end

-- What a station is doing, from the sim and nothing else (GR5-104): ACTIVE while one of its freighters is out or back, FULL (an
-- alert) while the sim's station_full alert is up, IDLE otherwise. The sim has no station damage, so none is shown.
function SystemMap.status(sim, sid: string?)
	if sid and sim.alertTrack and sim.alertTrack.stations[sid] then return MapLife.badge("warning", "FULL") end
	for _, f in ipairs(sim.freighters or {}) do
		if f.station == sid and (f.state == "out" or f.state == "back") then return MapLife.badge("working", "ACTIVE") end
	end
	return MapLife.badge("waiting", "IDLE")
end

-- The roles that live at a station (never on a ship): LOG for its Logisticians, MON for the Monitor at the command centre, REF
-- for a Refiner at its refinery. Each tag wears its agent's real state (paused_error magenta, no_compute amber).
function SystemMap.tags(sim, sid: string?)
	local out = {}
	if not sid then return out end
	local function tag(agent, label: string)
		out[#out + 1] = MapLife.agentBadge(agent, agent and agent.state == "acting" and "working" or "waiting", label)
	end
	for _, id in ipairs(Logistics.logisticiansAt(sim, sid)) do tag(sim.agents[id], "LOG") end
	if sid == StationsConfig.map.home.planet and sim.agents.monitor and sim.upgrades and sim.upgrades.commandCenter then tag(sim.agents.monitor, "MON") end
	local ref = sim.refining and Refining.refineryAt(sim, sid)
	if ref and ref.owner and sim.agents[ref.owner] then tag(sim.agents[ref.owner], "REF") end
	return out
end

-- UI side of the planet stations (the depot and the outposts): the label above the station and the dock line from the planet
-- to its hub, in view pixels, with the station's status and role tags. { label, at = label centre top, from, to, skipFrom,
-- skipTo, status, tags }.
function SystemMap.stationLabels(sim)
	local cfg, out = StationsConfig.map, {}
	for _, s in ipairs(SystemMap.stations(sim)) do
		if s.planet then
			local e = Stations.extent(s.id, s.upgrades, s.scale)
			local hub = Stations.parts(s.id, s.upgrades).modules[1]
			local top = math.max(Shell.layout().main.y + 2, s.at.y + e.top - 18)
			out[#out + 1] = {
				label = s.label, at = { x = s.at.x + (e.left + e.right) / 2, y = top },
				from = s.planet, to = s.at, skipFrom = Screens.map.planetRadius + cfg.dock.gap, skipTo = math.max(hub.w, hub.h) / 2 * s.scale,
				spacing = cfg.dock.spacing, status = SystemMap.status(sim, s.sid), tags = SystemMap.tags(sim, s.sid),
			}
		end
	end
	return out
end

-- Rectangles the ships' badges and berths keep clear of: the silhouette and name of every station, the planet and market
-- labels (sized from their text). View pixels.
function SystemMap.reserved(sim)
	local T, cfg, out = Theme.type, Screens.map, {}
	local main = Shell.layout().main
	local function text(w: number, size: number) return w * size * 0.6 end
	local function label(center, name: string, sub: string, below: number)
		local w = math.min(180, math.max(text(#name, T.body), text(#sub, T.small)))
		local left = math.max(main.x + Theme.layout.gap, math.min(center.x - 90, main.x + main.w - 180 - Theme.layout.gap)) + 90
		out[#out + 1] = { x = left - w / 2, y = center.y + below, w = w, h = T.body + T.small + 4 }
	end
	local view = Model.map(sim)
	for _, p in ipairs(view.planets) do
		label(Shell.mapPoint(p.x, p.y), p.name, p.lit and table.concat(p.ores, ", ") or ("Locked: " .. p.condition), cfg.planetRadius + 8)
	end
	for _, m in ipairs(view.markets) do
		label(Shell.mapPoint(m.x, m.y), m.name, ("T%d market"):format(m.tier), 14)
	end
	for _, s in ipairs(SystemMap.stations(sim)) do
		local e = Stations.extent(s.id, s.upgrades, s.scale)
		out[#out + 1] = { x = s.at.x + e.left, y = s.at.y + e.top, w = e.right - e.left, h = e.bottom - e.top }
		if s.label then
			local w = text(#s.label, T.small)
			out[#out + 1] = { x = s.at.x + (e.left + e.right) / 2 - w / 2, y = math.max(main.y + 2, s.at.y + e.top - 18), w = w, h = T.small + 16 }
		end
	end
	return out
end

-- Entity descriptions of every station on the map (client/station_fx animates the turrets in them).
function SystemMap.stationEntities(sim)
	local out = {}
	for i, s in ipairs(SystemMap.stations(sim)) do
		for _, desc in ipairs(Stations.entities(s.id, s.state, s.at, s.scale, nil, s.upgrades)) do
			local turret = desc["game.StationTurret"]
			if turret then turret.site = i end
			out[#out + 1] = desc
		end
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
