-- Run from repo root: luau tests/test_prompt_library.luau
-- GR5-107: the prompt library (BAD / OK / GOOD examples for every role and missions 1-8) and its five practice challenges.
-- Data limits, branch and tool gating, what the stub really does with each example, and the challenge fixtures.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Market = require("@scripts/sim/market")
local Skills = require("@scripts/sim/skills")
local Missions = require("@scripts/sim/missions")
local Salvage = require("@scripts/sim/salvage")
local Library = require("@scripts/sim/prompt_library")
local Challenges = require("@scripts/sim/prompt_challenges")
local Data = require("@scripts/config/prompt_library")
local MissionsConfig = require("@scripts/config/missions")

local function status(s, i) return s.missions[i].status end
local function good(list, grade) for _, ex in ipairs(list) do if ex.grade == grade then return ex end end end
local function text(list, grade) return good(list, grade).text end
local function minutes(s, m) s:run(s:ticks(m * 60)) end
local function skillLoop(name, vein)
  return { name = name, agent_type = "miner", params = {}, loop = true,
    steps = { { tool = "mine", args = { vein = vein } }, { tool = "return" }, { tool = "sell" } } }
end
local function decide(s, id) return Ai.decide(s, id, s:context(id)) end

-- 1. the data: three grades per role and mission, the 400-token and 60-character limits, permitted tools only
do
  local s = Sim.new()
  local problems = Library.validate(s)
  assert(#problems == 0, table.concat(problems, "\n"))
  assert(#Data.roles == 6 and #Data.missions == 8 and #Data.challenges == 5)
  for i, m in ipairs(MissionsConfig.missions) do assert(Data.missions[i].id == m.id, "mission order matches config/missions") end
  -- the validator really bites
  local bad = Data.missions[1].examples[1]
  local longText = string.rep("mine ", 401)
  local saved = bad.text
  -- frozen config: validate a sim whose limit is tiny instead of mutating the table
  local limit = s.aiConfig.editor.directiveMaxTokens
  s.aiConfig.editor.directiveMaxTokens = 3
  local reported = #Library.validate(s)
  s.aiConfig.editor.directiveMaxTokens = limit
  assert(reported > 0, "a directive over the limit is reported")
  assert(bad.text == saved and #longText > 400 * s.compute.cfg.charsPerToken)
end

-- 2. branch roles stay hidden until the branch is open; tools are gated by tier
do
  local s = Sim.new()
  assert(#Library.roleExamples(s, "miner") == 3 and Library.roleExamples(s, "miner")[1].blocker == nil)
  for _, kind in ipairs({ "refiner", "scavenger", "privateer" }) do
    assert(#Library.roleExamples(s, kind) == 0, kind .. " examples are hidden before the branch opens")
  end
  assert(Library.roleExamples(s, "logistician")[3].blocker == "tier_locked", "ship is a T4 tool")
  assert(Library.roleExamples(s, "monitor")[3].blocker == "tier_locked")
  assert(#Library.missionExamples(s, 1) == 3 and #Library.missionExamples(s, 2) == 0, "locked missions are not listed")
  local forMiner = Library.forAgent(s, "miner")
  assert(forMiner.missionId == 1 and #forMiner.mission == 3 and #forMiner.role == 3)
  s.resources.credits = 5000
  s.missions[1].status = "claimed"
  s:enterTier(2)
  s:run(2)
  assert(status(s, 2) == "active")
  assert(Library.missionExamples(s, 2)[3].blocker == "needs_scanner", "scan needs the scanner bought")
  assert(s:buyUpgrade("scanner"))
  assert(Library.missionExamples(s, 2)[3].blocker == nil)
  assert(Library.forAgent(s, "nobody").role[1] == nil)

  local r = Sim.new()
  r:enterTier(3)
  r.lifetimeRevenue = 60000
  r.resources.credits = 500000
  assert(r:buyUpgrade("warehouse") and r:buyUpgrade("trading_post"))
  r:enterTier(4)
  assert(r:openBranch("refining"))
  assert(#Library.roleExamples(r, "refiner") == 3 and #Library.roleExamples(r, "scavenger") == 0, "only the opened branch shows")
end

-- 3. Miner role examples through the stub
do
  local s = Sim.new()
  s:setDecider(Ai.decide)
  local ex = Library.roleExamples(s, "miner")
  s.agents.miner.directive = text(ex, "good")
  local c = decide(s, "miner")
  assert(c.name == "mine" and c.args.vein == "K1" and c.args.stop_at_hold_pct == 100 and c.args.to == "local_depot", "GOOD is exact")
  s.agents.miner.directive = text(ex, "ok")
  c = decide(s, "miner")
  assert(c.args.stop_at_hold_pct == 80 and c.args.to == "local_depot" and c.reasoning:find("at random", 1, true), "OK: vein left to chance")
  s.agents.miner.directive = text(ex, "bad")
  c = decide(s, "miner")
  assert(c.reasoning:find("no threshold given", 1, true) and c.reasoning:find("at random", 1, true), "BAD: everything left to chance")
end

-- 4. Logistician role examples (the stub has no stock guard: the GOOD example is "partial")
local function stationOf(seed)
  local s = Sim.new({ seed = seed })
  s:enterTier(3)
  s.lifetimeRevenue = 80000
  s.resources.credits = 500000
  s.resources.compute = 500
  Market.quiet(s.market)
  assert(s:buyUpgrade("warehouse") and s:buyUpgrade("logistics_hub"))
  s.upgrades.archive = 3
  return s
end
do
  local s = stationOf()
  assert(s:hireLogistician("kessa"))
  s:buyFreighter("kessa")
  s:setDecider(Ai.decide)
  local ex = Library.roleExamples(s, "logistician")
  assert(ex[3].support == "partial" and ex[3].unread[1]:find("300", 1, true) and ex[1].blocker == nil)
  s.warehouse.cobalt, s.warehouse.titanium = 100, 500
  s.agents.logistician.directive = text(ex, "good")
  local c = decide(s, "logistician")
  assert(c.name == "ship" and c.args.resource == "cobalt" and c.args.destination == "halcyon", "ships cobalt to Halcyon")
  assert(c.args.qty == 100, "the stub does not hold back below 300: the guard is design intent, not guaranteed")
  s.warehouse.cobalt = 0
  assert(decide(s, "logistician").name == "wait", "nothing to ship: waits")
  s.warehouse.cobalt = 300
  s.agents.logistician.directive = text(ex, "bad")
  c = decide(s, "logistician")
  assert(c.reasoning:find("at random", 1, true) or c.reasoning:find("Fullest", 1, true), c.reasoning)
end

-- 5. Refiner role examples
do
  local s = stationOf(5)
  s.resources.credits = 500000
  s:enterTier(4)
  s.lifetimeRevenue = 80000
  assert(s:buyUpgrade("trading_post"))
  assert(s:openBranch("refining"))
  s:setDecider(Ai.decide)
  for _, o in ipairs({ "titanium", "cobalt", "iridium", "crystal" }) do s.warehouse[o] = 300 end
  local ex = Library.roleExamples(s, "refiner")
  assert(#ex == 3 and ex[1].blocker == nil and ex[3].support == "partial")
  s.agents.refiner.directive = text(ex, "ok")
  local c = decide(s, "refiner")
  assert(c.name == "refine" and c.args.recipe == "plate" and c.args.qty == 10, "OK: plate, 10")
  s.agents.refiner.directive = text(ex, "good")
  c = decide(s, "refiner")
  assert(c.name == "refine" and c.args.recipe == "plate" and c.args.qty == 10, "GOOD: plate, 10")
  s.warehouse.titanium = 6
  c = decide(s, "refiner")
  assert(c.name == "refine" and c.args.recipe == "plate" and c.args.qty < 10, "the stub shrinks the batch to the stock, it does not read the 30 guard")
  s.warehouse.titanium = 300
  s.agents.refiner.directive = text(ex, "bad")
  c = decide(s, "refiner")
  assert(c.name == "refine" or c.name == "wait", "BAD still makes a valid call")
end

-- 6. Salvager role examples: survey, depth, danger and the single hull threshold
do
  local s = Sim.new({ seed = 14 })
  s:enterTier(2)
  s.resources.credits, s.resources.compute = 100000, 500
  assert(s:buyUpgrade("engine_mk2") and s:openBranch("salvage"))
  s:setDecider(Ai.decide)
  local ex = Library.roleExamples(s, "scavenger")
  assert(#ex == 3 and ex[3].blocker == nil)
  local site = Salvage.spawnSite(s, { planet = "tessar", type = "wreck", danger = 3, qualities = { "fair", "fair", "fair" } })
  site.survey = { type = "wreck", danger = 3, bands = { "fair", "fair", "fair" } }
  s.agents.scavenger.directive = text(ex, "good")
  local c = decide(s, "scavenger")
  assert(c.name ~= "salvage", "GOOD skips a danger-3 site: " .. c.name)
  s.agents.scavenger.directive = text(ex, "ok")
  c = decide(s, "scavenger")
  assert(c.name == "salvage" and c.args.layer == 1, "OK has no danger limit: " .. c.name)
  s.agents.scavenger.directive = text(ex, "bad")
  c = decide(s, "scavenger")
  assert(c.name == "salvage", "BAD strips without a survey")
  s.agents.scavenger.directive = text(ex, "good")
  s.salvageShips.w1.hull, s.salvageShips.w1.at = 55, "tessar"
  site.survey.danger = 0
  c = decide(s, "scavenger")
  assert(c.name == "return", "GOOD: under 60 hull it goes home to repair, got " .. c.name)
end

-- 7. Raider role examples: the BAD one climbs to Notoriety 3, the others stay under it
do
  local function play(seed, directive)
    local s = Sim.new({ seed = seed })
    s:enterTier(4)
    s.lifetimeRevenue = 30000
    s.resources.credits, s.resources.compute = 100000, 500
    assert(s:openBranch("raiding"))
    s:setDecider(Ai.decide)
    local ex = Library.roleExamples(s, "privateer")
    assert(#ex == 3 and ex[3].blocker == nil)
    s:setDirective("privateer", text(ex, directive))
    local peak = 0
    for _ = 1, 30 * 600 do
      s:step()
      if s.raid.notoriety > peak then peak = s.raid.notoriety end
    end
    assert(s.agents.privateer.state ~= "paused_error", "the stub never sends an invalid call")
    return peak
  end
  for seed = 1, 3 do
    assert(play(seed, "bad") >= 3, "BAD attacks everything: seed " .. seed)
    assert(play(seed, "good") < 3, "GOOD stays under Notoriety 3: seed " .. seed)
  end
end

-- 8. Monitor role examples: GOOD resumes a pause and rotates a dried-up vein
local function withMonitor(directive)
  local s = Sim.new()
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
  s.agents.monitor_1.directive = directive
  return s
end
do
  local s = withMonitor("")
  local ex = Library.roleExamples(s, "monitor")
  assert(#ex == 3 and ex[3].blocker == nil)
  s.agents.monitor_1.directive = text(ex, "good")
  assert(s:apply("miner", { name = "run_skill", args = { name = "Titanium loop", params = { vein = "K1" } } }))
  s:run(200)
  local t0, rotated
  for _ = 1, 6000 do
    if not t0 then s.veins.K1.reserve = 0 end
    s:step()
    if not t0 and #s.alerts.list > 0 then t0 = s.alerts.list[1].tick end
    local m = s.agents.miner
    if t0 and m.skillParams and m.skillParams.vein ~= "K1" and m.state == "acting" then rotated = true break end
  end
  assert(t0 and rotated, "GOOD rotates an aborted skill to another vein")
end

-- 9. mission 1: GOOD completes, BAD fails in most seeds
do
  local function run(directive, seed)
    local s = Sim.new({ seed = seed })
    s:setDecider(Ai.decide)
    s:setDirective("miner", directive)
    minutes(s, 15)
    return s
  end
  local ex = Library.missionExamples(Sim.new(), 1)
  for seed = 1, 5 do assert(status(run(text(ex, "good"), seed), 1) == "complete", "GOOD, seed " .. seed) end
  local failed = 0
  for seed = 1, 20 do if status(run(text(ex, "bad"), seed), 1) == "active" then failed += 1 end end
  assert(failed > 10, "BAD fails mission 1 in most seeds: " .. failed .. "/20")
end

-- 10. mission 2
do
  local function open2(seed)
    local s = Sim.new({ seed = seed })
    s.resources.credits = 5000
    s.missions[1].status = "claimed"
    s:enterTier(2)
    assert(s:buyUpgrade("scanner"))
    Market.quiet(s.market)
    s:setDecider(Ai.decide)
    s:run(2)
    assert(status(s, 2) == "active")
    return s
  end
  local ex = Library.missionExamples(open2(1), 2)
  local s = open2(1)
  s:setDirective("miner", text(ex, "good"))
  minutes(s, 15)
  assert(status(s, 2) == "complete", "GOOD scans, then sells K4")
  for seed = 1, 3 do
    local b = open2(seed)
    b:setDirective("miner", text(ex, "bad"))
    minutes(b, 15)
    assert(status(b, 2) == "active", "BAD never calls scan, so it cannot finish")
  end
end

-- 11. missions 3 and 4: a saved skill is the point; a precise AI run does not count as skill credit
do
  local function open(n)
    local s = Sim.new()
    Market.quiet(s.market)
    s:setDecider(Ai.decide)
    for i = 1, n - 1 do s.missions[i].status = "claimed" end
    assert(Skills.save(s, skillLoop("K1Loop", "K1"), { agent = "miner" }))
    s:run(2)
    assert(status(s, n) == "active", "mission " .. n)
    return s
  end
  local ex3 = Library.missionExamples(open(3), 3)
  local s = open(3)
  s:setDirective("miner", text(ex3, "good"))
  minutes(s, 20)
  assert(status(s, 3) == "complete" and s.compute.lifetimeTotal < 3, "GOOD earns 1,000 cr for almost no Compute")
  s = open(3)
  s:setDirective("miner", text(ex3, "bad"))
  minutes(s, 60)
  assert(status(s, 3) == "active" and s.lifetimeRevenue < 1000 and s.resources.compute < 1, "BAD: the Compute pool runs dry before 1,000 cr")
  s = open(3)
  s:setDirective("miner", text(ex3, "ok"))
  minutes(s, 20)
  assert(status(s, 3) == "complete", "OK stays inside the budget")

  local ex4 = Library.missionExamples(open(4), 4)
  s = open(4)
  s:setDirective("miner", text(ex4, "good"))
  minutes(s, 20)
  assert(status(s, 4) == "complete", "GOOD: skill steps earn the 500 cr")
  for _, grade in ipairs({ "bad", "ok" }) do
    s = open(4)
    s:setDirective("miner", text(ex4, grade))
    minutes(s, 20)
    assert(s.missions[4].earned == 0 and status(s, 4) == "active", grade .. ": AI sales are not skill credit")
  end
end

-- 12. mission 5: only Orbis sales at 1.5x count; the floor makes the agent wait instead of selling cheap
do
  local function open5()
    local s = Sim.new()
    Market.quiet(s.market)
    s.tier = 3
    for _, a in pairs(s.agents) do a.tier = 3 end
    s.upgrades.warehouse, s.upgrades.tradingPost = true, true
    for i = 1, 4 do s.missions[i].status = "claimed" end
    s:setDecider(Ai.decide)
    s:run(2)
    assert(status(s, 5) == "active")
    return s
  end
  local ex = Library.missionExamples(open5(), 5)
  for _, grade in ipairs({ "ok", "good" }) do
    local s = open5()
    s:setDirective("miner", text(ex, grade))
    minutes(s, 20)
    assert(status(s, 5) == "complete", grade .. " completes in a steady market")
  end
  local s = open5()
  s:setDirective("miner", text(ex, "bad"))
  minutes(s, 20)
  assert(s.missions[5].units == 0 and s.resources.credits > 500, "BAD: sells, but HMC sales do not count")
  -- Orbis saturates (price x0.5, about 3 cr/unit): OK still sells under the ratio, GOOD holds the cargo
  local function dip(grade)
    local d = open5()
    d.market.markets.orbis.res.titanium.s = 0.5
    d:setDirective("miner", text(ex, grade))
    minutes(d, 10)
    return d
  end
  local ok, hold = dip("ok"), dip("good")
  assert(ok.resources.credits > 500 + 300 and ok.missions[5].units == 0, "OK sold cheap: nothing counts")
  assert(hold.resources.credits == 500 and hold.ships.s1.cargo > 0 and hold.missions[5].units == 0, "GOOD waits below the floor")
end

-- 13. mission 6: the same vein for two Miners crowds, two veins do not
do
  local function open6(d1, d2)
    local s = stationOf()
    s.resources.compute = 500
    for i = 1, 5 do s.missions[i].status = "claimed" end
    Missions.update(s)
    assert(s:buyUpgrade("ship2"))
    s:setDecider(Ai.decide)
    s:run(1)
    assert(status(s, 6) == "active")
    s:setDirective("miner", d1)
    s:setDirective("miner2", d2)
    minutes(s, 12)
    return s
  end
  local ex = Data.missions[6].examples
  local g = good(ex, "good")
  local s = open6(g.text, g.text2)
  assert(status(s, 6) == "complete", "GOOD: one vein each: " .. Missions.progress(s, s.missions[6]).text)
  local b = good(ex, "bad")
  s = open6(b.text, b.text2 or b.text)
  assert(status(s, 6) ~= "complete" and Missions.progress(s, s.missions[6]).failed, "BAD: both on K1 crowd")
end

-- 14. mission 7: GOOD gives each Logistician its own resource; BAD collides in some seed
do
  local function open7(seed, d1, d2)
    local s = stationOf(seed)
    for i = 1, 6 do s.missions[i].status = "claimed" end
    assert(s:hireLogistician("kessa") and s:hireLogistician("kessa"))
    s:buyFreighter("kessa"); s:buyFreighter("kessa")
    s:setDecider(Ai.decide)
    s:run(2)
    assert(status(s, 7) == "active")
    s:setDirective("logistician", d1)
    s:setDirective("logistician_2", d2)
    for _ = 1, 16 do
      s.warehouse.cobalt, s.warehouse.titanium = 500, 500
      minutes(s, 1)
    end
    return s
  end
  local ex = Data.missions[7].examples
  local g = good(ex, "good")
  local s = open7(1, g.text, g.text2)
  assert(status(s, 7) == "complete", "GOOD: " .. Missions.progress(s, s.missions[7]).text)
  local b = good(ex, "bad")
  local hit = 0
  for seed = 1, 5 do
    if Missions.progress(open7(seed, b.text, b.text), open7(seed, b.text, b.text).missions[7]).failed then hit += 1 end
  end
  assert(hit > 0, "BAD collides on stock or freighters in at least one seed")
end

-- 15. mission 8: the GOOD Monitor directive resolves three alerts within 10 Compute
do
  local ex = Data.missions[8].examples
  local s = withMonitor(text(ex, "good"))
  for i = 1, 7 do s.missions[i].status = "claimed" end
  s:run(100)
  local e = s.missions[8]
  assert(e.status == "active")
  for round = 1, 3 do
    s:run(30)
    s:pauseAgent("miner", "test")
    for _ = 1, 1500 do
      s:step()
      if e.resolved >= round or e.status == "complete" then break end
    end
  end
  s:step()
  assert(e.status == "complete", "mission 8: " .. e.status)
end

-- 16. challenges: BAD misses the target, GOOD reaches it; every fixture is reproducible
do
  local K1 = Data.missions[1].examples
  local cases = {
    [1] = { bad = K1[1].text, good = K1[3].text },
    [2] = { bad = Data.missions[2].examples[1].text, good = Data.missions[2].examples[3].text },
    [3] = { bad = Data.missions[1].examples[3].text, good = Data.missions[3].examples[3].text },
    [4] = { bad = Data.missions[5].examples[1].text, good = Data.missions[5].examples[3].text },
    [5] = { bad = Data.missions[8].examples[1].text, good = Data.missions[8].examples[3].text },
  }
  for id, case in ipairs(cases) do
    local b, g = Challenges.run(id, case.bad), Challenges.run(id, case.good)
    assert(not b.passed, "challenge " .. id .. " BAD should miss: " .. tostring(b.value))
    assert(g.passed, "challenge " .. id .. " GOOD should pass: " .. tostring(g.value))
    local again = Challenges.run(id, case.good)
    assert(again.value == g.value and again.compute == g.compute, "challenge " .. id .. " is deterministic")
  end
  -- challenge 3 is stricter than mission 3: a precise AI run earns the revenue but spends too much Compute
  local ai = Challenges.run(3, Data.missions[1].examples[3].text)
  assert(ai.value >= 1000 and not ai.within_budget and not ai.passed)
  -- challenge 4's floor: HMC sales at 3 cr/unit never reach 4.5
  local hmc = Challenges.run(4, cases[4].bad)
  assert(hmc.value == 0 and hmc.units_below_floor > 0)
end

print("prompt library OK")
