-- Headless pacing run and balance report (spec §6.7, M8). A scripted player (config/pacing.luau) plays the stub-AI game for
-- a long stretch of game time; the run records when each tier starts and the credits timeline, and `markdown` turns it
-- into the report Game Design tunes balance.luau from. Pure sim: no engine calls, deterministic per seed.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Clock = require("@scripts/sim/clock")
local Upgrades = require("@scripts/sim/upgrades")
local Config = require("@scripts/config/pacing")
local World = require("@scripts/config/world")

local Pacing = {}

-- The vein a Miner should work: best revenue per trip-second (spec §5.1 travel and mining formulas) among the known veins
-- its ship can reach that still hold a full load and are not `taken`. nil when nothing qualifies.
local function bestVein(sim, ship, taken)
  local best, bestScore
  for _, v in ipairs(World.veins) do
    local vein = sim.veins[v.id]
    local ore, planet = World.ores[vein.ore], World.planets[vein.planet]
    if (not vein.hidden or vein.scanned) and not taken[vein.id] and vein.reserve >= ship.cargoCap and sim:inRange(ship, vein.planet) then
      local seconds = 2 * vein.jumps * World.jumpSeconds + ship.cargoCap / (ship.drillRate * vein.richness * ore.hardness)
      local score = ship.cargoCap * ore.basePrice * planet.depotRate / seconds
      if not bestScore or score > bestScore then best, bestScore = vein.id, score end
    end
  end
  return best
end

