-- Run from repo root: luau tests/test_missions.luau
-- GR5-9: mission framework + missions 1-3 (spec §15): detected from sim state, one at a time in order, claimed with a button.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Missions = require("@scripts/sim/missions")
local Skills = require("@scripts/sim/skills")
local Market = require("@scripts/sim/market")
local Offline = require("@scripts/sim/offline")
local Persistence = require("@scripts/sim/persistence")
local MissionsView = require("@scripts/ui/missions_view")
local Shell = require("@scripts/ui/shell")
local Model = require("@scripts/ui/shell_model")

local PRECISE = "Mine titanium on K1 until the hold is 100%, then sell at HMC."
local VAGUE = "mine stuff"
local FIFTEEN_MIN = 15 * 60 * 10 -- ticks

local function newSim(directive, opts)
  local s = Sim.new(opts)
  s:setDecider(Ai.decide)
  s:setDirective("miner", directive or "")
  return s
end

local function status(s, i) return s.missions[i].status end

local function runUntil(s, cond, maxTicks)
  for _ = 1, maxTicks do
    if cond() then return true end
    s:step()
  end
  return cond()
end

-- Drive the ship by hand (no AI): one call, then wait until the ship is idle again.
local function call(s, name, args)
  local ok, err = s:apply("miner", { name = name, args = args })
  assert(ok, name .. ": " .. tostring(err))
  assert(runUntil(s, function() return s.ships.s1.state == "idle" end, 20000), name .. " never finished")
end

