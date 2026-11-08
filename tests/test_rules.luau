-- GR5-25 rules: crowding, thrashing guard, bailout, multi-agent conflicts, AI concurrency + token budget.
-- Run from repo root: luau tests/test_rules.luau
local Balance = require("@scripts/config/balance")
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local AiQueue = require("@scripts/sim/ai_queue")
local AiConfig = require("@scripts/config/ai")
local Market = require("@scripts/sim/market")

for _, m in { Balance, Sim, Ai, AiQueue, AiConfig } do table.freeze(m) end

local function near(a, b, eps, msg) assert(math.abs(a - b) <= eps, ("%s: %s vs %s"):format(msg, tostring(a), tostring(b))) end
local function runUntil(sim, pred, maxTicks)
  for _ = 1, maxTicks do if pred() then return true end sim:step() end
  return pred()
end
local function hasLog(sim, level, needle)
  for _, l in ipairs(sim.logs) do if l.level == level and l.msg:find(needle, 1, true) then return true end end
  return false
end

-- spec §5.1 crowding: 1 / (1 + 0.5 (n - 1))
do
  local s = Sim.new()
  near(s:crowdingFor(1), 1, 1e-9, "1 ship"); near(s:crowdingFor(2), 0.667, 0.001, "2 ships"); near(s:crowdingFor(3), 0.5, 1e-9, "3 ships")
end

