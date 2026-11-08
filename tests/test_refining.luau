-- Run from repo root: luau tests/test_refining.luau
-- B-b (spec §15b.2, §15b.6): refineries and jobs, refined goods in the markets and the stocks, the Refiner's tools, margins
-- in its context, the stub Refiner, recipe skills, mission V1, the Branches/Shop/Missions views, saving, and the acceptance test:
-- after a demand trend, a stub Refiner told "best margin" earns more over 30 game minutes than a fixed-recipe skill.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Market = require("@scripts/sim/market")
local World = require("@scripts/config/world")
local Cfg = require("@scripts/config/branches").refining
local Refining = require("@scripts/sim/refining")
local Skills = require("@scripts/sim/skills")
local Persistence = require("@scripts/sim/persistence")
local Json = require("@scripts/sim/json")
local ContextBuilder = require("@scripts/sim/context_builder")
local ContextSettings = require("@scripts/sim/context_settings")
local MissionsView = require("@scripts/ui/missions_view")
local ShopView = require("@scripts/ui/shop_view")
local BranchesView = require("@scripts/ui/branches_view")
local MarketView = require("@scripts/ui/market_view")
local Prompt = require("@scripts/sim/prompt")

local function run(s, seconds) s:run(s:ticks(seconds)) end
local function ok(s, agent, name, args)
  local good, err = s:validate(agent, { name = name, args = args or {} })
  assert(good, name .. ": " .. tostring(err))
  assert(s:apply(agent, { name = name, args = args or {} }))
end
local function refused(s, agent, name, args, why)
  local good, err = s:validate(agent, { name = name, args = args or {} })
  assert(not good and err == why, name .. ": want " .. why .. ", got " .. tostring(err))
end

-- A T4 company with the warehouse and the trading post, the branch not opened yet.
local function company(opts)
  opts = opts or {}
  local s = Sim.new({ seed = opts.seed })
  s:enterTier(3)
  s.lifetimeRevenue = 60000
  s.resources.credits = 500000
  s.resources.compute = 500
  assert(s:buyUpgrade("warehouse") and s:buyUpgrade("trading_post"))
  s:enterTier(4)
  if opts.quiet ~= false then Market.quiet(s.market) end
  return s
end
local function refinery(opts)
  local s = company(opts)
  assert(s:openBranch("refining"))
  return s
end
local function stock(s, ore, n) s.warehouse[ore] = n end