-- 1. framework: mission 1 is active from the first tick, 2 and 3 are locked, nothing is claimable
do
  local s = Sim.new()
  assert(#s.missions == 7 and status(s, 1) == "active" and status(s, 2) == "locked" and status(s, 3) == "locked")
  local ok, err = Missions.claim(s, 1)
  assert(not ok and err == "not_complete", "cannot claim an unfinished mission")
  assert(select(2, Missions.claim(s, 99)) == "unknown_mission")
  local m = MissionsView.model(s)
  assert(m.current.id == 1 and m.current.claim == nil and m.current.percent == 0 and m.total == 7 and #m.rows == 7)
  assert(m.current.hint:find("Say which ore, which vein", 1, true), "hint text from the spec")
  assert(m.current.rewardText == "Reward: 300 cr + 5 Compute")
end

-- 2. mission 1 with a precise directive completes in under 15 game minutes, from the same vein
do
  local s = newSim(PRECISE)
  assert(runUntil(s, function() return status(s, 1) == "complete" end, FIFTEEN_MIN), "precise directive completes mission 1")
  assert(s.tick < FIFTEEN_MIN)
  assert(s.agents.miner.state ~= "paused_error")
  local p = Missions.progress(s, s.missions[1])
  assert(p.fraction == 1 and p.text == "3 / 3 trips in a row")
end

-- 3. mission 1 with a vague directive usually fails (more than half of 20 seeds do not finish it in 15 minutes)
do
  local failed = 0
  for seed = 1, 20 do
    local s = newSim(VAGUE, { seed = seed })
    runUntil(s, function() return status(s, 1) ~= "active" end, FIFTEEN_MIN)
    if status(s, 1) == "active" then failed += 1 end
  end
  assert(failed > 10, ("a vague directive should fail mission 1 in most seeds, failed %d/20"):format(failed))
  -- and the precise one works on every seed
  for seed = 1, 20 do
    local s = newSim(PRECISE, { seed = seed })
    assert(runUntil(s, function() return status(s, 1) == "complete" end, FIFTEEN_MIN), "precise directive, seed " .. seed)
  end
end

-- 4. the streak rules: hold >= 80%, same vein, in a row (a bad sale resets it)
do
  local s = Sim.new()
  local function streak() return Missions.progress(s, s.missions[1]).text end
  local function trip(vein, pct) call(s, "mine", { vein = vein, stop_at_hold_pct = pct }) end
  trip("K1", 100); assert(streak() == "1 / 3 trips in a row", streak())
  trip("K1", 80); assert(streak() == "2 / 3 trips in a row", "exactly 80% counts: " .. streak())
  trip("K1", 79); assert(streak() == "0 / 3 trips in a row", "79% resets: " .. streak())
  trip("K1", 100); trip("K2", 100); assert(streak() == "1 / 3 trips in a row", "another vein restarts the streak: " .. streak())
  trip("K2", 90); trip("K2", 100)
  assert(status(s, 1) == "complete", "three in a row from K2")
  local before = s.resources.credits
  trip("K2", 100) -- selling after completion changes nothing
  assert(status(s, 1) == "complete" and s.resources.credits > before)
end

-- 5. claim pays 300 cr + 5 Compute once; rewards are not revenue; mission 2 stays shut below T2
do
  local s = newSim(PRECISE)
  assert(runUntil(s, function() return status(s, 1) == "complete" end, FIFTEEN_MIN))
  local credits, compute, revenue = s.resources.credits, s.resources.compute, s.lifetimeRevenue
  local m = MissionsView.model(s)
  assert(m.current.claim == "missions.claim.1" and m.current.status == "complete" and m.current.percent == 100)
  local handled, ok = MissionsView.act(s, "missions.claim.1")
  assert(handled and ok, "claim through the panel action")
  assert(s.resources.credits == credits + 300 and math.abs(s.resources.compute - (compute + 5)) < 1e-6, "reward paid")
  assert(s.lifetimeRevenue == revenue, "reward credits are not revenue")
  local ok2, err2 = Missions.claim(s, 1)
  assert(not ok2 and err2 == "already_claimed" and s.resources.credits == credits + 300, "no double pay")
  assert(status(s, 1) == "claimed" and status(s, 2) == "locked", "T1: mission 2 waits for T2")
  local locked = MissionsView.model(s)
  assert(locked.current.id == 2 and locked.current.locked and locked.current.progressText == "Reach tier 2")
  assert(MissionsView.act(s, "shop.buy.drill_mk2") == false)
end

-- 6. mission 2: needs T2 and mission 1 claimed; buy the scanner, scan, sell K4 cargo, in that order
do
  local s = Sim.new()
  s.resources.credits = 5000
  s.missions[1].status = "claimed"
  s:run(2)
  assert(status(s, 2) == "locked", "T1 keeps mission 2 locked")
  s.tier = 2
  for _, a in pairs(s.agents) do a.tier = 2 end
  s:run(2)
  assert(status(s, 2) == "active", "T2 opens mission 2")
  local function steps() local out = {} for _, l in ipairs(Missions.progress(s, s.missions[2]).lines) do out[#out + 1] = l.done and 1 or 0 end return table.concat(out) end
  assert(steps() == "000")
  assert(s:buyUpgrade("scanner")); s:run(1)
  assert(steps() == "100", "scanner bought: " .. steps())
  call(s, "mine", { vein = "K3", stop_at_hold_pct = 100 })
  assert(steps() == "100" and status(s, 2) == "active", "selling cobalt from K3 is not enough")
  call(s, "scan", { planet = "kessa" })
  assert(steps() == "110", "scan done: " .. steps())
  call(s, "mine", { vein = "K3", stop_at_hold_pct = 100 })
  assert(status(s, 2) == "active", "a K3 sale after the scan is still not K4")
  call(s, "mine", { vein = "K4", stop_at_hold_pct = 50 })
  assert(status(s, 2) == "complete" and steps() == "111", "K4 sale completes it")
  local credits = s.resources.credits
  assert(Missions.claim(s, 2) and s.resources.credits == credits + 500)
  assert(status(s, 3) == "active", "mission 3 opens when 2 is claimed")
end

-- 6b. K4 revealed before mission 2 opened (a scan done while mission 1 was unclaimed) still counts as the scan step
do
  local s = Sim.new()
  s.resources.credits = 5000
  s.tier = 2
  for _, a in pairs(s.agents) do a.tier = 2 end
  assert(s:buyUpgrade("scanner"))
  call(s, "scan", { planet = "kessa" })
  s.missions[1].status = "claimed"
  s:run(2)
  assert(status(s, 2) == "active")
  local p = Missions.progress(s, s.missions[2])
  assert(p.lines[1].done and p.lines[2].done and not p.lines[3].done, "scanner and scan already done")
  call(s, "mine", { vein = "K4", stop_at_hold_pct = 100 })
  assert(status(s, 2) == "complete")
end

-- 7. mission 3: 1,000 revenue from its start, at most 15 Compute spent in that time
do
  local function open3()
    local s = Sim.new()
    s.resources.credits = 5000
    s.missions[1].status, s.missions[2].status = "claimed", "claimed"
    s:run(2)
    assert(status(s, 3) == "active")
    return s
  end
  local s = open3()
  -- revenue earned before the mission started does not count
  local m3 = s.missions[3]
  assert(m3.baseRevenue == s.lifetimeRevenue and m3.baseCompute == s.compute.lifetimeTotal)
  s.lifetimeRevenue += 999; s:step()
  assert(status(s, 3) == "active" and Missions.progress(s, m3).text:find("^999 / 1000 cr"))
  s.lifetimeRevenue += 1; s:step()
  assert(status(s, 3) == "complete", "1,000 revenue at 0 Compute")
  local credits = s.resources.credits
  assert(Missions.claim(s, 3) and s.resources.credits == credits + 800)
  assert(not MissionsView.model(s).allDone and MissionsView.model(s).current.id == 4 and #MissionsView.model(s).rows == 7)

  -- exactly 15 Compute is allowed
  s = open3()
  s.compute.lifetimeTotal += 15; s.lifetimeRevenue += 1000; s:step()
  assert(status(s, 3) == "complete", "15 Compute is within the budget")

  -- 15.1 Compute is over: the mission fails, even once the revenue arrives
  s = open3()
  s.compute.lifetimeTotal += 15.1; s:step()
  assert(m3 ~= s.missions[3] and s.missions[3].failed, "over budget")
  s.lifetimeRevenue += 5000; s:step()
  assert(status(s, 3) == "active", "revenue cannot rescue a blown Compute budget")
  local view = MissionsView.model(s)
  assert(view.current.retry == "missions.retry.3" and view.current.progressText:find("over budget", 1, true))
  assert(select(2, MissionsView.act(s, "missions.retry.3")) == true)
  assert(not s.missions[3].failed and s.missions[3].baseRevenue == s.lifetimeRevenue and MissionsView.model(s).current.retry == nil, "retry starts over")
  s.lifetimeRevenue += 1000; s:step()
  assert(status(s, 3) == "complete", "second attempt")
  assert(not Missions.retry(s, 3), "a completed mission cannot be retried")

  -- the real thing: a precise directive earns 1,000 within the Compute budget
  s = newSim(PRECISE)
  s.missions[1].status, s.missions[2].status = "claimed", "claimed"
  s:run(2)
  assert(runUntil(s, function() return status(s, 3) ~= "active" or s.missions[3].failed end, 40000))
  assert(status(s, 3) == "complete", "a precise directive makes 1,000 cr under 15 Compute")
end

-- 8. missions survive a save and restore, midway through a streak
do
  local s = newSim(PRECISE)
  assert(runUntil(s, function() return Missions.progress(s, s.missions[1]).fraction >= 2 / 3 end, FIFTEEN_MIN))
  local storage = Persistence.memoryStorage()
  assert(Persistence.save(s, storage, "save.json", 1700000000))
  local r = assert(Persistence.load(storage, "save.json"))
  r:setDecider(Ai.decide)
  assert(Missions.progress(r, r.missions[1]).text == Missions.progress(s, s.missions[1]).text, "same streak after load")
  s:run(2000); r:run(2000)
  assert(status(r, 1) == status(s, 1) and status(r, 1) == "complete" and r.tick == s.tick)
  assert(Persistence.encode(Persistence.serialize(r, 1)) == Persistence.encode(Persistence.serialize(s, 1)), "restored == original")
end

-- 9. the screen: current mission with a Claim button when done, no colour or text outside the theme
do
  local s = Sim.new()
  local function texts(node, out)
    out = out or {}
    if node.text then out[#out + 1] = node.text.text end
    if node.children then for _, c in ipairs(node.children) do texts(c, out) end end
    return out
  end
  local function buttons(node, out)
    out = out or {}
    if node.button then out[node.button.action] = true end
    if node.children then for _, c in ipairs(node.children) do buttons(c, out) end end
    return out
  end
  local spec, shown = Shell.spec(s, "missions", {})
  assert(shown == "missions")
  local all = table.concat(texts(spec), "\n")
  assert(all:find("Clear orders", 1, true) and all:find("MISSION 1 / 7", 1, true) and all:find("0 / 3 trips in a row", 1, true))
  assert(not buttons(spec)["missions.claim.1"], "no Claim button before the goal is met")
  s.missions[1].status = "complete"
  local done = Shell.spec(s, "missions", {})
  assert(buttons(done)["missions.claim.1"], "Claim button once complete")
  assert(Model.signature(s, "missions", MissionsView.signature(s)) ~= Model.signature(Sim.new(), "missions", MissionsView.signature(Sim.new())))
end

local function skillLoop(name, vein)
  return { name = name, agent_type = "miner", params = {}, loop = true,
    steps = { { tool = "mine", args = { vein = vein } }, { tool = "return" }, { tool = "sell" } } }
end

-- Sim with missions 1-3 claimed and mission 4 open.
local function open4()
  local s = Sim.new()
  Market.quiet(s.market)
  for i = 1, 3 do s.missions[i].status = "claimed" end
  s:run(2)
  assert(status(s, 4) == "active")
  return s
end

-- 10. mission 4: save a skill, then 500 credits from skill steps (also offline); manual and AI sales do not count
do
  local s = open4()
  local p = Missions.progress(s, s.missions[4])
  assert(p.text == "Save a skill first" and not p.lines[1].done)
  call(s, "mine", { vein = "K1", stop_at_hold_pct = 100 }) -- a hand-driven sale earns credits but is not a skill step
  assert(s.missions[4].earned == 0, "manual sales do not count")
  assert(Skills.save(s, skillLoop("loop-k1", "K1"), { agent = "miner" }))
  s:run(1)
  p = Missions.progress(s, s.missions[4])
  assert(p.lines[1].done and not p.lines[2].done and p.text == "0 / 500 cr from skill steps", p.text)
  assert(Skills.assign(s, "miner", "loop-k1", {}))
  assert(runUntil(s, function() return status(s, 4) == "complete" end, 20000), "skill credits complete mission 4")
  assert(s.missions[4].earned >= 500 and s.compute.lifetimeTotal == 0, "earned with no Compute")
  assert(Missions.progress(s, s.missions[4]).fraction == 1)
  local slots = s:archiveCapacity()
  local credits = s.resources.credits
  assert(Missions.claim(s, 4) and s.resources.credits == credits, "reward is an Archive slot, not credits")
  assert(s:archiveCapacity() == slots + 1 and s.upgrades.archive == 0, "+1 Archive slot, purchases untouched")
  assert(MissionsView.model(s).rows[4].reward == "+1 Archive slot")
  assert(status(s, 5) == "locked" and MissionsView.model(s).current.progressText == "Build the warehouse and the trading post")
end

-- 10b. mission 4 offline: the skill earns while away; a save made before the skill existed still loads with missions 4-5
do
  local s = open4()
  assert(Skills.save(s, skillLoop("loop-k1", "K1"), { agent = "miner" }))
  assert(Skills.assign(s, "miner", "loop-k1", {}))
  Offline.run(s, 1800)
  s:run(2)
  assert(status(s, 4) == "complete", "offline skill credits count")
  local old = Persistence.serialize(s, 1)
  old.state.missions = { old.state.missions[1], old.state.missions[2], old.state.missions[3] }
  local r = assert(Persistence.restore(old))
  assert(#r.missions == 7 and r.missions[4].status == "locked" and r.missions[5].status == "locked", "old save gains missions 4-5")
end

-- 11. mission 5: needs warehouse + trading post; only Orbis units paid >= 1.5x the Kessa HMC price count
do
  local s = Sim.new()
  Market.quiet(s.market)
  s.tier = 3
  for _, a in pairs(s.agents) do a.tier = 3 end
  for i = 1, 4 do s.missions[i].status = "claimed" end
  s:run(2)
  assert(status(s, 5) == "locked" and MissionsView.model(s).current.locked)
  s.upgrades.warehouse = true
  s:run(2)
  assert(status(s, 5) == "locked", "the warehouse alone is not enough")
  s.upgrades.tradingPost = true
  s:run(2)
  assert(status(s, 5) == "active")
  local function units() return s.missions[5].units end
  local function trip(buyer, pct)
    call(s, "mine", { vein = "K1", stop_at_hold_pct = pct or 100 })
    call(s, "sell", { buyer = buyer })
  end
  for _ = 1, 6 do trip("hmc") end
  assert(units() == 0 and status(s, 5) == "active", "selling to HMC never counts")
  local res = s.market.markets.orbis.res.titanium
  res.s = 0.7 -- 6 x 0.7 = 4.2 cr/unit < 1.5 x 3.0
  trip("orbis")
  assert(units() == 0, "below 1.5x the HMC price does not count: " .. units())
  res.s = 1
  trip("orbis", 50)
  assert(units() == 50, "50 units at 6 cr: " .. units())
  for _ = 1, 4 do trip("orbis") end
  assert(units() == 450 and status(s, 5) == "active")
  assert(Missions.progress(s, s.missions[5]).text == "450 / 500 units to Orbis at 1.5x the HMC price")
  trip("orbis")
  assert(status(s, 5) == "complete", "500 qualifying units")
  local credits = s.resources.credits
  assert(Missions.claim(s, 5) and s.resources.credits == credits + 2000)
  assert(MissionsView.model(s).current.id == 6 and MissionsView.model(s).current.locked, "mission 6 waits for ship #2")
end

-- 11b. the Orbis hook alone (the Logistician's warehouse sale calls it too): 500 units at the baseline price complete it
do
  local s = Sim.new()
  Market.quiet(s.market)
  s.tier = 3
  s.upgrades.warehouse, s.upgrades.tradingPost = true, true
  for i = 1, 4 do s.missions[i].status = "claimed" end
  s:run(2)
  Missions.onOrbisSale(s, "cobalt", 500, Market.price(s.market, "orbis", "cobalt"))
  assert(status(s, 5) == "complete")
end

print("missions OK")
