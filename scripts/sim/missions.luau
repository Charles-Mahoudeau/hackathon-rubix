-- Missions (spec §15): the tutorial. One mission is active at a time, in order; the checks read sim state (a sale hook
-- for trips, plain state for the rest), so nothing is triggered by hand. State lives in `sim.missions` (a list, one entry
-- per mission, saved with the game). Rewards are paid on claim and are NOT revenue (they never count toward tiers or mission 3).
-- Pure Luau, headless, no UI calls: the panel (ui/missions_view.luau) reads progress() and calls claim() / retry().
local Config = require("@scripts/config/missions")
local World = require("@scripts/config/world")
local DecisionLog = require("./decision_log")
local Logistics = require("./logistics")

local Missions = {}

local function defOf(id)
  for _, d in ipairs(Config.missions) do if d.id == id then return d end end
  return nil
end

function Missions.def(id) return defOf(id) end

function Missions.new()
  local list = {}
  for _, d in ipairs(Config.missions) do list[#list + 1] = { id = d.id, status = "locked" } end
  return list
end

-- Computes spent since the baseline, rounded to the 0.1 billing step so float noise never flips a threshold.
local function computeSpent(sim, e)
  return math.floor((sim.compute.lifetimeTotal - e.baseCompute) * 10 + 0.5) / 10
end

-- Compute the Monitor spent since the mission opened, on the same 0.1 billing step.
local function monitorSpent(sim, e)
  return math.floor(((sim.compute.lifetime.monitor or 0) - e.baseMonitor) * 10 + 0.5) / 10
end

-- Worker agents of every branch (spec §15b.0): all but the Logisticians and the Monitor, in agent order.
local function workerIds(sim)
  local ids = {}
  for _, id in ipairs(sim.agentOrder) do
    local agent = sim.agents[id]
    if agent and agent.type ~= "logistician" and agent.type ~= "monitor" then ids[#ids + 1] = id end
  end
  return ids
end

-- Workers grouped by branch (agent type), in first-seen order: -> { { type, ids }, ... }
local function groupsOf(sim, ids)
  local groups, byType = {}, {}
  for _, id in ipairs(ids) do
    local t = sim.agents[id].type
    if not byType[t] then byType[t] = { type = t, ids = {} }; groups[#groups + 1] = byType[t] end
    local g = byType[t].ids
    g[#g + 1] = id
  end
  return groups
end

local function salvageShipOf(sim, id)
  for _, sid in ipairs(sim.salvageOrder or {}) do
    if sim.salvageShips[sid].owner == id then return sim.salvageShips[sid] end
  end
  return nil
end

local function salvaging(ship) return ship.state == "surveying" or ship.state == "salvaging" end

-- One tick of a worker for mission 6: is it working, and is it sharing its vein (Miners) or site (Scavengers) with another ship?
local function workerTick(sim, id)
  local agent = sim.agents[id]
  if agent.type == "miner" then
    local ship = sim:ownedShip(id)
    return ship.state == "mining", ship.state == "mining" and #ship.crowdedBy > 0
  elseif agent.type == "scavenger" then
    local ship = salvageShipOf(sim, id)
    if not ship or not salvaging(ship) or not ship.job then return false, false end
    for _, sid in ipairs(sim.salvageOrder) do
      local other = sim.salvageShips[sid]
      if other ~= ship and salvaging(other) and other.job and other.job.site == ship.job.site then return true, true end
    end
    return true, false
  end
  return agent.state == "acting", false
end

-- Fresh counters for a mission that just opened (or is retried).
local function begin(sim, e, d)
  if d.check == "streak" then e.streaks = {}
  elseif d.check == "scout" then e.scanner, e.scanned, e.sold = false, false, false
  elseif d.check == "skillcredit" then e.saved, e.earned = false, 0
  elseif d.check == "orbis" then e.units = 0
  elseif d.check == "teamwork" then
    e.startTick, e.failed, e.lastTick, e.agents, e.earned, e.mining, e.crowded = sim.tick, false, -1, {}, {}, {}, {}
    for _, id in ipairs(workerIds(sim)) do
      e.agents[#e.agents + 1] = id
      e.earned[id], e.mining[id], e.crowded[id] = 0, 0, 0
    end
  elseif d.check == "divide" then
    e.startTick, e.failed, e.errors, e.lastTick, e.agents, e.deliveries = sim.tick, false, 0, -1, {}, {}
    for _, sid in ipairs(sim.stationOrder) do
      local at = Logistics.logisticiansAt(sim, sid)
      if #at >= 2 then
        e.station = sid
        for _, id in ipairs(at) do e.agents[#e.agents + 1] = id; e.deliveries[id] = 0 end
        break
      end
    end
  elseif d.check == "watch" then e.resolved, e.pending, e.failed, e.baseMonitor = 0, {}, false, sim.compute.lifetime.monitor or 0
  elseif d.check == "frugal" then e.baseRevenue, e.baseCompute, e.failed = sim.lifetimeRevenue, sim.compute.lifetimeTotal, false end
end

-- The first mission not yet claimed: the only one that can be locked-with-a-reason, active or complete.
function Missions.current(sim)
  for i, e in ipairs(sim.missions) do
    if e.status ~= "claimed" then return e, defOf(e.id), i end
  end
  return nil
end

local function startMet(sim, d)
  local s = d.start
  if s == nil then return true end
  if s.tier and sim.tier < s.tier then return false end
  for _, u in ipairs(s.upgrades or {}) do if not sim.upgrades[u] then return false end end
  if s.ships then
    local found = false
    for _, g in ipairs(groupsOf(sim, workerIds(sim))) do
      if #g.ids >= s.ships then found = true end
    end
    if not found then return false end
  end
  if s.logisticians then
    local found = false
    for _, sid in ipairs(sim.stationOrder) do
      if #Logistics.logisticiansAt(sim, sid) >= s.logisticians then found = true end
    end
    if not found then return false end
  end
  return true
end

local UPGRADE_LABEL = { warehouse = "the warehouse", tradingPost = "the trading post", commandCenter = "the command center" }

-- Why the current mission has not started: nil once its `start` holds.
function Missions.lockReason(sim, d)
  local s = d.start
  if s and s.tier and sim.tier < s.tier then return ("Reach tier %d"):format(s.tier) end
  local need = {}
  for _, u in ipairs(s and s.upgrades or {}) do
    if not sim.upgrades[u] then need[#need + 1] = UPGRADE_LABEL[u] or u end
  end
  if #need > 0 then return "Build " .. table.concat(need, " and ") end
  if s and s.ships then return ("Buy ship #%d in one branch"):format(s.ships) end
  if s and s.logisticians then return ("Hire %d Logisticians at one station"):format(s.logisticians) end
  return nil
end

local function streakBest(e)
  local best = 0
  for _, s in pairs(e.streaks or {}) do if s.n > best then best = s.n end end
  return best
end

local function windowTicks(sim, d) return sim:ticks(d.minutes * 60) end

-- Share of a Miner's mining ticks spent on a vein shared with another ship, in percent.
local function crowdPct(e, id)
  local m = e.mining[id] or 0
  return m > 0 and 100 * (e.crowded[id] or 0) / m or 0
end

-- Progress of an active mission: fraction 0..1 and the lines the panel shows under the bar.
function Missions.progress(sim, e)
  local d = defOf(e.id)
  if e.status == "claimed" then return { fraction = 1, text = "Claimed", lines = {} } end
  if e.status == "locked" then return { fraction = 0, text = Missions.lockReason(sim, d) or "Claim the previous mission", lines = {} } end
  if d.check == "streak" then
    local n = math.min(streakBest(e), d.trips)
    return { fraction = n / d.trips, text = ("%d / %d trips in a row"):format(n, d.trips), lines = {} }
  elseif d.check == "scout" then
    local done = { e.scanner, e.scanned, e.sold }
    local n, lines = 0, {}
    for i, label in ipairs(d.steps) do
      if done[i] then n += 1 end
      lines[#lines + 1] = { text = label, done = done[i] == true }
    end
    return { fraction = n / #d.steps, text = ("%d / %d steps"):format(n, #d.steps), lines = lines }
  elseif d.check == "skillcredit" then
    local earned = math.min(e.earned or 0, d.credits)
    local done = { e.saved, e.saved and earned >= d.credits }
    local lines = {}
    for i, label in ipairs(d.steps) do lines[#lines + 1] = { text = label, done = done[i] == true } end
    if not e.saved then return { fraction = 0, text = "Save a skill first", lines = lines } end
    return { fraction = earned / d.credits, text = ("%d / %d cr from skill steps"):format(math.floor(earned), d.credits), lines = lines }
  elseif d.check == "orbis" then
    local n = math.min(e.units or 0, d.units)
    return { fraction = n / d.units, text = ("%d / %d units to Orbis at %.1fx the HMC price"):format(n, d.units, d.minRatio), lines = {} }
  elseif d.check == "teamwork" then
    local lines, best = {}, 0
    for _, id in ipairs(e.agents) do
      local earned = e.earned[id] or 0
      lines[#lines + 1] = { text = ("%s: %d / %d cr, crowded %d%%"):format(id, math.floor(earned), d.creditsEach,
        math.floor(crowdPct(e, id) + 0.5)), done = earned >= d.creditsEach and crowdPct(e, id) < d.crowdMaxPct }
    end
    for _, g in ipairs(groupsOf(sim, e.agents)) do -- the mission is met by one branch's team: show the closest one
      local sum = 0
      for _, id in ipairs(g.ids) do sum += math.min(1, (e.earned[id] or 0) / d.creditsEach) end
      if #g.ids >= 2 and sum / #g.ids > best then best = sum / #g.ids end
    end
    local left = math.max(0, windowTicks(sim, d) - (sim.tick - e.startTick))
    local text = ("%d:%02d left"):format(math.floor(left / 600), math.floor(left / 10) % 60)
    if e.failed then text = "Window over, goals missed - retry" end
    return { fraction = best, text = text, failed = e.failed == true, lines = lines }
  elseif d.check == "divide" then
    local lines, sum = {}, 0
    for _, id in ipairs(e.agents) do
      local n = e.deliveries[id] or 0
      sum += math.min(1, n / d.deliveries)
      lines[#lines + 1] = { text = ("%s: %d / %d deliveries"):format(id, n, d.deliveries), done = n >= d.deliveries }
    end
    lines[#lines + 1] = { text = ("%d stock or freighter errors"):format(e.errors), done = e.errors == 0 }
    local left = math.max(0, windowTicks(sim, d) - (sim.tick - e.startTick))
    local text = ("%d:%02d left"):format(math.floor(left / 600), math.floor(left / 10) % 60)
    if e.failed then text = "Failed (an error or too few deliveries) - retry" end
    return { fraction = #e.agents > 0 and sum / #e.agents or 0, text = text, failed = e.failed == true, lines = lines }
  elseif d.check == "watch" then
    local n = math.min(e.resolved or 0, d.resolve)
    local spent = monitorSpent(sim, e)
    local text = ("%d / %d alerts resolved  -  Monitor Compute %.1f / %d"):format(n, d.resolve, spent, d.computeMax)
    if e.failed then text = text .. "  -  over budget, retry" end
    return { fraction = n / d.resolve, text = text, failed = e.failed == true, lines = {} }
  else
    local earned = math.max(0, sim.lifetimeRevenue - e.baseRevenue)
    local spent = computeSpent(sim, e)
    local text = ("%d / %d cr revenue  -  Compute %.1f / %d"):format(math.floor(earned), d.revenue, spent, d.computeMax)
    if e.failed then text = text .. "  -  over budget, retry" end
    return { fraction = math.min(1, earned / d.revenue), text = text, failed = e.failed == true, lines = {} }
  end
end

local function check(sim, e, d)
  if d.check == "streak" then return streakBest(e) >= d.trips end
  if d.check == "scout" then
    if sim.upgrades.scanner then e.scanner = true end
    -- A real `scan` call (counted when the scan finishes, also one made before the mission opened) that revealed K4:
    -- a debug veins-reveal is not a scan.
    if e.scanner and (sim.scanCalls or 0) > 0 and sim.veins[d.vein] and sim.veins[d.vein].scanned then e.scanned = true end
    return e.scanner and e.scanned and e.sold
  end
  if d.check == "skillcredit" then
    if next(sim.skills) ~= nil then e.saved = true end
    return e.saved and (e.earned or 0) >= d.credits
  end
  if d.check == "orbis" then return (e.units or 0) >= d.units end
  if d.check == "teamwork" or d.check == "divide" then
    if e.lastTick ~= sim.tick then -- check() also runs after a sale: count each tick once
      e.lastTick = sim.tick
      if d.check == "teamwork" and not e.failed then
        for _, id in ipairs(e.agents) do
          if sim.agents[id] then
            local active, crowded = workerTick(sim, id)
            if active then
              e.mining[id] += 1
              if crowded then e.crowded[id] += 1 end
            end
          end
        end
      end
    end
    if e.failed or sim.tick - e.startTick < windowTicks(sim, d) then return false end
    local ok = false
    if d.check == "teamwork" then -- two or more workers of one branch, all of them on target (spec §15b.0)
      for _, g in ipairs(groupsOf(sim, e.agents)) do
        local met = #g.ids >= 2
        for _, id in ipairs(g.ids) do
          if (e.earned[id] or 0) < d.creditsEach or crowdPct(e, id) >= d.crowdMaxPct then met = false end
        end
        if met then ok = true end
      end
    else
      ok = #e.agents >= 2
      for _, id in ipairs(e.agents) do
        if (e.deliveries[id] or 0) < d.deliveries then ok = false end
      end
      if e.errors > 0 then ok = false end
    end
    if not ok then e.failed = true end
    return ok
  end
  if d.check == "watch" then
    local back = sim:ticks(d.backSeconds)
    local keep = {}
    for _, p in ipairs(e.pending) do
      local agent = sim.agents[p.agent]
      if agent and agent.state == "acting" then
        e.resolved += 1
      elseif sim.tick - p.tick <= back then
        keep[#keep + 1] = p
      end
    end
    e.pending = keep
    if monitorSpent(sim, e) > d.computeMax then e.failed = true end
    return not e.failed and e.resolved >= d.resolve
  end
  if computeSpent(sim, e) > d.computeMax then e.failed = true end
  return not e.failed and sim.lifetimeRevenue - e.baseRevenue >= d.revenue
end

-- Opens the next mission when its turn and start condition come, and completes the active one when its goal is met.
-- Called at the end of every tick and after a sale.
function Missions.update(sim)
  local e, d = Missions.current(sim)
  if not e then return end
  if e.status == "locked" and startMet(sim, d) then
    e.status = "active"
    begin(sim, e, d)
    if sim.tick > 0 then -- the first mission opens silently with the game
      sim:log("INFO", ("mission %d started: %s"):format(d.id, d.name))
      sim:emit("mission_started", { id = d.id })
    end
  end
  if e.status == "active" and check(sim, e, d) then
    e.status = "complete"
    sim:log("INFO", ("mission %d complete: %s"):format(d.id, d.name))
    sim:emit("mission_complete", { id = d.id })
  end
end

-- A miner sold its hold (Sim:sell, before the hold is emptied). `ship.cargoVein` is the vein the hold came from,
-- or "mixed" when two veins fed it.
function Missions.onSale(sim, ship)
  local e, d = Missions.current(sim)
  if not e or e.status ~= "active" then return end
  if d.check == "streak" then
    local vein = ship.cargoVein
    local full = ship.cargoCap > 0 and ship.cargo * 100 >= d.holdPct * ship.cargoCap
    local prev = e.streaks[ship.id]
    if vein and vein ~= "mixed" and full then
      e.streaks[ship.id] = (prev and prev.vein == vein) and { vein = vein, n = prev.n + 1 } or { vein = vein, n = 1 }
    else
      e.streaks[ship.id] = nil
    end
  elseif d.check == "scout" then
    if e.scanner and e.scanned and ship.cargoVein == d.vein then e.sold = true end
  end
  Missions.update(sim)
end

-- Money came in (Sim:credit) from the decision `recordId`: a skill step's sale counts for mission 4 ("skill:<name>" source).
function Missions.onCredit(sim, recordId, gain, agentId)
  local e, d = Missions.current(sim)
  if not e or e.status ~= "active" or gain <= 0 then return end
  if d.check == "teamwork" then
    if e.earned[agentId or ""] and not e.failed then e.earned[agentId] += gain end
    return
  end
  if d.check ~= "skillcredit" then return end
  local rec = DecisionLog.find(sim, recordId)
  if rec and rec.source and rec.source:sub(1, 6) == "skill:" then
    e.earned = (e.earned or 0) + gain
    Missions.update(sim)
  end
end

-- A freighter shipped by `agentId` delivered (Sim:stepFreighters): counts for mission 7.
function Missions.onDelivery(sim, agentId)
  local e, d = Missions.current(sim)
  if not e or e.status ~= "active" or d.check ~= "divide" or e.failed then return end
  if e.deliveries[agentId or ""] and sim.tick - e.startTick < windowTicks(sim, d) then e.deliveries[agentId] += 1 end
end

-- A tool call of `agentId` was refused with `err` (Sim:apply): a stock or freighter conflict fails mission 7 at once.
function Missions.onError(sim, agentId, err)
  local e, d = Missions.current(sim)
  if not e or e.status ~= "active" or d.check ~= "divide" or e.failed or not e.deliveries[agentId] then return end
  for _, code in ipairs(d.errors) do
    if err == code then
      e.errors += 1
      e.failed = true
      sim:log("WARN", ("mission %d: %s got %s, the mission needs a restart"):format(d.id, agentId, err))
      return
    end
  end
end

-- Units sold to Orbis at `unit` credits each (priced before the saturation drop): only units paid at least `minRatio` times
-- the reference planet's HMC depot price for that ore count for mission 5.
function Missions.onOrbisSale(sim, ore, qty, unit)
  local e, d = Missions.current(sim)
  if not e or e.status ~= "active" or d.check ~= "orbis" then return end
  local hmc = World.planets[d.refPlanet].depotRate * World.ores[ore].basePrice
  if unit >= d.minRatio * hmc then
    e.units = (e.units or 0) + qty
    Missions.update(sim)
  end
end

-- The Monitor acted on `agentId`. It counts toward mission 8 when it answered an alert of that agent (one fix per alert)
-- and the agent is acting again within the mission's window.
function Missions.onMonitorFix(sim, agentId)
  local e, d = Missions.current(sim)
  if not e or e.status ~= "active" or d.check ~= "watch" then return end
  for i = #sim.alerts.list, 1, -1 do
    local a = sim.alerts.list[i]
    if a.agent == agentId and a.handled and not a.resolved then
      a.resolved = true
      e.pending[#e.pending + 1] = { agent = agentId, tick = sim.tick }
      return
    end
  end
end

-- The Claim button. Pays the reward once; the next mission opens on the next update. -> ok, err
function Missions.claim(sim, id)
  local d = defOf(id)
  if not d then return false, "unknown_mission" end
  for _, e in ipairs(sim.missions) do
    if e.id == id then
      if e.status == "claimed" then return false, "already_claimed" end
      if e.status ~= "complete" then return false, "not_complete" end
      local r = d.reward
      if r.credits then sim.resources.credits += r.credits end
      if r.compute then sim.compute:grant(r.compute) end
      if r.freighter then
        local st = e.station and sim.stations[e.station] and e.station or sim.home
        for _ = 1, r.freighter do sim:addFreighter(st) end
        e.rewardStation = st
      end
      if r.archiveSlot then sim.upgrades.archiveBonus = (sim.upgrades.archiveBonus or 0) + r.archiveSlot end
      e.status = "claimed"
      sim:log("INFO", ("mission %d claimed: +%d cr%s%s"):format(d.id, r.credits or 0, r.compute and (" +%d Compute"):format(r.compute) or "",
        r.archiveSlot and (" +%d Archive slot"):format(r.archiveSlot) or "",
        r.freighter and (" +%d freighter"):format(r.freighter) or ""))
      sim:emit("mission_claimed", { id = d.id, reward = { credits = r.credits, compute = r.compute, archiveSlot = r.archiveSlot, freighter = r.freighter } })
      Missions.update(sim)
      return true, r
    end
  end
  return false, "unknown_mission"
end

-- Start the active mission over: counters and baselines reset (mission 3 after going over its Compute budget).
function Missions.retry(sim, id)
  for _, e in ipairs(sim.missions) do
    if e.id == id then
      if e.status ~= "active" then return false, "not_active" end
      begin(sim, e, defOf(id))
      sim:log("INFO", ("mission %d restarted"):format(id))
      return true
    end
  end
  return false, "unknown_mission"
end

return Missions
