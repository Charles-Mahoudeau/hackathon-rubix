-- Missions (spec §15): the tutorial. One mission is active at a time, in order; the checks read sim state (a sale hook
-- for trips, plain state for the rest), so nothing is triggered by hand. State lives in `sim.missions` (a list, one entry
-- per mission, saved with the game). Rewards are paid on claim and are NOT revenue (they never count toward tiers or mission 3).
-- Pure Luau, headless, no UI calls: the panel (ui/missions_view.luau) reads progress() and calls claim() / retry().
local Config = require("@scripts/config/missions")

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

-- Fresh counters for a mission that just opened (or is retried).
local function begin(sim, e, d)
  if d.check == "streak" then e.streaks = {}
  elseif d.check == "scout" then e.scanner, e.scanned, e.sold = false, false, false
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
  return s == nil or s.tier == nil or sim.tier >= s.tier
end

-- Why the current mission has not started: nil once its `start` holds.
function Missions.lockReason(sim, d)
  local s = d.start
  if s and s.tier and sim.tier < s.tier then return ("Reach tier %d"):format(s.tier) end
  return nil
end

local function streakBest(e)
  local best = 0
  for _, s in pairs(e.streaks or {}) do if s.n > best then best = s.n end end
  return best
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
    -- A revealed K4 means a scan happened (K4 is hidden until Kessa is scanned), also one done before the mission opened.
    if e.scanner and sim.veins[d.vein] and sim.veins[d.vein].scanned then e.scanned = true end
    return e.scanner and e.scanned and e.sold
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
      e.status = "claimed"
      sim:log("INFO", ("mission %d claimed: +%d cr%s"):format(d.id, r.credits or 0, r.compute and (" +%d Compute"):format(r.compute) or ""))
      sim:emit("mission_claimed", { id = d.id, reward = { credits = r.credits, compute = r.compute } })
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