-- two Miners on one vein each mine at 0.67x, and the cause is visible (crowded_by + log)
do
  local solo = Sim.new()
  assert(solo:apply("miner", { name = "mine", args = { vein = "K1" } }))
  runUntil(solo, function() return solo.ships.s1.state == "mining" end, 1000)
  local before = solo.ships.s1.cargoF
  solo:run(100)
  local soloRate = solo.ships.s1.cargoF - before -- 10 s alone

  local s = Sim.new()
  s:addAgent("miner_2", "miner"); s:addShip("s2", "miner_2")
  assert(s:apply("miner", { name = "mine", args = { vein = "K1" } }))
  assert(s:apply("miner_2", { name = "mine", args = { vein = "K1" } }))
  runUntil(s, function() return s.ships.s1.state == "mining" and s.ships.s2.state == "mining" end, 1000)
  s:step() -- first tick with both mining
  local c1, c2, r0 = s.ships.s1.cargoF, s.ships.s2.cargoF, s.veins.K1.reserve
  s:run(99)
  near((s.ships.s1.cargoF - c1) / soloRate, 0.667, 0.01, "miner 1 rate vs solo")
  near((s.ships.s2.cargoF - c2) / soloRate, 0.667, 0.01, "miner 2 rate vs solo")
  near(((s.ships.s1.cargoF - c1) + (s.ships.s2.cargoF - c2)) / soloRate, 1.333, 0.02, "the vein is drained 1.33x faster")
  assert(r0 - s.veins.K1.reserve > 0, "reserve drops")
  assert(s.ships.s1.crowdedBy[1] == "miner_2" and s.ships.s2.crowdedBy[1] == "miner", "crowded_by")
  assert(s:context("miner_2").ship.crowded_by[1] == "miner", "crowded_by in context")
  assert(hasLog(s, "WARN", "crowded by miner_2"), "crowding logged")

  -- different veins: no penalty
  local t = Sim.new()
  t:addAgent("miner_2", "miner"); t:addShip("s2", "miner_2")
  assert(t:apply("miner", { name = "mine", args = { vein = "K1" } }) and t:apply("miner_2", { name = "mine", args = { vein = "K2" } }))
  t:run(400)
  assert(#t.ships.s1.crowdedBy == 0 and #t.ships.s2.crowdedBy == 0)

  -- three on a vein: 0.5x each
  local u = Sim.new()
  for i = 2, 3 do u:addAgent("miner_" .. i, "miner"); u:addShip("s" .. i, "miner_" .. i) end
  assert(u:apply("miner", { name = "mine", args = { vein = "K1" } }))
  assert(u:apply("miner_2", { name = "mine", args = { vein = "K1" } }))
  assert(u:apply("miner_3", { name = "mine", args = { vein = "K1" } }))
  runUntil(u, function() return u.ships.s3.state == "mining" end, 1000)
  u:step()
  local d0 = u.ships.s3.cargoF
  u:run(100)
  near((u.ships.s3.cargoF - d0) / soloRate, 0.5, 0.01, "3 miners rate")
end

-- thrashing guard (spec §8.3): never more than 5 decisions in any 30 s window, and it keeps deciding
do
  local s = Sim.new()
  s.resources.compute = 100000
  local times = {}
  s:setDecider(function(sim, id) times[#times + 1] = sim.tick; return { name = "report", args = { message = "x" } } end) -- valid but does nothing, ship stays idle
  s:run(6000)
  local win, worst = s:ticks(Balance.ai.thrashWindowSeconds), 0
  for i = 1, #times do
    local n = 0
    for j = i, #times do if times[j] - times[i] < win then n = n + 1 else break end end
    worst = math.max(worst, n)
  end
  assert(worst == Balance.ai.thrashMaxDecisions, "max decisions in a window: " .. worst)
  assert(#times >= 5 * 600 / 30 - 5, "keeps deciding after the window: " .. #times)
  assert(hasLog(s, "WARN", "thrashing guard"), "guard logged")
  local count = 0
  for _, l in ipairs(s.logs) do if l.msg:find("thrashing guard", 1, true) then count = count + 1 end end
  assert(count == 1 and s.agents.miner.throttleCount > 1, "guard logged once, counted every time")
end

-- bailout (spec §8.5)
do
  local s = Sim.new()
  s.resources.compute, s.resources.credits = 1, 199
  s:step()
  assert(s.offer and s.offer.kind == "emergency_advance", "offer when stuck")
  local evs = s:drainEvents(); assert(evs[#evs].name == "emergency_advance_offered")
  assert(s:acceptEmergencyAdvance())
  assert(s.resources.compute == 4 and s.offer == nil, "+3 Compute")
  s.resources.compute = 0
  s:run(s:ticks(Balance.bailout.cooldownSeconds) - 2)
  assert(s.offer == nil and not s:acceptEmergencyAdvance(), "once per 5 game minutes")
  s:run(3)
  assert(s.offer, "offered again after the cooldown")

  local function blocked(mutate)
    local t = Sim.new(); t.resources.compute, t.resources.credits = 1, 100; mutate(t); t:step(); return t.offer == nil
  end
  assert(blocked(function(t) t.resources.compute = 2 end), "compute >= 2")
  assert(blocked(function(t) t.resources.credits = 200 end), "credits >= 200")
  assert(blocked(function(t) t.agents.miner.mode = "skill" end), "a skill is running")
  assert(blocked(function(t) t.ships.s1.cargo = 5 end), "a hold is not empty")

  local w = Sim.new(); w.resources.compute, w.resources.credits = 1, 100; w:step()
  assert(w.offer); w.resources.credits = 500; w:step(); assert(w.offer == nil, "offer withdrawn when no longer stuck")
  assert(not w:acceptEmergencyAdvance())

  -- unstuck loop: out of Compute -> no_compute -> advance -> the miner decides again
  local p = Sim.new(); p:setDecider(Ai.decide)
  p.resources.compute, p.resources.credits = 0, 100
  p:run(5)
  assert(p.agents.miner.state == "no_compute" and p.agents.miner.pending == nil, "no_compute without Compute")
  assert(p:acceptEmergencyAdvance())
  p:run(5)
  assert(p.agents.miner.state == "thinking", "decides again after the advance")
end

-- Logistician conflicts (spec §8.6): stock and freighters are taken at call time
do
  local function station()
    local s = Sim.new()
    s:addAgent("logistician_1", "logistician", { tier = 4 }); s:addAgent("logistician_2", "logistician", { tier = 4 })
    s:enterTier(4)
    s.warehouse.cobalt, s.warehouse.titanium = 500, 500
    Market.quiet(s.market) -- no random price events: the delivery prices are the plain demand x base
    return s
  end
  local s = station()
  s:addFreighter("kessa")
  local ok, r = s:apply("logistician_1", { name = "ship", args = { resource = "cobalt", qty = 300, destination = "halcyon" } })
  assert(ok and r.freighter_id == "F1" and r.eta_s == 240, "first call wins")
  local ok2, e2 = s:apply("logistician_2", { name = "ship", args = { resource = "titanium", qty = 100, destination = "halcyon" } })
  assert(not ok2 and e2 == "no_free_freighter", "one freighter: " .. tostring(e2))
  s:addFreighter("kessa")
  local ok3, e3 = s:apply("logistician_2", { name = "ship", args = { resource = "cobalt", qty = 300, destination = "halcyon" } })
  assert(not ok3 and e3 == "not_enough_stock", "same stock: " .. tostring(e3))
  assert(s:apply("logistician_2", { name = "ship", args = { resource = "titanium", qty = 300, destination = "halcyon" } }), "split by resource: no error")
  assert(s.warehouse.cobalt == 200 and s.warehouse.titanium == 200)
  local ok4, e4 = s:apply("logistician_1", { name = "sell", args = { resource = "cobalt", qty = 300 } })
  assert(not ok4 and e4 == "not_enough_stock", "sell after ship")
  local ok5, e5 = s:apply("logistician_1", { name = "ship", args = { resource = "cobalt", qty = 1, destination = "meridian" } })
  assert(not ok5 and e5 == "not_bought_here", "meridian does not buy cobalt")
  -- delivery: credits arrive, freighters come home
  local c0 = s.resources.credits
  s:run(s:ticks(240) + 1)
  assert(s.resources.credits == c0 + math.floor(300 * 24 * 1.2) + math.floor(300 * 10 * 1.3), "delivery revenue")
  assert(s.freighters[1].state == "back")
  s:run(s:ticks(240) + 1)
  assert(s.freighters[1].state == "idle" and s.freighters[2].state == "idle", "freighters return")
  local ok6, r6 = s:apply("logistician_1", { name = "sell", args = { resource = "cobalt", qty = "all" } })
  assert(ok6 and r6.sold == 200 and s.warehouse.cobalt == 0)
  local ok7, e7 = s:apply("logistician_1", { name = "sell", args = { resource = "cobalt", qty = "all" } })
  assert(not ok7 and e7 == "not_enough_stock")
  assert(not s:apply("logistician_1", { name = "ship", args = { resource = "titanium", qty = 9999, destination = "orbis" } }))
end

-- AI request queue: concurrency cap, Monitor first, then oldest; hourly token budget
do
  local now = 0
  local q = AiQueue.new({ maxConcurrent = 4, tokensPerHour = 1000, windowSeconds = 3600 }, function() return now end)
  local ids = {}
  for i = 1, 6 do local id, st = q:submit({ agentId = "a" .. i }); ids[i] = id; assert(st == (i <= 4 and "running" or "queued")) end
  local mon, mst = q:submit({ agentId = "monitor", monitor = true })
  assert(mst == "queued" and q:queued() == 3 and q:inFlight() == 4)
  local started = q:complete(ids[1], 100)
  assert(#started == 1 and started[1] == mon, "Monitor first")
  started = q:complete(ids[2], 100)
  assert(started[1] == ids[5], "then oldest")
  assert(q:inFlight() == 4 and q:queued() == 1)
  for _, id in ipairs({ ids[3], ids[4] }) do q:complete(id, 300) end
  assert(q:tokensUsed() == 800 and not q:budgetReached())
  q:complete(mon, 200)
  assert(q:budgetReached(), "cap reached")
  local nid, why = q:submit({ agentId = "x" }); assert(nid == nil and why == "budget")
  now = 3600
  assert(not q:budgetReached() and q:tokensUsed() == 0, "budget frees after the real hour")
  assert(q:submit({ agentId = "x" }))
end

-- budget wired into the sim: agents go to no_compute with the budget message, then recover
do
  local cfg = { maxConcurrent = 4, tokensPerHour = 1200, windowSeconds = 120, budgetMessage = "Server AI budget reached" }
  local s = Sim.new({ aiConfig = cfg })
  s.resources.compute = 100
  s:setDecider(function() return { name = "wait", args = { seconds = 10 } } end)
  s:run(400)
  assert(s.agents.miner.state == "no_compute" and s.agents.miner.blockReason == cfg.budgetMessage, "budget reached: " .. s.agents.miner.state)
  assert(hasLog(s, "WARN", cfg.budgetMessage))
  local c = s.resources.compute
  assert(runUntil(s, function() return s.agents.miner.state == "thinking" end, 1500), "recovers once the window passes")
  assert(s.resources.compute < c, "decisions resume")

  -- concurrency: with one slot, the second agent waits its turn
  local t = Sim.new({ aiConfig = { maxConcurrent = 1, tokensPerHour = 1e9, windowSeconds = 3600, budgetMessage = "x" } })
  t:addAgent("miner_2", "miner"); t:addShip("s2", "miner_2")
  t:setDecider(Ai.decide)
  t:step()
  assert(t.agents.miner.pending.started and not t.agents.miner_2.pending.started, "second request queued")
  local d = t.agents.miner_2.pending.delay
  t:step()
  assert(t.agents.miner_2.pending.delay == d, "queued request does not advance")
  t:run(60)
  assert(t.agents.miner_2.pending == nil or t.agents.miner_2.pending.started, "queued request starts when a slot frees")
end

-- determinism with several agents
do
  local function run()
    local s = Sim.new()
    s:addAgent("miner_2", "miner"); s:addShip("s2", "miner_2")
    s:setDecider(Ai.decide); s:run(4000)
    return s.resources.credits, s.resources.compute, #s.logs
  end
  local a1, a2, a3 = run(); local b1, b2, b3 = run()
  assert(a1 == b1 and a2 == b2 and a3 == b3, "same seed, same result")
end

print("OK rules")