-- 1. nothing exists before the branch is open
do
  local s = Sim.new()
  assert(s.refining and #s.refining.order == 0 and not s.agents.refiner)
  assert(not Market.has(s.market, "orbis", "plate") and s.warehouse.plate == nil)
  assert(not Refining.isOpen(s) and #Refining.shopRows(s) == 0)
  assert(#MissionsView.model(s).optional == 0)
end

-- 2. opening: Tier 3 and the warehouse, 18,000 cr, a refinery on the main station, the Refiner agent, refined goods listed
do
  local s = Sim.new()
  assert(select(2, s:openBranch("refining")) == "tier_locked")
  s:enterTier(3)
  s.resources.credits = 100000
  s.lifetimeRevenue = 0
  assert(select(2, s:openBranch("refining")) == "needs_warehouse")
  s.lifetimeRevenue = 60000
  assert(s:buyUpgrade("warehouse") and s:buyUpgrade("trading_post"))
  s:enterTier(4)
  s.resources.credits = 17999
  assert(select(2, s:openBranch("refining")) == "not_enough_credits")
  s.resources.credits = 20000
  assert(s:openBranch("refining") and s.resources.credits == 2000)
  assert(s.branchesOpen.refining and s.agents.refiner and s.agents.refiner.type == "refiner")
  local ref = Refining.refineryAt(s, s.home)
  assert(ref and ref.owner == "refiner" and not ref.mk2 and not ref.job)
  assert(Refining.refineryFor(s, "refiner") == ref)
  for _, good in ipairs(Cfg.recipeOrder) do
    assert(s.warehouse[good] == 0, good .. " stock key")
  end
  assert(Market.has(s.market, "orbis", "plate") and Market.has(s.market, "halcyon", "superalloy"))
  assert(Market.has(s.market, "meridian", "processor") and not Market.has(s.market, "orbis", "catalyst"))
  assert(s.market.markets.meridian.res.processor.depth == 3000)
  assert(math.abs(Market.price(s.market, "meridian", "processor") - 340 * 1.5) < 1e-6)
  local tools = s:equippedTools("refiner")
  assert(#tools == 4 and s:hasTool("refiner", "refine"), table.concat(tools, ","))
  assert(s:toolSlots("refiner") ~= nil and s.agents.refiner.tools.refine)
  assert(s.refining.mission.status == "active")
end

-- 3. refine: validation, inputs leave the stock now, the output lands when the job ends, one job at a time
do
  local s = refinery()
  stock(s, "titanium", 100)
  refused(s, "refiner", "refine", { recipe = "gold", qty = 5 }, "bad recipe")
  refused(s, "refiner", "refine", { recipe = "plate", qty = 0 }, "bad qty")
  refused(s, "refiner", "refine", { recipe = "plate", qty = 51 }, "bad qty")
  refused(s, "refiner", "refine", { recipe = "plate", qty = 2.5 }, "bad qty")
  refused(s, "refiner", "refine", { recipe = "plate", qty = 34 }, "not_enough_input")
  refused(s, "refiner", "refine", { recipe = "superalloy", qty = 1 }, "not_enough_input")
  ok(s, "refiner", "refine", { recipe = "plate", qty = 10 })
  assert(s.warehouse.titanium == 70 and s.warehouse.plate == 0, "inputs taken at once")
  refused(s, "refiner", "refine", { recipe = "plate", qty = 1 }, "refinery_busy")
  assert(not s:needsDecision("refiner"))
  run(s, 29)
  assert(s.warehouse.plate == 0, "10 plates take 30 s")
  run(s, 3)
  assert(s.warehouse.plate == 10 and Refining.refineryAt(s, s.home).job == nil)
  assert(s:needsDecision("refiner"))
  refused(s, "refiner", "wait", { seconds = 1 }, "bad seconds")
  -- Mk2 doubles the speed
  Refining.refineryAt(s, s.home).mk2 = true
  ok(s, "refiner", "refine", { recipe = "plate", qty = 10 })
  run(s, 16)
  assert(s.warehouse.plate == 20, "Mk2: 10 plates in 15 s")
end

-- 4. a full station holds the output back until there is room (the refinery blocks), then delivers it
do
  local s = refinery()
  stock(s, "titanium", 45)
  ok(s, "refiner", "refine", { recipe = "plate", qty = 10 })
  local cap = s.b.warehouse.capacity
  s.warehouse.cobalt = cap - 20 - s.warehouse.titanium -- 20 units free with 10 plates arriving: room for all
  run(s, 31)
  assert(s.warehouse.plate == 10)
  ok(s, "refiner", "refine", { recipe = "plate", qty = 5 })
  s.warehouse.cobalt = cap - s.warehouse.titanium - s.warehouse.plate - 2 -- room for 2 of the 5
  run(s, 16)
  local ref = Refining.refineryAt(s, s.home)
  assert(ref.job and ref.job.blocked and s.warehouse.plate == 12, "blocked with 3 waiting")
  refused(s, "refiner", "refine", { recipe = "plate", qty = 1 }, "station_full")
  s.warehouse.cobalt = 0
  run(s, 1)
  assert(s.warehouse.plate == 15 and ref.job == nil, "the rest arrives once there is room")
end

-- 5. the shop: a refinery on an outpost (12,000) with its own Refiner, Mk2 (15,000), one refinery per station
do
  local s = refinery()
  s.lifetimeRevenue = 200000
  assert(s:buyUpgrade("engine_mk2") and s:buyUpgrade("engine_mk3") and s:buyUpgrade("logistics_hub"))
  assert(s:buildOutpost("varn"))
  local rows = Refining.shopRows(s)
  local ids = {}
  for _, r in ipairs(rows) do ids[r.id] = r end
  assert(ids["refinery:varn"] and ids["refinery_mk2:kessa"] and not ids["refinery:kessa"] and not ids["refinery_mk2:varn"])
  assert(ids["refinery:varn"].cost == 12000 and ids["refinery_mk2:kessa"].cost == 15000)
  assert(s.stations.varn.stock.plate == 0, "refined goods are stocked at outposts built after opening")
  local credits = s.resources.credits
  assert(select(2, s:buyUpgrade("refinery_mk2:varn")) == "needs_refinery")
  assert(s:buyUpgrade("refinery:varn") and s.resources.credits == credits - 12000)
  local ref = Refining.refineryAt(s, "varn")
  assert(ref and ref.owner == "refiner_2" and s.agents.refiner_2.station == "varn", "an empty Refiner for the new refinery")
  assert(select(2, s:buyUpgrade("refinery:varn")) == "already_owned")
  credits = s.resources.credits
  assert(s:buyUpgrade("refinery_mk2:varn") and s.resources.credits == credits - 15000 and ref.mk2)
  assert(select(2, s:buyUpgrade("refinery_mk2:varn")) == "already_owned")
  assert(select(2, s:buyUpgrade("refinery:atlantis")) == "unknown_station" or select(2, s:buyUpgrade("refinery:atlantis")) == "unknown_item")
  -- each Refiner works the stock of its own station
  s.stations.varn.stock.titanium = 30
  ok(s, "refiner_2", "refine", { recipe = "plate", qty = 10 })
  assert(s.stations.varn.stock.titanium == 0 and s.warehouse.titanium == 0)
  run(s, 16)
  assert(s.stations.varn.stock.plate == 10)
  local owned
  for _, r in ipairs(Refining.shopRows(s)) do if r.id == "refinery:varn" then owned = r end end
  assert(owned == nil, "an owned refinery is replaced by its Mk2 row")
end

-- 6. logistics: refined goods are sold at Orbis from the main station or shipped to a market that buys them; mission V1
do
  local s = refinery()
  assert(s:buyUpgrade("logistics_hub") and s:hireLogistician("kessa") and s:buyFreighter("kessa"))
  s.warehouse.superalloy, s.warehouse.plate, s.warehouse.catalyst = 60, 10, 10
  refused(s, "logistician", "sell", { resource = "plate", qty = "all" }, "not_bought_here")
  refused(s, "logistician", "sell", { resource = "plate", qty = "all", buyer = "hmc" }, "not_bought_here")
  refused(s, "logistician", "ship", { resource = "plate", qty = 10, destination = "meridian" }, "not_bought_here")
  refused(s, "logistician", "ship", { resource = "catalyst", qty = 10, destination = "orbis" }, "not_bought_here")
  -- an Orbis sale below 1.5 x the input value does not count for V1
  local credits = s.resources.credits
  ok(s, "logistician", "sell", { resource = "plate", qty = "all", buyer = "orbis" })
  assert(s.warehouse.plate == 0 and s.resources.credits > credits)
  assert(s.refining.mission.units == 0, "plate at Orbis (27 cr) is worth less than 45")
  assert(Refining.mission(s).status == "active")
  assert(select(2, Refining.claimMission(s)) == "not_complete")
  -- a freighter load to Halcyon does (superalloy 168 >= 1.5 x 68)
  ok(s, "logistician", "ship", { resource = "superalloy", qty = 50, destination = "halcyon" })
  run(s, 241)
  assert(s.refining.mission.units == 50 and s.refining.mission.status == "complete", "units " .. s.refining.mission.units)
  local before = s.resources.credits
  local good, reward = Refining.claimMission(s)
  assert(good and reward.credits == 3000 and s.resources.credits == before + 3000)
  assert(select(2, Refining.claimMission(s)) == "already_claimed")
  -- the Missions view lists V1 with its claim button
  local s2 = refinery()
  local m = MissionsView.model(s2)
  assert(#m.optional == 1 and m.optional[1].id == "V1" and m.optional[1].claim == nil and m.optional[1].progressText == "0 / 50 units")
  s2.refining.mission.status, s2.refining.mission.units = "complete", 50
  m = MissionsView.model(s2)
  assert(m.optional[1].claim == "missions.claim.V1")
  local handled, done = MissionsView.act(s2, "missions.claim.V1")
  assert(handled and done and s2.refining.mission.status == "claimed")
end

-- 7. the Refiner's context: margins behind the setting, recipes, stock and prices of raw and refined goods
do
  local s = refinery()
  s.warehouse.titanium, s.warehouse.iridium, s.warehouse.crystal = 30, 4, 2
  local c = s:context("refiner")
  assert(c.refinery.state == "idle" and #c.recipes == 4 and #c.margins == 4)
  local byName = {}
  for _, r in ipairs(c.recipes) do byName[r.name] = r end
  assert(byName.plate.can_make == 10 and byName.catalyst.can_make == 2 and byName.processor.can_make == 2 and byName.superalloy.can_make == 0)
  assert(byName.plate.time_s == 3 and byName.processor.time_s == 12)
  local best
  for _, m in ipairs(c.margins) do if not best or m.margin_per_unit > best.margin_per_unit then best = m end end
  assert(best.recipe == "processor" and best.best_market == "meridian" and best.margin_per_unit > 0)
  assert(c.prices.meridian.processor and c.prices.orbis.plate and c.prices.meridian.crystal)
  assert(ContextSettings.options.margins and ContextSettings.defaults().margins == false)
  assert(ContextSettings.orderFor("refiner")[1] == "margins")
  local function text()
    local b = Prompt.build(s, "refiner")
    local out = b.text or ""
    if out == "" then for _, v in pairs(b) do if type(v) == "string" then out ..= v .. "\n" end end end
    return out
  end
  local without = text()
  assert(without:find("refiner", 1, true) and without:find("recipes", 1, true) and not without:find("margins", 1, true), without)
  assert(s:setContextSetting("refiner", "margins", true))
  local withMargins = text()
  assert(withMargins:find("margins", 1, true) and withMargins:find("processor", 1, true) and #withMargins > #without)
  assert(withMargins:find("refine", 1, true) and withMargins:find("run_skill", 1, true), "its tools are listed")
  -- a job shows in the refinery line
  ok(s, "refiner", "refine", { recipe = "plate", qty = 5 })
  assert(s:context("refiner").refinery.state == "refining")
  local data = ContextBuilder.build(s, "refiner")
  assert(#data > 5)
end

-- 8. the stub Refiner (spec §15b.6)
do
  local function stubbed(directive, setup)
    local s = refinery({ seed = 5 })
    s:setDecider(Ai.decide)
    s.resources.compute = 500
    for _, o in ipairs({ "titanium", "cobalt", "iridium", "crystal" }) do s.warehouse[o] = 300 end
    if setup then setup(s) end
    s:setDirective("refiner", directive)
    return s
  end
  local function first(s)
    for _ = 1, 200 do
      s:step()
      for _, e in ipairs(s.feed) do if e.agent == "refiner" and e.tool == "refine" then return e end end
    end
  end
  local e = first(stubbed("Refine superalloy, 20 at a time"))
  assert(e and e.args.recipe == "superalloy" and e.args.qty == 20, "a named recipe and quantity")
  e = first(stubbed("Make catalyst"))
  assert(e and e.args.recipe == "catalyst" and e.args.qty >= 5 and e.args.qty <= 50, "a random quantity of 5-50")
  e = first(stubbed("Make processor", function(s) s.warehouse.crystal, s.warehouse.iridium = 3, 8 end))
  assert(e and e.args.recipe == "processor" and e.args.qty == 3, "clamped to what the stock allows")
  e = first(stubbed("go", function(s) s.warehouse.cobalt, s.warehouse.iridium, s.warehouse.crystal = 0, 0, 0 end))
  assert(e and e.args.recipe == "plate", "a random recipe it has the inputs for")
  -- with the margins setting on, "best margin" picks the best recipe; without prices it stays random
  e = first(stubbed("best margin, 10 units", function(s) s:setContextSetting("refiner", "margins", true) end))
  assert(e and e.args.recipe == "processor" and e.args.qty == 10, e and e.args.recipe)
  local blind = stubbed("best margin", function(s)
    s:setContextSetting("refiner", "prices_orbis", false)
  end)
  local picks = {}
  for seed = 1, 12 do
    local s = Sim.new({ seed = seed })
    s:enterTier(3); s.lifetimeRevenue = 60000; s.resources.credits = 500000; s.resources.compute = 500
    assert(s:buyUpgrade("warehouse") and s:buyUpgrade("trading_post")); s:enterTier(4); assert(s:openBranch("refining"))
    s:setDecider(Ai.decide)
    for _, o in ipairs({ "titanium", "cobalt", "iridium", "crystal" }) do s.warehouse[o] = 300 end
    s:setContextSetting("refiner", "prices_orbis", false)
    s:setDirective("refiner", "best margin")
    local ev = first(s)
    if ev then picks[ev.args.recipe] = true end
  end
  local n = 0
  for _ in pairs(picks) do n += 1 end
  assert(n >= 2, "without the margins or prices the stub does not know the best recipe")
  assert(blind ~= nil)
  -- nothing makeable: it waits, and never sends an invalid call
  local s = stubbed("make plate", function(s) for _, o in ipairs({ "titanium", "cobalt", "iridium", "crystal" }) do s.warehouse[o] = 0 end end)
  run(s, 120)
  assert(s.agents.refiner.state ~= "paused_error" and s.warehouse.plate == 0)
  s.warehouse.titanium = 9
  run(s, 60)
  assert(s.warehouse.plate >= 3 or Refining.refineryAt(s, s.home).job ~= nil, "it resumes once the inputs arrive")
end

-- 9. skills: a Refiner skill with a recipe parameter
do
  local s = refinery({ seed = 3 })
  s.skills = {}
  local skill = { name = "make", agent_type = "refiner", loop = true, params = { r = { kind = "recipe" } },
    steps = { { tool = "refine", args = { recipe = "$r", qty = 10 } } } }
  assert(Skills.save(s, skill, { agent = "refiner" }))
  assert(select(2, Skills.assign(s, "refiner", "make", {})) == "bad_params")
  assert(select(2, Skills.assign(s, "refiner", "make", { r = "gold" })) == "bad_params")
  assert(Skills.paramOfArg("recipe") == "recipe")
  s.warehouse.titanium = 100
  assert(Skills.assign(s, "refiner", "make", { r = "plate" }))
  s:setDecider(Ai.decide)
  s:setDirective("miner", "Mine cobalt and sell at HMC.") -- a vague Miner may store into the warehouse (spec 10.5)
  run(s, 120)
  assert(s.warehouse.plate == 30 and s.warehouse.titanium == 10, "three jobs of 10 plates: " .. s.warehouse.plate)
  assert(s.agents.refiner.mode == "skill", s.agents.refiner.mode)
  run(s, 60) -- the titanium is gone: the step is skipped, the skill keeps running
  assert(s.agents.refiner.mode == "skill" and s.agents.refiner.state ~= "paused_error")
  s.warehouse.titanium = 30
  run(s, 40)
  assert(s.warehouse.plate >= 40, "it picks the work up again: " .. s.warehouse.plate)
end

-- 10. acceptance (B-b): after a demand trend, "best margin" beats a fixed-recipe skill over 30 game minutes
do
  local TOP = 400
  local function net(mode)
    local s = refinery({ seed = 11 })
    s.skills = {}
    s.warehouse.titanium, s.warehouse.cobalt, s.warehouse.iridium, s.warehouse.crystal = TOP, TOP, TOP, TOP
    if mode == "best" then
      assert(s:setContextSetting("refiner", "margins", true))
      s:setDirective("refiner", "best margin, 50 units")
    else
      local skill = { name = "fixed", agent_type = "refiner", loop = true, params = { r = { kind = "recipe" } },
        steps = { { tool = "refine", args = { recipe = "$r", qty = 50 } } } }
      assert(Skills.save(s, skill, { agent = "refiner" }))
      assert(Skills.assign(s, "refiner", "fixed", { r = "processor" }))
    end
    s:setDecider(Ai.decide)
    local revenue, spent = 0, 0
    local function topUp()
      for _, ore in ipairs({ "titanium", "cobalt", "iridium", "crystal" }) do
        local have = s.warehouse[ore] or 0
        if have < TOP then s.warehouse[ore] = TOP end
      end
    end
    local before = {}
    for _, ore in ipairs({ "titanium", "cobalt", "iridium", "crystal" }) do before[ore] = s.warehouse[ore] end
    for sec = 1, 1800 do
      if sec == 900 then
        -- the demand trend: processors lose most of their buyers at Meridian
        local r = s.market.markets.meridian.res.processor
        r.b, r.t, r.driftT = 0.3, 0.3, 0.3
      end
      run(s, 1)
      for _, good in ipairs(Cfg.recipeOrder) do
        local n = s.warehouse[good] or 0
        if n > 0 then
          local mid = Market.best(s.market, good, function(id) return s:marketUnlocked(id) end)
          local _, total = Market.sell(s.market, mid, good, n)
          revenue += total
          s.warehouse[good] = 0
        end
      end
      if sec % 60 == 0 then
        for _, ore in ipairs({ "titanium", "cobalt", "iridium", "crystal" }) do
          local used = TOP - (s.warehouse[ore] or 0)
          spent += used * World.ores[ore].basePrice
        end
        topUp()
      end
    end
    -- inputs still sitting in a job count as spent
    return revenue - spent, revenue
  end
  local best, bestRev = net("best")
  local fixed, fixedRev = net("fixed")
  assert(bestRev > 0 and fixedRev > 0, "both earned something")
  assert(best > fixed, ("best margin (%d) must beat the fixed recipe (%d)"):format(best, fixed))
  assert(select(1, net("best")) == best, "deterministic")
end

-- 11. saving: refineries, a job in progress and the mission survive a round trip
do
  local s = refinery({ seed = 5, quiet = false })
  s.warehouse.titanium = 60
  ok(s, "refiner", "refine", { recipe = "plate", qty = 10 })
  run(s, 5)
  local job = Refining.refineryAt(s, s.home).job
  assert(job and job.recipe == "plate")
  local r = Persistence.restore(Json.decode(Json.encode(Persistence.serialize(s, 100))))
  local ref = Refining.refineryAt(r, r.home)
  assert(ref and ref.job and ref.job.recipe == "plate" and ref.job.qty == 10, "job restored")
  assert(r.agents.refiner and Refining.isOpen(r) and Market.has(r.market, "orbis", "plate"))
  run(r, 40)
  assert(r.warehouse.plate == 10, "the restored job finishes: " .. tostring(r.warehouse.plate))
end

-- 12. views
do
  local s = company()
  local rows = BranchesView.model(s).rows
  local row
  for _, x in ipairs(rows) do if x.id == "refining" then row = x end end
  assert(row, "refining row in the Branches panel")
  assert(s:openBranch("refining"))
  local shop = ShopView.model(s)
  assert(shop, "shop model")
  local m = MarketView.model(s)
  assert(m, "market model")
  local found = false
  local function scan(t, depth)
    if depth > 4 then return end
    for _, v in pairs(t) do
      if v == "plate" or v == "Plate" then found = true end
      if type(v) == "table" then scan(v, depth + 1) end
    end
  end
  scan(m, 0)
  assert(found, "refined goods show in the Market panel")
end

print("test_refining: ok")
