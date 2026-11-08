-- Station screen view-model (GR5-73, spec §6.6 T3, §7): stock per resource, used / capacity, docked ships, freighters and the
-- Logisticians of the main station and of each outpost (one tab per station). Pure reads of the sim, so it is testable headless.
local Logistics = require("@scripts/sim/logistics")
local World = require("@scripts/config/world")
local FleetView = require("@scripts/ui/fleet_view")

local View = {}

function View.new() return { station = nil } end

-- The tab to show: the picked station when it still exists, else the home one.
local function selected(sim, state)
  local id = state and state.station
  if id and sim.stations[id] then return id end
  return sim.home
end

local function stockRows(sim, st, cap)
  local rows = {}
  for _, ore in ipairs(sim.b.ores) do
    local q = math.floor(st.stock[ore] or 0)
    rows[#rows + 1] = { id = ore, name = World.ores[ore].name, qty = q, percent = cap > 0 and math.floor(100 * q / cap) or 0 }
  end
  return rows
end

local function dockedShips(sim, st)
  local out = {}
  for _, sid in ipairs(sim.shipOrder) do
    local s = sim.ships[sid]
    if s.state == "idle" and s.at == st.planet then
      local hold = s.cargo > 0 and ("%d %s"):format(math.floor(s.cargo), s.ore) or "hold empty"
      out[#out + 1] = { id = sid, owner = s.owner, text = ("%s  %s  %s"):format(sid, s.owner and ("run by " .. s.owner) or "no agent", hold) }
    end
  end
  return out
end

local function freighterRows(sim, st)
  local out = {}
  for _, f in ipairs(Logistics.freighterRows(sim, st.id)) do
    local text = f.state == "docked" and (f.id .. "  docked")
      or ("%s  %s  eta %ds"):format(f.id, f.cargo and ("-> " .. f.dest .. " " .. f.cargo) or ("back to " .. f.dest), f.eta)
    out[#out + 1] = { id = f.id, state = f.state, text = text }
  end
  return out
end

local function logisticianRows(sim, st)
  local out = {}
  for _, id in ipairs(Logistics.logisticiansAt(sim, st.id)) do
    out[#out + 1] = { id = id, state = sim.agents[id].state, text = ("%s  %s"):format(id, sim.agents[id].state) }
  end
  return out
end

function View.model(sim, state)
  local pick = selected(sim, state)
  local tabs = {}
  for _, id in ipairs(sim.stationOrder) do
    tabs[#tabs + 1] = { id = id, label = Logistics.label(sim.stations[id]), active = id == pick, action = "station.tab." .. id }
  end
  local st = sim.stations[pick]
  local cap = Logistics.storageCap(sim, st)
  local used = math.floor(Logistics.used(st))
  local hub = sim.upgrades.hub == true
  local idle = Logistics.idleReason(sim, "station", st.id)
  return {
    tabs = tabs, showTabs = #tabs > 1,
    id = st.id, label = Logistics.label(st), planet = World.planets[st.planet].name, kind = st.kind,
    stock = stockRows(sim, st, cap), used = used, capacity = cap, percent = cap > 0 and math.floor(100 * used / cap) or 0,
    usedText = ("%d / %d"):format(used, cap),
    ships = dockedShips(sim, st),
    hub = hub, freighters = freighterRows(sim, st), freighterCap = Logistics.freighterCap(sim, st),
    logisticians = logisticianRows(sim, st),
    idleText = hub and idle and ("Idle: " .. FleetView.why(idle)) or nil,
  }
end

function View.signature(sim, state)
  local pick = selected(sim, state)
  local parts = { pick, tostring(#sim.stationOrder), tostring(sim.upgrades.hub) }
  local st = sim.stations[pick]
  for _, ore in ipairs(sim.b.ores) do parts[#parts + 1] = math.floor(st.stock[ore] or 0) end
  for _, sid in ipairs(sim.shipOrder) do
    local s = sim.ships[sid]
    if s.state == "idle" and s.at == st.planet then parts[#parts + 1] = sid .. ":" .. math.floor(s.cargo) end
  end
  for _, f in ipairs(sim.freighters) do if f.station == pick then parts[#parts + 1] = f.id .. f.state end end
  for _, id in ipairs(Logistics.logisticiansAt(sim, pick)) do parts[#parts + 1] = id .. sim.agents[id].state end
  return table.concat(parts, ",")
end

-- "station.tab.<id>" -> handled.
function View.act(state, action)
  if type(action) ~= "string" then return false end
  local id = action:match("^station%.tab%.([%w_]+)$")
  if not id then return false end
  state.station = id
  return true
end

return View
