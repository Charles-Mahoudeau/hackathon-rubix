-- Run from repo root: luau tests/test_skills.luau
-- GR5-10: warehouse and trading post, store/sell tools, saved skills, parameterized skills, skill abort.
local Sim = require("@scripts/sim/sim")
local Skills = require("@scripts/sim/skills")
local Market = require("@scripts/sim/market")
local Ai = require("@scripts/sim/ai")

local function rich(tier)
  local s = Sim.new()
  s.tier = tier or 2
  for _, a in pairs(s.agents) do a.tier = s.tier end
  s.resources.credits = 100000
  Market.quiet(s.market)
  return s
end
local function loop(name, vein, extra)
  local steps = { { tool = "mine", args = { vein = vein } }, { tool = "return" }, { tool = "sell" } }
  return { name = name, agent_type = "miner", params = {}, steps = extra or steps, loop = true }
end

-- 1. warehouse and trading post purchases follow the §6.5 requirements
do
  local s = Sim.new()
  s.resources.credits = 100000
  local ok, why = s:buyUpgrade("warehouse")
  assert(not ok and why == "tier_locked", "warehouse needs T2: " .. tostring(why))
  s = rich(2)
  s.resources.credits = 9999
  ok, why = s:buyUpgrade("warehouse")
  assert(not ok and why == "not_enough_credits")
  ok, why = s:buyUpgrade("trading_post")
  assert(not ok and why == "needs_warehouse", "trading post needs the warehouse: " .. tostring(why))
  assert(not s:marketUnlocked("orbis") and not s:hasWarehouse())
  s.resources.credits = 10000
  local slots = s:skillSlots("miner")
  assert(s:buyUpgrade("warehouse") and s.resources.credits == 0, "warehouse costs 10,000")
  assert(s.tier == 3 and s.agents.miner.tier == 3 and s:hasWarehouse(), "the warehouse enters T3")
  assert(s:skillSlots("miner") == slots + 2, "+2 skill slots")
  assert(select(2, s:buyUpgrade("warehouse")) == "already_owned")
  s.resources.credits = 3999
  assert(select(2, s:buyUpgrade("trading_post")) == "not_enough_credits")
  s.resources.credits = 4000
  assert(s:buyUpgrade("trading_post") and s:marketUnlocked("orbis") and s.resources.credits == 0, "trading post costs 4,000")
end

-- 2. at the warehouse dock the hold is kept; store moves it, sell goes to hmc or orbis
do
  local s = rich(3)
  s.upgrades.warehouse = true
  assert(select(2, s:apply("miner", { name = "sell", args = { buyer = "orbis" } })) == "buyer_locked")
  assert(s:apply("miner", { name = "mine", args = { vein = "K1" } }))
  repeat s:step() until s.ships.s1.state == "idle"
  local ship = s.ships.s1
  assert(ship.cargo == 100 and ship.ore == "titanium", "the warehouse dock keeps the hold")
  local c0 = s.resources.credits
  assert(select(2, s:apply("miner", { name = "store", args = { resource = "cobalt" } })) == "not_enough_stock")
  assert(s:apply("miner", { name = "store", args = { resource = "titanium", qty = 40 } }))
  assert(s.warehouse.titanium == 40 and ship.cargo == 60 and s.resources.credits == c0, "partial store")
  assert(s:apply("miner", { name = "store", args = { resource = "titanium" } }))
  assert(s.warehouse.titanium == 100 and ship.cargo == 0 and ship.ore == nil)
  assert(select(2, s:apply("miner", { name = "store", args = { resource = "titanium" } })) == "not_enough_stock")
  s.warehouse.titanium = s.b.warehouse.capacity
  ship.cargo, ship.cargoF, ship.ore = 10, 10, "titanium"
  assert(select(2, s:apply("miner", { name = "store", args = { resource = "titanium" } })) == "warehouse_full")
  s.warehouse.titanium = 0
  -- sell at hmc, part of the hold
  assert(s:apply("miner", { name = "sell", args = { qty = 4 } }))
  assert(s.resources.credits == c0 + math.floor(4 * 0.3 * 10) and ship.cargo == 6)
  s.upgrades.tradingPost = true
  local unit = Market.price(s.market, "orbis", "titanium")
  local c1 = s.resources.credits
  assert(s:apply("miner", { name = "sell", args = { buyer = "orbis" } }))
  assert(s.resources.credits == c1 + math.floor(6 * unit) and ship.cargo == 0, "orbis price")
  assert(Market.saturation(s.market, "orbis", "titanium") < 1, "selling saturates")
  -- no warehouse: store is refused
  local plain = rich(3)
  assert(select(2, plain:apply("miner", { name = "store", args = { resource = "titanium" } })) == "no_warehouse")
end