-- The scripted player, once per game second: a directive for every Miner without one, Compute topped up, then the shop
-- list bought strictly in order (it waits for the first item it cannot afford yet, keeping `reserve` credits back). Returns the ids bought.
local function play(sim, bought)
  local p = Config.player
  local taken = {}
  for _, id in ipairs(sim.agentOrder) do
    local a = sim.agents[id]
    if a.type == "miner" then
      local ship = sim:ownedShip(id)
      local vein = bestVein(sim, ship, taken)
      if vein then
        taken[vein] = true
        local text = p.directive:gsub("{vein}", vein)
        if a.directive ~= text and (a.directive == "" or ship.state == "idle") then sim:setDirective(id, text) end
      end
    end
  end
  if sim.offer then sim:acceptEmergencyAdvance() end
  if sim.resources.compute < p.computeBelow then sim:buyCompute(p.computePacks) end
  for _, id in ipairs(p.buy) do
    if sim.b.shop.items[id] then
      local why = Upgrades.blocker(sim, id)
      if why == nil and sim.resources.credits - sim.b.shop.items[id].cost < p.reserve then why = "reserve" end
      if why == nil then
        if sim:buyUpgrade(id) then bought[#bought + 1] = id end
      elseif why ~= "already_owned" then
        break
      end
    end
  end
end

-- opts: seed, seconds, sampleSeconds, speed (all default to config/pacing.luau). Returns
-- { seed, seconds, speed, tiers = { [t] = { at, credits, revenue } }, samples = { { t, credits, revenue, tier } },
--   purchases = { { t, id } }, decisions, tokens, finalCredits, finalRevenue, finalTier }
function Pacing.run(opts)
  opts = opts or {}
  local seconds = opts.seconds or Config.report.seconds
  local every = opts.sampleSeconds or Config.report.sampleSeconds
  local sim = Sim.new({ seed = opts.seed or Config.report.seeds[1], balance = opts.balance })
  sim:setDecider(Ai.decide)
  assert(Clock.setSpeed(sim, opts.speed or Config.report.speed))
  local tick = sim.b.tickSeconds
  local perSecond, perSample = math.floor(1 / tick + 0.5), math.floor(every / tick + 0.5)
  local data = { seed = sim.seed, seconds = seconds, speed = sim.speed, tiers = { [1] = { at = 0, credits = sim.resources.credits, revenue = 0 } },
    samples = {}, purchases = {} }
  local tier = sim.tier
  for i = 1, math.floor(seconds / tick + 0.5) do
    sim:step()
    if sim.tier ~= tier then
      for t = tier + 1, sim.tier do
        data.tiers[t] = { at = sim.tick * tick, credits = sim.resources.credits, revenue = sim.lifetimeRevenue }
      end
      tier = sim.tier
    end
    if i % perSecond == 0 then
      local bought = {}
      play(sim, bought)
      for _, id in ipairs(bought) do data.purchases[#data.purchases + 1] = { t = sim.tick * tick, id = id } end
    end
    if i % perSample == 0 then
      data.samples[#data.samples + 1] = { t = sim.tick * tick, credits = sim.resources.credits, revenue = sim.lifetimeRevenue, tier = sim.tier }
    end
  end
  if opts.keepSim then data.sim = sim end
  data.decisions, data.tokens = sim.recordSeq, sim.aiQueue:tokensUsed()
  data.finalCredits, data.finalRevenue, data.finalTier = sim.resources.credits, sim.lifetimeRevenue, sim.tier
  return data
end

-- Verdict of one tier: { target, at, deviation (fraction, + = late), status = "ok" | "flag" | "not_reached" | "beyond_run" | "no_target" }.
function Pacing.verdict(tier: number, at: number?, runSeconds: number)
  local target = Config.targets[tier]
  if not target then return { status = "no_target", at = at } end
  if not at then return { target = target, status = target > runSeconds and "beyond_run" or "not_reached" } end
  local dev = (at - target) / target
  return { target = target, at = at, deviation = dev, status = math.abs(dev) <= Config.tolerance and "ok" or "flag" }
end

local function median(list)
  local v = table.clone(list)
  table.sort(v)
  local n = #v
  if n == 0 then return nil end
  return n % 2 == 1 and v[(n + 1) / 2] or (v[n / 2] + v[n / 2 + 1]) / 2
end

local function minutes(s: number?) return s and ("%.1f"):format(s / 60) or "-" end
local function thousands(n: number)
  local s = tostring(math.floor(n + 0.5))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

local STATUS = { ok = "OK", flag = "FLAG", not_reached = "NOT REACHED", beyond_run = "beyond run", no_target = "no target" }

-- `runs` = list of Pacing.run results (first one drives the timeline). Returns the markdown report.
function Pacing.markdown(runs)
  local first = runs[1]
  local out = {}
  local function add(line) out[#out + 1] = line end
  local maxTier = 1
  for _, r in ipairs(runs) do maxTier = math.max(maxTier, r.finalTier) end
  for t in pairs(Config.targets) do maxTier = math.max(maxTier, t) end
  add("# GRIDMIND pacing report")
  add("")
  add(("Scripted player on the stub AI, %s game-min per run, x%d, seeds %s. Targets from spec §6.7, tolerance +/-%d%%; off by more means tune `balance.luau`, not logic.")
    :format(minutes(first.seconds), first.speed, table.concat((function() local l = {} for _, r in ipairs(runs) do l[#l + 1] = tostring(r.seed) end return l end)(), ", "), Config.tolerance * 100))
  add("")
  add("## Tier timings (game minutes, median over seeds)")
  add("")
  add("| Tier | Target | Reached | Deviation | Status |")
  add("|---|---|---|---|---|")
  local flagged, missing = {}, {}
  for t = 2, maxTier do
    local ats = {}
    for _, r in ipairs(runs) do if r.tiers[t] then ats[#ats + 1] = r.tiers[t].at end end
    local reached = #ats == #runs and median(ats) or nil
    local v = Pacing.verdict(t, reached, first.seconds)
    local dev = v.deviation and ("%+.0f%%"):format(v.deviation * 100) or "-"
    local note = (#ats > 0 and #ats < #runs) and (" (%d of %d seeds)"):format(#ats, #runs) or ""
    add(("| T%d | %s | %s | %s | %s%s |"):format(t, v.target and minutes(v.target) or "-", minutes(reached), dev, STATUS[v.status], note))
    if v.status == "flag" then flagged[#flagged + 1] = ("T%d %s"):format(t, dev) end
    if v.status == "not_reached" or v.status == "beyond_run" then missing[#missing + 1] = "T" .. t end
  end
  add("")
  if #flagged == 0 and #missing == 0 then add("**Verdict:** every tier is within tolerance.")
  else
    local parts = {}
    if #flagged > 0 then parts[#parts + 1] = "flagged: " .. table.concat(flagged, ", ") end
    if #missing > 0 then parts[#parts + 1] = "not reached in this run: " .. table.concat(missing, ", ") .. " (a tier starts only through a purchase or threshold the build implements; the player list is in `config/pacing.luau`)" end
    add("**Verdict:** " .. table.concat(parts, "; ") .. ".")
  end
  add("")
  add("## Per seed (game minutes at which each tier starts)")
  add("")
  local head, rule = "| Seed |", "|---|"
  for t = 2, maxTier do head ..= (" T%d |"):format(t); rule ..= "---|" end
  add(head .. " Final credits | Decisions |")
  add(rule .. "---|---|")
  for _, r in ipairs(runs) do
    local row = ("| %d |"):format(r.seed)
    for t = 2, maxTier do row ..= (" %s |"):format(minutes(r.tiers[t] and r.tiers[t].at)) end
    add(row .. (" %s | %d |"):format(thousands(r.finalCredits), r.decisions))
  end
  add("")
  add(("## Credits per tier (seed %d)"):format(first.seed))
  add("")
  add("| Tier | Starts (min) | Credits at start | Revenue at start | Income during tier (cr/min) |")
  add("|---|---|---|---|---|")
  for t = 1, first.finalTier do
    local cur, nxt = first.tiers[t], first.tiers[t + 1]
    if cur then
      local endAt = nxt and nxt.at or first.seconds
      local endRev = nxt and nxt.revenue or first.finalRevenue
      local rate = endAt > cur.at and (endRev - cur.revenue) / ((endAt - cur.at) / 60) or 0
      add(("| T%d | %s | %s | %s | %s |"):format(t, minutes(cur.at), thousands(cur.credits), thousands(cur.revenue), thousands(rate)))
    end
  end
  add("")
  add(("## Credits timeline (seed %d)"):format(first.seed))
  add("")
  add("| Min | Tier | Credits | Lifetime revenue |")
  add("|---|---|---|---|")
  for _, s in ipairs(first.samples) do add(("| %s | T%d | %s | %s |"):format(minutes(s.t), s.tier, thousands(s.credits), thousands(s.revenue))) end
  add("")
  add(("## Purchases (seed %d)"):format(first.seed))
  add("")
  if #first.purchases == 0 then add("none")
  else
    local parts = {}
    for _, p in ipairs(first.purchases) do parts[#parts + 1] = ("%s @ %s min"):format(p.id, minutes(p.t)) end
    add(table.concat(parts, ", "))
  end
  add("")
  add("## AI load")
  add("")
  local realMin = first.seconds / first.speed / 60
  add(("Seed %d: %d decisions in %.1f real min at x%d = %.1f per real minute; AI tokens counted in the last real hour: %s (cap %s per real hour, spec §10.4).")
    :format(first.seed, first.decisions, realMin, first.speed, first.decisions / realMin, thousands(first.tokens),
      thousands(require("@scripts/config/ai").tokensPerHour)))
  add("")
  return table.concat(out, "\n")
end

-- Runs every configured seed and returns the markdown report.
function Pacing.report(opts)
  opts = opts or {}
  local runs = {}
  for _, seed in ipairs(opts.seeds or Config.report.seeds) do
    runs[#runs + 1] = Pacing.run({ seed = seed, seconds = opts.seconds, sampleSeconds = opts.sampleSeconds, speed = opts.speed })
  end
  return Pacing.markdown(runs)
end

return Pacing
