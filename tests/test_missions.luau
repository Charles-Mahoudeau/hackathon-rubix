-- Run from repo root: luau tests/test_missions.luau
-- GR5-9: mission framework + missions 1-3 (spec §15): detected from sim state, one at a time in order, claimed with a button.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Missions = require("@scripts/sim/missions")
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
  assert(#s.missions == 3 and status(s, 1) == "active" and status(s, 2) == "locked" and status(s, 3) == "locked")
  local ok, err = Missions.claim(s, 1)
  assert(not ok and err == "not_complete", "cannot claim an unfinished mission")
  assert(select(2, Missions.claim(s, 99)) == "unknown_mission")
  local m = MissionsView.model(s)
  assert(m.current.id == 1 and m.current.claim == nil and m.current.percent == 0 and m.total == 3 and #m.rows == 3)
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
  assert(MissionsView.model(s).allDone and #MissionsView.model(s).rows == 3)

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
  assert(all:find("Clear orders", 1, true) and all:find("MISSION 1 / 3", 1, true) and all:find("0 / 3 trips in a row", 1, true))
  assert(not buttons(spec)["missions.claim.1"], "no Claim button before the goal is met")
  s.missions[1].status = "complete"
  local done = Shell.spec(s, "missions", {})
  assert(buttons(done)["missions.claim.1"], "Claim button once complete")
  assert(Model.signature(s, "missions", MissionsView.signature(s)) ~= Model.signature(Sim.new(), "missions", MissionsView.signature(Sim.new())))
end

print("missions OK")