-- 3. a saved skill runs with zero Compute, loops, and earns credits
do
  local s = rich(1)
  local ok, err = Skills.save(s, loop("loop-k1", "K1"), { agent = "miner" })
  assert(ok, tostring(err))
  assert(select(2, Skills.save(s, loop("loop-k1", "K1"))) == "name_taken")
  assert(Skills.assign(s, "miner", "loop-k1", {}))
  local compute, c0 = s.resources.compute, s.resources.credits
  s:run(s:ticks(600))
  assert(s.resources.compute == compute, "skill steps cost 0 Compute")
  assert(s.resources.credits >= c0 + 600, "the skill earned: " .. (s.resources.credits - c0))
  assert(s.agents.miner.mode == "skill" and s.agents.miner.skillRun.loops >= 2, "the skill loops")
  local free = 0
  for _, r in ipairs(s.records.miner) do if r.source == "skill:loop-k1" then free += 1; assert(r.compute_spent == 0) end end
  assert(free > 0, "skill steps are in the decision log")
  -- name and size limits
  assert(select(2, Skills.validate(s, loop(("x"):rep(25), "K1"))) == "bad_name")
  assert(select(2, Skills.validate(s, loop("", "K1"))) == "bad_name")
  assert(select(2, Skills.validate(s, loop("a", "K1", { { tool = "store", args = {} } }), "miner")):find("not equipped"), "store needs T3")
  assert(select(2, Skills.validate(s, loop("a", "K1", { { tool = "run_skill", args = {} } }))):find("bad tool"))
end

-- 4. skill slots cap the Archive
do
  local s = rich(1)
  assert(Skills.save(s, loop("one", "K1")))
  assert(select(2, Skills.save(s, loop("two", "K2"), { force = true })) == "archive_full", "1 slot at T1")
  s.upgrades.archive = 1
  assert(Skills.save(s, loop("two", "K3"), { force = true }))
end

