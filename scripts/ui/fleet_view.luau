-- Fleet screen view-model (GR5-12, spec §6.5-6.7, D17, D21): Reputation and command capacity, the logistics hub, every station
-- with its stock, freighters and Logisticians, outposts to build, and why a ship or station is idle. Pure reads and sim calls.
local Logistics = require("@scripts/sim/logistics")
local Upgrades = require("@scripts/sim/upgrades")
local World = require("@scripts/config/world")

local View = {}

local WHY = {
  hub_locked = "Build the logistics hub first",
  hangar_full = "Hangar full",
  not_enough_credits = "Not enough credits",
  station_full = "Station has its Logisticians",
  command_capacity = "Command capacity reached: raise Reputation",
  no_agent = "No agent assigned",
  no_logistician = "No Logistician: hire one",
  tier_locked = "Reach tier 4",
  already_built = "Built",
  out_of_range = "Out of range: upgrade the engine",
  home_planet = "Home planet",
}

function View.why(code) return code and (WHY[code] or code) or nil end

local function reputation(sim)
  local level, levels = sim:reputationLevel(), sim.b.reputationLevels
  local next_, base = levels[level + 1], levels[level] or 0
  local percent = 100
  if next_ then percent = math.floor(100 * math.min(1, math.max(0, (sim.lifetimeRevenue - base) / (next_ - base)))) end
  return { level = level, revenue = math.floor(sim.lifetimeRevenue), next = next_, percent = percent,
    used = #sim.agentOrder, capacity = sim:commandCapacity() }
end

local function hubRow(sim)
  for _, r in ipairs(Upgrades.catalog(sim)) do
    if r.id == "logistics_hub" then
      local note = r.blocker and r.blocker ~= "not_enough_credits" and (r.blocker:match("^reputation_(%d+)$") and ("Needs Reputation " .. r.blocker:match("%d+"))
        or r.blocker == "needs_warehouse" and "Needs the Warehouse" or r.blocker == "tier_locked" and ("Reach tier " .. r.tier) or r.blocker) or nil
      return { name = r.name, state = r.state, cost = r.cost, costText = ("%d cr"):format(r.cost), note = note, action = "shop.buy.logistics_hub" }
    end
  end
end

local function stationRow(sim, st)
  local c = sim.b.logistics
  local fr = Logistics.freightersAt(sim, st.id)
  local idle = Logistics.idleReason(sim, "station", st.id)
  local stock = {}
  for _, ore in ipairs(sim.b.ores) do
    local q = st.stock[ore] or 0
    if q > 0 then stock[#stock + 1] = ("%s %d"):format(ore, math.floor(q)) end
  end
  local opens = {
    freighter = Logistics.freighterBlocker(sim, st.id), hangar = Logistics.hangarBlocker(sim, st.id), hire = Logistics.hireBlocker(sim, st.id),
  }
  return {
    id = st.id, label = Logistics.label(st), kind = st.kind,
    stockText = ("%s  %d/%d"):format(#stock > 0 and table.concat(stock, ", ") or "empty", Logistics.used(st), Logistics.storageCap(sim, st)),
    freighters = #fr, freighterCap = Logistics.freighterCap(sim, st), hangar = st.hangar,
    freighterRows = Logistics.freighterRows(sim, st.id),
    logisticians = Logistics.logisticiansAt(sim, st.id),
    idle = idle, idleText = View.why(idle) and ("Idle: " .. View.why(idle)) or nil,
    freighterCost = c.freighterCost, hangarCost = c.hangarCost,
    canFreighter = opens.freighter == nil, canHangar = opens.hangar == nil, canHire = opens.hire == nil,
    freighterNote = View.why(opens.freighter), hangarNote = View.why(opens.hangar), hireNote = View.why(opens.hire),
    actions = { freighter = "fleet.freighter." .. st.id, hangar = "fleet.hangar." .. st.id, hire = "fleet.hire." .. st.id },
  }
end

function View.model(sim)
  local stations = {}
  for _, id in ipairs(sim.stationOrder) do stations[#stations + 1] = stationRow(sim, sim.stations[id]) end
  local outposts = {}
  for _, pid in ipairs(World.planetOrder) do
    if pid ~= sim.home and not sim.stations[pid] then
      local why = Logistics.outpostBlocker(sim, pid)
      outposts[#outposts + 1] = { planet = pid, cost = sim.b.logistics.outpostCost, can = why == nil, note = View.why(why),
        action = "fleet.outpost." .. pid }
    end
  end
  local ships = {}
  for _, sid in ipairs(sim.shipOrder) do
    local s = sim.ships[sid]
    local idle = Logistics.idleReason(sim, "ship", sid)
    ships[#ships + 1] = { id = sid, owner = s.owner, idle = idle,
      text = ("%s  %s"):format(sid, s.owner and ("run by " .. s.owner) or ("Idle: " .. View.why(idle))) }
  end
  return { reputation = reputation(sim), hub = hubRow(sim), hubOpen = sim.upgrades.hub == true, stations = stations,
    outposts = outposts, ships = ships, credits = math.floor(sim.resources.credits) }
end

function View.signature(sim)
  local parts = { tostring(sim:reputationLevel()), tostring(#sim.agentOrder), tostring(sim.upgrades.hub), tostring(math.floor(sim.resources.credits / 100)) }
  for _, id in ipairs(sim.stationOrder) do
    local st = sim.stations[id]
    parts[#parts + 1] = id .. Logistics.used(st) .. "/" .. #Logistics.freightersAt(sim, id) .. "/" .. st.hangar .. "/" .. #Logistics.logisticiansAt(sim, id)
  end
  for _, f in ipairs(sim.freighters) do parts[#parts + 1] = f.id .. f.state end
  return table.concat(parts, ",")
end

-- "fleet.<freighter|hangar|hire|outpost>.<id>" -> handled, ok, err.
function View.act(sim, action)
  if type(action) ~= "string" then return false end
  local kind, id = action:match("^fleet%.(%a+)%.([%w_]+)$")
  if not kind then return false end
  if kind == "freighter" then return true, sim:buyFreighter(id) end
  if kind == "hangar" then return true, sim:buyHangar(id) end
  if kind == "hire" then return true, sim:hireLogistician(id) end
  if kind == "outpost" then return true, sim:buildOutpost(id) end
  return false
end

return View
