-- Practice challenges for the prompt library (GR5-107): each one is a reproducible fixture (a fresh Sim, a seed, a game-time
-- window), a metric read from the sim and a numeric target from config/prompt_library.luau. They run on a throwaway Sim and never
-- touch the eight canonical missions of a player's game.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Market = require("@scripts/sim/market")
local Skills = require("@scripts/sim/skills")
local Library = require("@scripts/config/prompt_library")

local Challenges = {}

local function loopSkill(name, vein)
  return { name = name, agent_type = "miner", params = {}, loop = true,
    steps = { { tool = "mine", args = { vein = vein } }, { tool = "return" }, { tool = "sell" } } }
end

local function find(id)
  for _, c in ipairs(Library.challenges) do if c.id == id then return c end end
  error("prompt challenge: unknown id " .. tostring(id))
end

-- Every sale (cargo emptied by a credit gain) of `shipId`, read tick by tick: units, credits and the unit price.
local function runWith(s, seconds, shipId)
  local sales = {}
  local ship = s.ships[shipId or "s1"]
  for _ = 1, s:ticks(seconds) do
    local cargo, credits = ship.cargo, s.resources.credits
    s:step()
    if cargo > 0 and ship.cargo == 0 and s.resources.credits > credits then
      local gain = s.resources.credits - credits
      sales[#sales + 1] = { t = s.tick * s.b.tickSeconds, units = cargo, credits = gain, unit = gain / cargo }
    end
  end
  return sales
end

local function base(c)
  local s = Sim.new({ seed = c.seed })
  Market.quiet(s.market)
  s:setDecider(Ai.decide)
  return s
end

local function minutes(c) return c.windowSeconds / 60 end

-- 1. three K1 sales in a row, each with the hold at 80% or more
local function miningRepeatable(c, directive)
  local s = base(c)
  s:setDirective("miner", directive)
  local before = s.resources.credits
  local run, best, last = 0, 0, nil
  runWith(s, c.windowSeconds)
  for _, rec in ipairs(s.records.miner or {}) do
    local call = rec.tool_call
    if call.tool == "mine" then
      local good = rec.credits_delta > 0 and call.args.vein == (c.vein or "K1") and (call.args.stop_at_hold_pct or 0) >= c.holdPct
      if good and last == call.args.vein then run += 1 elseif good then run = 1 else run = 0 end
      last = good and call.args.vein or nil
      best = math.max(best, run)
    end
  end
  return { value = best, credits_per_min = (s.resources.credits - before) / minutes(c), compute = s.compute.lifetimeTotal }
end

-- 2. scan first, then a K4 sale (T2, scanner bought)
local function scanThenTarget(c, directive)
  local s = base(c)
  s.resources.credits = 5000
  s:enterTier(2)
  assert(s:buyUpgrade("scanner"))
  s:setDirective("miner", directive)
  local before = s.resources.credits
  runWith(s, c.windowSeconds)
  local scanAt, saleAt, sold = nil, nil, 0
  for i, rec in ipairs(s.records.miner or {}) do
    local call = rec.tool_call
    if call.tool == "scan" and rec.validation == "ok" and not scanAt then scanAt = i end
    if call.tool == "mine" and call.args.vein == c.vein and rec.credits_delta > 0 and scanAt and not saleAt then saleAt = i end
    if call.tool == "mine" and call.args.vein == c.vein and rec.credits_delta > 0 then sold += rec.credits_delta end
  end
  local ordered = scanAt ~= nil and saleAt ~= nil
  return { value = ordered and 1 or 0, k4_credits = ordered and sold or 0,
    credits_per_min = (s.resources.credits - before) / minutes(c), compute = s.compute.lifetimeTotal }
end

-- 3. revenue within a Compute budget; K1Loop is saved before the clock starts
local function thinkLess(c, directive)
  local s = base(c)
  assert(Skills.save(s, loopSkill("K1Loop", "K1"), { agent = "miner" }))
  s:setDirective("miner", directive)
  local revenue, compute = s.lifetimeRevenue, s.compute.lifetimeTotal
  runWith(s, c.windowSeconds)
  local earned, spent = s.lifetimeRevenue - revenue, s.compute.lifetimeTotal - compute
  return { value = earned, compute = spent, within_budget = spent <= c.computeMax }
end

-- 4. units sold to Orbis at or above the price floor (warehouse and trading post built)
local function orbisFloor(c, directive)
  local s = base(c)
  s:enterTier(3)
  s.upgrades.warehouse, s.upgrades.tradingPost = true, true
  s:setDirective("miner", directive)
  local sales = runWith(s, c.windowSeconds)
  local units, credits, below = 0, 0, 0
  for _, sale in ipairs(sales) do
    if sale.unit >= c.minUnitPrice then units += sale.units; credits += sale.credits else below += sale.units end
  end
  return { value = units, credits = credits, units_below_floor = below, avg_unit_price = units > 0 and credits / units or 0,
    compute = s.compute.lifetimeTotal }
end

-- 5. the Monitor brings a paused Miner back within backSeconds, three times, on a Compute budget
local function monitorRecoveries(c, directive)
  local s = Sim.new({ seed = c.seed })
  s:enterTier(4)
  s.lifetimeRevenue = s.b.reputationLevels[2]
  s.resources.credits, s.resources.compute = 250000, 200
  Market.quiet(s.market)
  s:setDecider(Ai.decide)
  assert(Skills.save(s, { name = "Titanium loop", agent_type = "miner", loop = true,
    params = { vein = { kind = "vein", filter = { resource = "titanium" } } },
    steps = { { tool = "mine", args = { vein = "$vein" } }, { tool = "return" }, { tool = "sell" } } }))
  assert(s:buyUpgrade("command_center") and s:hireMonitor())
  assert(s:setMonitorSettings({ heartbeat = false }))
  s.agents.monitor.directive = directive
  s:run(100)
  local recovered, times = 0, {}
  for _ = 1, c.recoveries do
    s:run(30)
    s:pauseAgent("miner", "challenge")
    local t0 = s.tick
    for _ = 1, s:ticks(c.backSeconds) do
      s:step()
      if s.agents.miner.state ~= "paused_error" then break end
    end
    local back = (s.tick - t0) * s.b.tickSeconds
    if s.agents.miner.state ~= "paused_error" and back <= c.backSeconds then
      recovered += 1
      times[#times + 1] = back
    end
  end
  local spent = s.compute.lifetime.monitor or 0
  return { value = recovered, compute = spent, within_budget = spent <= c.computeMax, seconds_each = times }
end

local fixtures = {
  mining_repeatable = miningRepeatable,
  scan_then_target = scanThenTarget,
  think_less = thinkLess,
  orbis_floor = orbisFloor,
  monitor_recoveries = monitorRecoveries,
}

-- Runs challenge `id` with `directive` on a fresh fixture. `passed` is the numeric target (and the Compute budget where it has one).
function Challenges.run(id, directive)
  local c = find(id)
  local r = fixtures[c.fixture](c, directive)
  r.id, r.target, r.metric = id, c.target, c.metricName
  r.passed = r.value >= c.target and r.within_budget ~= false
  return r
end

return Challenges
