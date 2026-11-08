-- Logistics (spec §5.2, §6.5-6.7, D17, D21): stations with their own stock, freighters, hangars, outposts and
-- Logisticians. A station is keyed by its planet id; the main station is the home planet and its stock IS
-- `sim.warehouse`. Pure sim logic: the fleet screen only calls the buy/hire functions and reads the snapshots.
local Logistics = {}

function Logistics.init(sim)
  sim.stations = { [sim.home] = { id = sim.home, planet = sim.home, kind = "main", stock = sim.warehouse, hangar = 0 } }
  sim.stationOrder = { sim.home }
end

local function cfg(sim) return sim.b.logistics end

function Logistics.station(sim, id) return sim.stations[id or ""] end

function Logistics.label(st) return (st.kind == "main" and "main@" or "outpost@") .. st.planet end

function Logistics.used(st)
  local n = 0
  for _, q in pairs(st.stock) do n += q end
  return n
end

function Logistics.storageCap(sim, st)
  return st.kind == "main" and sim.b.warehouse.capacity or cfg(sim).outpostStorage
end

function Logistics.freighterCap(sim, st)
  local c = cfg(sim)
  return (st.kind == "main" and c.mainFreighters or c.outpostFreighters) + st.hangar * c.hangarSlots
end

function Logistics.freightersAt(sim, stationId)
  local out = {}
  for _, f in ipairs(sim.freighters) do if f.station == stationId then out[#out + 1] = f end end
  return out
end

function Logistics.logisticiansAt(sim, stationId)
  local out = {}
  for _, id in ipairs(sim.agentOrder) do
    local a = sim.agents[id]
    if a.type == "logistician" and a.station == stationId then out[#out + 1] = id end
  end
  return out
end

-- Free storage at a station.
function Logistics.room(sim, st) return Logistics.storageCap(sim, st) - Logistics.used(st) end

local function hubOpen(sim) return sim.upgrades.hub == true end

-- Each blocker returns nil when the action is possible, else a code the UI turns into a sentence.
function Logistics.freighterBlocker(sim, stationId)
  local st = sim.stations[stationId or ""]
  if not st then return "unknown_station" end
  if not hubOpen(sim) then return "hub_locked" end
  if #Logistics.freightersAt(sim, stationId) >= Logistics.freighterCap(sim, st) then return "hangar_full" end
  if sim.resources.credits < cfg(sim).freighterCost then return "not_enough_credits" end
  return nil
end

function Logistics.buyFreighter(sim, stationId)
  local why = Logistics.freighterBlocker(sim, stationId)
  if why then
    sim:log("ERROR", ("freighter: cannot buy at %s (%s)"):format(tostring(stationId), why))
    return false, why
  end
  sim.resources.credits -= cfg(sim).freighterCost
  local f = sim:addFreighter(stationId)
  sim:log("INFO", ("freighter %s bought at %s"):format(f.id, stationId))
  sim:emit("freighter_bought", { id = f.id, station = stationId })
  return true, f.id
end

function Logistics.hangarBlocker(sim, stationId)
  if not sim.stations[stationId or ""] then return "unknown_station" end
  if not hubOpen(sim) then return "hub_locked" end
  if sim.resources.credits < cfg(sim).hangarCost then return "not_enough_credits" end
  return nil
end

function Logistics.buyHangar(sim, stationId)
  local why = Logistics.hangarBlocker(sim, stationId)
  if why then
    sim:log("ERROR", ("hangar: cannot extend %s (%s)"):format(tostring(stationId), why))
    return false, why
  end
  sim.resources.credits -= cfg(sim).hangarCost
  sim.stations[stationId].hangar += 1
  sim:log("INFO", ("hangar extension at %s"):format(stationId))
  sim:emit("hangar_bought", { station = stationId })
  return true
end

-- D21: an outpost on any harvest planet the fleet can reach, except the home planet.
function Logistics.outpostBlocker(sim, planetId)
  local c = cfg(sim)
  if not sim.planets[planetId or ""] then return "unknown_planet" end
  if planetId == sim.home then return "home_planet" end
  if sim.tier < c.outpostTier then return "tier_locked" end
  if sim.stations[planetId] then return "already_built" end
  if not sim:inRange(sim.ships[sim.shipOrder[1]], planetId) then return "out_of_range" end
  if sim.resources.credits < c.outpostCost then return "not_enough_credits" end
  return nil
end

function Logistics.buildOutpost(sim, planetId)
  local why = Logistics.outpostBlocker(sim, planetId)
  if why then
    sim:log("ERROR", ("outpost: cannot build on %s (%s)"):format(tostring(planetId), why))
    return false, why
  end
  sim.resources.credits -= cfg(sim).outpostCost
  local stock = {}
  for _, ore in ipairs(sim.b.ores) do stock[ore] = 0 end
  sim.stations[planetId] = { id = planetId, planet = planetId, kind = "outpost", stock = stock, hangar = 0 }
  sim.stationOrder[#sim.stationOrder + 1] = planetId
  sim:log("INFO", ("outpost built on %s"):format(planetId))
  sim:emit("outpost_built", { station = planetId })
  return true
end

function Logistics.hireBlocker(sim, stationId)
  if not sim.stations[stationId or ""] then return "unknown_station" end
  if not hubOpen(sim) then return "hub_locked" end
  if #Logistics.logisticiansAt(sim, stationId) >= cfg(sim).logisticiansPerStation then return "station_full" end
  if #sim.agentOrder >= sim:commandCapacity() then return "command_capacity" end
  return nil
end

-- Hiring is free (spec §6.7) but every agent takes a command slot.
function Logistics.hire(sim, stationId)
  local why = Logistics.hireBlocker(sim, stationId)
  if why then
    sim:log("ERROR", ("hire: cannot hire a Logistician at %s (%s)"):format(tostring(stationId), why))
    return false, why
  end
  local n, id = 1, "logistician"
  while sim.agents[id] do n += 1; id = "logistician_" .. n end
  sim:addAgent(id, "logistician", { tier = sim.tier, station = stationId })
  sim:log("INFO", ("%s: hired at %s (empty directive)"):format(id, stationId))
  sim:emit("agent_added", { agent = id, station = stationId })
  return true, id
end

-- Why a ship or station does nothing, for the UI: nil when it is staffed.
function Logistics.idleReason(sim, kind, key)
  if kind == "ship" then
    if sim.ships[key].owner then return nil end
    if #sim.agentOrder >= sim:commandCapacity() then return "command_capacity" end
    return "no_agent"
  end
  if #Logistics.logisticiansAt(sim, key) > 0 then return nil end
  if not hubOpen(sim) then return "hub_locked" end
  if #sim.agentOrder >= sim:commandCapacity() then return "command_capacity" end
  return "no_logistician"
end

-- One row per freighter of a station: id, state (docked|travelling), cargo "ore:qty", dest, eta in game seconds.
function Logistics.freighterRows(sim, stationId)
  local rows, dt = {}, sim.b.tickSeconds
  for _, f in ipairs(Logistics.freightersAt(sim, stationId)) do
    local row = { id = f.id, state = f.state == "idle" and "docked" or "travelling" }
    if f.state == "out" then
      row.cargo, row.dest, row.eta = f.load.resource .. ":" .. f.load.qty, f.load.destination, math.ceil(f.timer * dt)
    elseif f.state == "back" then
      row.dest, row.eta = stationId, math.ceil(f.timer * dt)
    end
    rows[#rows + 1] = row
  end
  return rows
end

return Logistics