-- 5. parameterized skill for two agents with different $vein
do
  local s = rich(1)
  s.upgrades.archive = 3
  local skill = { name = "ore-run", agent_type = "miner", loop = true,
    params = { vein = { kind = "vein" } },
    steps = { { tool = "mine", args = { vein = "$vein" } }, { tool = "return" }, { tool = "sell" } } }
  assert(Skills.save(s, skill))
  s:addAgent("miner_b", "miner")
  s:addShip("s2", "miner_b")
  assert(select(2, Skills.assign(s, "miner", "ore-run", {})) == "bad_params", "missing parameter")
  assert(select(2, Skills.assign(s, "miner", "ore-run", { vein = "ZZ" })) == "bad_params")
  assert(select(2, Skills.assign(s, "miner", "ore-run", { vein = "K1", extra = 1 })) == "bad_params")
  assert(Skills.assign(s, "miner", "ore-run", { vein = "K1" }))
  assert(Skills.assign(s, "miner_b", "ore-run", { vein = "K3" }))
  local seen = {}
  local compute = s.resources.compute
  for _ = 1, s:ticks(400) do
    s:step()
    for _, id in ipairs({ "s1", "s2" }) do
      local v = s.ships[id].vein
      if v then seen[id] = seen[id] or {}; seen[id][v.id] = true end
    end
  end
  assert(seen.s1.K1 and not seen.s1.K3 and seen.s2.K3 and not seen.s2.K1, "each agent used its own vein")
  assert(s.resources.compute == compute)
  local usage = Skills.usage(s)["ore-run"]
  assert(#usage == 2 and usage[1].params.vein == "K1" and usage[2].params.vein == "K3", "usage lists agents and values")
  -- a filter on the parameter
  local f = { name = "cobalt-only", agent_type = "miner", loop = true, params = { vein = { kind = "vein", filter = { resource = "cobalt" } } },
    steps = { { tool = "mine", args = { vein = "$vein" } }, { tool = "return" } } }
  s.upgrades.archive = 3
  assert(Skills.save(s, f))
  assert(select(2, Skills.checkParams(s, s.skills["cobalt-only"], { vein = "K1" })) == "bad_params")
  assert(Skills.checkParams(s, s.skills["cobalt-only"], { vein = "K3" }))
  -- the AI tool starts a skill with params too
  Skills.stop(s, "miner")
  s.agents.miner.state = "idle"
  assert(s:apply("miner", { name = "run_skill", args = { name = "ore-run", params = { vein = "K2" } } }))
  assert(s.agents.miner.mode == "skill" and s.agents.miner.skillParams.vein == "K2")
  assert(select(2, s:apply("miner", { name = "run_skill", args = { name = "nope" } })) == "unknown_skill")
end

-- 6. make-a-parameter and the near-duplicate suggestion
do
  local s = rich(1)
  s.upgrades.archive = 3
  assert(Skills.save(s, loop("run-k1", "K1")))
  local ok, err, sug = Skills.save(s, loop("run-k2", "K2"))
  assert(not ok and err == "similar_skill" and sug.skill == "run-k1" and sug.param == "vein" and sug.from == "K1" and sug.to == "K2", "suggestion")
  assert(sug.text:find("parameter"))
  assert(Skills.assign(s, "miner", "run-k1", {}))
  assert(Skills.acceptSuggestion(s, sug))
  local conv = s.skills["run-k1"]
  assert(conv.params.vein.kind == "vein" and conv.steps[1].args.vein == "$vein")
  assert(s.agents.miner.skillParams.vein == "K1", "running agents keep their value")
  assert(Skills.save(s, loop("run-k2", "K2"), { force = true }), "forcing saves it anyway")
  local made = Skills.makeParam(loop("x", "K1"), "vein")
  assert(made.params.vein and made.steps[1].args.vein == "$vein")
end

-- 7. guard: a sell step below min_unit_price is skipped, not a failure
do
  local s = rich(3)
  s.upgrades.warehouse, s.upgrades.tradingPost = true, true
  local steps = { { tool = "mine", args = { vein = "K1" } }, { tool = "return" },
    { tool = "sell", args = { buyer = "orbis" }, guard = { min_unit_price = 50 } },
    { tool = "store", args = { resource = "titanium" } } }
  s.upgrades.archive = 3
  assert(Skills.save(s, loop("guarded", "K1", steps)))
  assert(select(2, Skills.validate(s, loop("g2", "K1", { { tool = "mine", args = { vein = "K1" }, guard = { min_unit_price = 5 } } }))):find("bad guard"))
  Skills.assign(s, "miner", "guarded", {})
  local c0 = s.resources.credits
  s:run(s:ticks(200))
  assert(s.agents.miner.skillRun.aborted == nil and s.agents.miner.mode == "skill", "skipped, not aborted")
  assert(s.resources.credits == c0 and s.warehouse.titanium >= 100, "nothing sold, the hold went to the warehouse")
end

-- 8. abort: a failing step stops the skill; with a directive and Compute the AI wakes with the reason
do
  local s = rich(1)
  s.upgrades.archive = 3
  local bad = loop("bad", "K1", { { tool = "mine", args = { vein = "K4" } }, { tool = "return" } })
  assert(Skills.save(s, bad))
  Skills.assign(s, "miner", "bad", {})
  s:run(3)
  local run = s.agents.miner.skillRun
  assert(s.agents.miner.mode == "skill" and run.aborted == "unknown vein", "no directive: idle, aborted: " .. tostring(run and run.aborted))
  assert(s.agents.miner.state == "idle")
  s:run(50)
  assert(s.agents.miner.skillRun.aborted, "stays aborted")
  local woke = rich(1)
  woke.upgrades.archive = 3
  Skills.save(woke, bad)
  woke.agents.miner.directive = "mine titanium"
  Skills.assign(woke, "miner", "bad", {})
  woke:run(3)
  local a = woke.agents.miner
  assert(a.mode == "ai" and a.activeSkill == nil and a.inbox[#a.inbox]:find("unknown vein"), "AI woken with the reason")
  local flagOff = rich(1)
  flagOff.upgrades.archive = 3
  Skills.save(flagOff, bad)
  flagOff.agents.miner.directive, flagOff.agents.miner.wakeAiOnSkillAbort = "mine titanium", false
  Skills.assign(flagOff, "miner", "bad", {})
  flagOff:run(3)
  assert(flagOff.agents.miner.mode == "skill", "flag off: stays idle")
  local noCompute = rich(1)
  noCompute.upgrades.archive = 3
  Skills.save(noCompute, bad)
  noCompute.agents.miner.directive, noCompute.resources.compute = "mine titanium", 0
  Skills.assign(noCompute, "miner", "bad", {})
  noCompute:run(3)
  assert(noCompute.agents.miner.mode == "skill", "no Compute: stays idle")
end

-- 9. recording from the feed: 2-8 contiguous successful calls
do
  local s = rich(1)
  s:setDecider(Ai.decide)
  s.agents.miner.directive = "mine titanium K1"
  for _ = 1, s:ticks(400) do s:step() end
  local calls = {}
  for _, e in ipairs(s.feed) do if e.agent == "miner" and e.kind == "call" and e.status == "ok" then calls[#calls + 1] = e end end
  assert(#calls >= 2, "AI calls in the feed")
  local rec, err = Skills.record(s, "miner", calls[1].id, calls[2].id, "recorded")
  assert(rec or err == "not_successful" or err == "bad_range", tostring(err))
  -- build one directly from two known successful calls
  local fresh = rich(1)
  assert(fresh:apply("miner", { name = "mine", args = { vein = "K1" } }))
  repeat fresh:step() until fresh.ships.s1.state == "idle"
  assert(fresh:apply("miner", { name = "mine", args = { vein = "K1" } }))
  local ids = {}
  for _, e in ipairs(fresh.feed) do if e.kind == "call" then ids[#ids + 1] = e.id end end
  assert(#ids == 2)
  local one, e1 = Skills.record(fresh, "miner", ids[1], ids[1], "x")
  assert(not one and e1 == "bad_length", "needs at least 2 calls")
  repeat fresh:step() until fresh.ships.s1.state == "idle"
  local rec2 = assert(Skills.record(fresh, "miner", ids[1], ids[2], "twice"))
  assert(#rec2.steps == 2 and rec2.steps[1].tool == "mine" and rec2.steps[1].args.vein == "K1" and rec2.created_from == "recording")
  assert(Skills.save(fresh, rec2))
  assert(fresh.skills.twice.created_from == "recording")
end

print("skills OK")
