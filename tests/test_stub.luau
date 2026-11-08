-- Run from repo root: luau tests/test_stub.luau
-- GR5-76: the stub interpreter (spec 10.5), one test per table row: directive text -> expected tool call.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local World = require("@scripts/config/world")
local Market = require("@scripts/sim/market")
local Skills = require("@scripts/sim/skills")

local function veinOf(id) for _, v in ipairs(World.veins) do if v.id == id then return v end end end

-- A T3 company at Kessa with the warehouse, the scanner and every harvest planet in reach; every vein is scanned.
local function miner(directive, opts)
  opts = opts or {}
  local s = Sim.new({ seed = opts.seed or 1 })
  s.tier = 3
  for _, a in pairs(s.agents) do a.tier = 3 end
  s.upgrades.warehouse = opts.warehouse ~= false
  s.upgrades.scanner = opts.scanner ~= false
  s.upgrades.tradingPost = true
  s.ships.s1.engineMark, s.deepNav = 4, true
  if opts.scanned ~= false then
    for _, p in pairs(s.planets) do for _, v in ipairs(p.veins) do v.scanned = true end end
  end
  Market.quiet(s.market)
  s.agents.miner.directive = directive
  s:setDecider(Ai.decide)
  return s
end

local function decide(s, id) return Ai.decide(s, id or "miner", s:context(id or "miner")) end
local function mined(directive, opts)
  local s = miner(directive, opts)
  local call = decide(s)
  assert(call.name == "mine", directive .. " -> " .. call.name)
  return call, s
end
local function loaded(directive, opts) -- docked at Kessa with 50 cobalt in the hold
  local s = miner(directive, opts)
  s.ships.s1.cargo, s.ships.s1.ore = 50, "cobalt"
  return decide(s), s
end
local function seen(fn, n) -- the set of values `fn(seed)` returns over `n` seeds
  local out, count = {}, 0
  for seed = 1, n do
    local v = fn(seed)
    if not out[v] then out[v] = true; count += 1 end
  end
  return out, count
end

-- target resource
do
  for _, ore in ipairs({ "titanium", "cobalt", "iridium", "crystal" }) do
    for seed = 1, 4 do
      local call = mined("Mine " .. ore .. " please", { seed = seed })
      assert(veinOf(call.args.vein).ore == ore, ore .. " -> " .. call.args.vein)
      assert(call.reasoning:find(ore, 1, true), "the reasoning names it: " .. call.reasoning)
    end
  end
  assert(veinOf(mined("cobalt then titanium").args.vein).ore == "cobalt", "the first one mentioned wins")
  local s = miner("")
  s.agents.miner.order = "mine iridium"
  assert(veinOf(decide(s).args.vein).ore == "iridium", "the order wins over the directive")
  -- the best price among the reachable veins: iridium (base price x depot rate)
  local best, bestScore = nil, -1
  for _, v in ipairs(World.veins) do
    local score = World.ores[v.ore].basePrice * World.planets[v.planet].depotRate
    if not v.hidden and score > bestScore then best, bestScore = v.ore, score end
  end
  for _, phrase in ipairs({ "Mine the most valuable resource", "mine the most expensive ore" }) do
    assert(veinOf(mined(phrase).args.vein).ore == best, phrase)
  end
  local ores = seen(function(seed) return veinOf(mined("", { seed = seed }).args.vein).ore end, 12)
  assert(ores.titanium and ores.cobalt and ores.iridium, "no resource given: random among the reachable veins")
  assert(mined("").reasoning:find("at random", 1, true), "it says so")
end

-- target planet and vein
do
  for _, pid in ipairs({ "kessa", "varn", "ashfall", "lumen" }) do
    for seed = 1, 4 do
      local call = mined("Work on " .. pid .. ".", { seed = seed })
      assert(veinOf(call.args.vein).planet == pid, pid .. " -> " .. call.args.vein)
    end
  end
  local call = mined("mine cobalt on varn")
  assert(call.args.vein == "V1" or call.args.vein == "V2", call.args.vein)
  local out = mined("mine cobalt on ashfall") -- ashfall has no cobalt: the planet is ignored
  assert(veinOf(out.args.vein).ore == "cobalt", "an impossible planet is ignored")
  assert(mined("Go to v3 now").args.vein == "V3", "a vein id")
  assert(mined("mine k2").args.vein == "K2" and mined("mine k2").reasoning:find("K2", 1, true))
  assert(mined("richest cobalt").args.vein == "V2", "richest: the highest richness")
  assert(mined("best titanium").args.vein == "A3")
  assert(mined("richest iridium on varn").args.vein == "V3", "richest on the target planet")
  assert(mined("nearest titanium").args.vein == "K1", "nearest: the shortest travel")
  assert(mined("closest cobalt").args.vein == "K3" or mined("closest cobalt").args.vein == "V1")
  local all = mined("richest").args.vein
  assert(all == "A3", "richest over everything reachable: " .. all)
  local ids = seen(function(seed) return mined("mine cobalt on kessa", { seed = seed }).args.vein end, 12)
  assert(ids.K3 and ids.K4, "no vein given: random among that planet's cobalt veins")
  assert(mined("richest cobalt, best price available").args.vein == "V2", "best price is about buyers, not about the vein")
end

-- return threshold and where to dock
do
  assert(mined("mine cobalt, return at 75%").args.stop_at_hold_pct == 75)
  assert(mined("mine cobalt, 5 % hold").args.stop_at_hold_pct == 10, "clamped to 10")
  assert(mined("mine cobalt until 250%").args.stop_at_hold_pct == 100, "clamped to 100")
  local pcts = seen(function(seed) return mined("mine cobalt", { seed = seed }).args.stop_at_hold_pct end, 12)
  local n = 0
  for p in pairs(pcts) do n += 1; assert(p >= 10 and p <= 100) end
  assert(n > 4, "random threshold")
  assert(mined("mine cobalt").reasoning:find("%% at random"), "it says so")
  assert(mined("mine cobalt and sell locally").args.to == "local_depot")
  assert(mined("Use the local depot").args.to == "local_depot")
  assert(mined("bring it back").args.to == "home")
  assert(mined("go home when full").args.to == "home")
  assert(mined("sell in the warehouse").args.to == "home")
  local docks = seen(function(seed) return mined("mine cobalt", { seed = seed }).args.to end, 12)
  assert(docks.home and docks.local_depot, "no dock given: random")
  assert(mined("mine cobalt and sell at orbis").args.to == "home", "Orbis is at the home dock")
  assert(mined("mine cobalt and store it").args.to == "home", "storing is at the home dock")
  local call, s = mined("mine cobalt, return at 50%, bring back")
  assert(s:validate("miner", call), "the call validates")
end

-- the tool schema accepts `to` and refuses anything else
do
  local s = miner("")
  assert(s:validate("miner", { name = "mine", args = { vein = "K1", to = "local_depot" } }))
  local ok, err = s:validate("miner", { name = "mine", args = { vein = "K1", to = "moon" } })
  assert(not ok and err == "bad dock", tostring(err))
end

-- the sim's own return honours the dock
do
  local s = miner("")
  assert(s:apply("miner", { name = "mine", args = { vein = "K3", stop_at_hold_pct = 10, to = "local_depot" } }))
  assert(s.ships.s1.returnTo == "local_depot")
  s:run(s:ticks(300))
  assert(s.ships.s1.state ~= "mining" or s.ships.s1.cargo < s.ships.s1.cargoCap)
end

-- sell buyer, minimum price, store
do
  local s = miner("sell at hmc")
  s.ships.s1.cargo, s.ships.s1.ore = 50, "cobalt"
  local call = decide(s)
  assert(call.name == "sell" and call.args.buyer == "hmc" and call.args.resource == "cobalt" and call.args.qty == "all", call.name)
  for _, word in ipairs({ "hmc", "corporation", "depot" }) do
    call = loaded("sell it to the " .. word)
    assert(call.name == "sell" and call.args.buyer == "hmc", word .. " -> " .. tostring(call.args and call.args.buyer))
  end
  call = loaded("sell at Orbis")
  assert(call.name == "sell" and call.args.buyer == "orbis", "orbis")
  for _, b in ipairs({ "halcyon", "meridian" }) do
    call = loaded("sell at " .. b)
    assert(call.name == "sell" and call.args.buyer == b, b .. ": named even when locked (a teaching moment)")
    local s2 = miner("sell at " .. b)
    s2.ships.s1.cargo, s2.ships.s1.ore = 50, "cobalt"
    local ok, err = s2:validate("miner", call)
    assert(not ok and err == "buyer_locked", tostring(err))
  end
  -- best price: the buyer paying the most for the hold
  local s3 = miner("sell at the best price")
  s3.ships.s1.cargo, s3.ships.s1.ore = 50, "cobalt"
  local want, top = "hmc", World.ores.cobalt.basePrice * World.planets.kessa.depotRate
  local orbis = Market.price(s3.market, "orbis", "cobalt")
  if orbis > top then want = "orbis" end
  call = decide(s3)
  assert(call.name == "sell" and call.args.buyer == want, "best price -> " .. tostring(call.args.buyer) .. " want " .. want)
  call = loaded("sell at the highest price")
  assert(call.name == "sell" and call.args.buyer == want, call.name .. tostring(call.args and call.args.buyer) .. want)
  s3.market.markets.orbis.res.cobalt.d = 10 -- Orbis now pays far more
  call = decide(s3)
  assert(call.args.buyer == "orbis", "follows the prices: " .. tostring(call.args.buyer))
  local buyers = seen(function(seed)
    local c = loaded("sell it", { seed = seed })
    return c.args.buyer
  end, 12)
  assert(buyers.hmc and buyers.orbis, "no buyer given: random among the visible ones")

  -- minimum price
  call = loaded("sell at hmc, never sell below 99999")
  assert(call.name == "wait" and call.args.seconds == 60 and call.reasoning:find("minimum", 1, true), "below the minimum: wait(60)")
  call = loaded("sell at hmc, not under 99999")
  assert(call.name == "wait")
  call = loaded("sell at hmc, minimum 99999")
  assert(call.name == "wait")
  call = loaded("sell at hmc, minimum 1")
  assert(call.name == "sell" and call.args.buyer == "hmc", "the price meets the minimum")
  call = loaded("sell at hmc, never sell below 2.5")
  assert(call.name == "sell", "a decimal minimum")

  -- store
  call = loaded("store the cobalt")
  assert(call.name == "store" and call.args.resource == "cobalt" and call.args.qty == "all")
  call = loaded("put it in the warehouse")
  assert(call.name == "store")
  call = loaded("sell at hmc and do not store anything")
  assert(call.name == "store", "the word store wins (the first match)")
  call = loaded("sell cobalt at hmc")
  assert(call.name == "sell", "an explicit sell is not stored")
  local choices = seen(function(seed) return loaded("", { seed = seed }).name end, 16)
  assert(choices.store and choices.sell, "no intent and a warehouse: 50% store")
  local none = seen(function(seed) return loaded("", { seed = seed, warehouse = false }).name end, 16)
  assert(none.sell and not none.store, "no warehouse: never stores")
end

-- scan
do
  local s = miner("scan first", { scanned = false })
  local call = decide(s)
  assert(call.name == "scan" and World.planets[call.args.planet] ~= nil, call.name)
  assert(s:validate("miner", call))
  assert(decide(miner("mine cobalt", { scanned = false })).name == "mine", "never scans unasked")
  assert(decide(miner("scan the planets", { scanned = false, scanner = false })).name == "mine", "no scanner: no scan")
  assert(decide(miner("scan the planets")).name == "mine", "everything scanned already")
end

-- use a skill
do
  local s = miner("use skill Cobalt loop")
  assert(Skills.save(s, { name = "Cobalt loop", agent_type = "miner", loop = true, params = { vein = { kind = "vein" } },
    steps = { { tool = "mine", args = { vein = "$vein" } }, { tool = "return" }, { tool = "sell" } } }))
  local call = decide(s)
  assert(call.name == "run_skill" and call.args.name == "Cobalt loop" and call.args.params.vein, call.name)
  assert(s:validate("miner", call), "bad params?")
  s.agents.miner.directive = "run cobalt loop on v1"
  call = decide(s)
  assert(call.name == "run_skill" and call.args.params.vein == "V1", "a vein in the text fills the parameter")
  s.agents.miner.directive = "mine cobalt"
  assert(decide(s).name == "mine", "no skill named: never")
  s.agents.miner.directive = "use skill Unknown loop"
  assert(decide(s).name == "mine", "an unknown skill is not run")
  s.agents.miner.directive = "scan, use skill Cobalt loop"
  assert(decide(s).name == "scan" or decide(s).name == "run_skill", "scan comes first, only while there is something to scan")
end

-- every stub call carries a reasoning that says where each value came from
do
  local call = mined("Mine cobalt, richest vein, return at 90%, sell locally")
  assert(call.reasoning:find("cobalt", 1, true) and call.reasoning:find("richest", 1, true) and call.reasoning:find("90%", 1, true), call.reasoning)
  local vague = mined("")
  assert(vague.reasoning:find("at random", 1, true) and #vague.reasoning <= 200, vague.reasoning)
end

-- Logistician
do
  local function station()
    local s = Sim.new({ seed = 2 })
    s:enterTier(3)
    s.lifetimeRevenue = 80000
    s.resources.credits, s.resources.compute = 500000, 500
    Market.quiet(s.market)
    assert(s:buyUpgrade("warehouse") and s:buyUpgrade("logistics_hub"))
    assert(s:hireLogistician("kessa"))
    assert(s:buyFreighter("kessa"))
    s:enterTier(4)
    s.upgrades.tradingPost = true
    s:setDecider(Ai.decide)
    return s
  end
  local function ship(directive, stock, setup)
    local s = station()
    for k, v in pairs(stock or { cobalt = 500 }) do s.warehouse[k] = v end
    s.agents.logistician.directive = directive
    if setup then setup(s) end
    return Ai.decide(s, "logistician", s:context("logistician")), s
  end
  local call = ship("Ship cobalt to Halcyon.")
  assert(call.name == "ship" and call.args.resource == "cobalt" and call.args.destination == "halcyon" and call.args.qty == 500, call.name)
  assert(call.reasoning:find("halcyon", 1, true))
  call = ship("only meridian", { cobalt = 500, iridium = 400 })
  assert(call.name == "ship" and call.args.destination == "meridian", "a named destination")
  call = ship("only cobalt", { titanium = 800, cobalt = 350 })
  assert(call.name == "ship" and call.args.resource == "cobalt" and call.args.qty == 350, "a named resource restricts it")
  call = ship("ship cobalt to meridian")
  assert(call.args.destination == "meridian", "meridian does not buy cobalt: still shipped, the error teaches")
  local sim
  call, sim = ship("ship cobalt to meridian")
  local good, why = sim:validate("logistician", call)
  assert(not good and why == "not_bought_here", tostring(why))
  call = ship("ship at the best price", { titanium = 400 })
  assert(call.name == "ship" and call.args.resource == "titanium" and call.args.destination == "halcyon", "best price: halcyon pays most for titanium: " .. tostring(call.args.destination))
  assert(call.reasoning:find("best price", 1, true))
  call = ship("ship cobalt to the highest price", { cobalt = 400 })
  assert(call.args.destination == "halcyon", "highest price")
  call = ship("ship iridium at the best price", { iridium = 400 }, function(s)
    s.market.markets.orbis.res.iridium.d = 20
  end)
  assert(call.args.destination == "orbis", "it follows the price: " .. tostring(call.args.destination))
  call = ship("sell cobalt at orbis")
  assert(call.name == "sell" and call.args.buyer == "orbis" and call.args.qty == "all", call.name)
  call = ship("Ship stuff.", { cobalt = 100 })
  assert(call.name == "wait" and call.args.seconds == 60, "stock below 300: wait(60)")
  call = ship("Ship stuff.", {}, function(s) s.warehouse.cobalt = 0 end)
  assert(call.name == "wait")
  local dests = seen(function(seed)
    local s = station()
    s.warehouse.iridium = 500
    s.agents.logistician.directive = "Ship stuff."
    for _ = 1, seed do s.randStub() end
    return Ai.decide(s, "logistician", s:context("logistician")).args.destination
  end, 12)
  assert(dests.halcyon and dests.meridian, "no destination: random among markets that buy it")
end

-- Monitor
do
  local function monitor()
    local s = Sim.new()
    s.tier = 4
    for _, a in pairs(s.agents) do a.tier = 4 end
    s.lifetimeRevenue = s.b.reputationLevels[2]
    s.resources.credits, s.resources.compute = 250000, 200
    Market.quiet(s.market)
    s:setDecider(Ai.decide)
    assert(Skills.save(s, { name = "Titanium loop", agent_type = "miner", loop = true,
      params = { vein = { kind = "vein", filter = { resource = "titanium" } } },
      steps = { { tool = "mine", args = { vein = "$vein" } }, { tool = "return" }, { tool = "sell" } } }))
    assert(s:buyUpgrade("command_center") and s:hireMonitor())
    s.ships.s1.engineMark, s.deepNav = 4, true
    return s
  end
  local function react(directive, alert, setup)
    local s = monitor()
    if setup then setup(s) end
    s.agents.monitor.directive = directive
    local ctx = s:context("monitor")
    ctx.alerts = alert and { { id = 1, type = alert.type, agent = alert.agent or "miner", reason = alert.reason or "vein_depleted",
      skill = alert.skill, params = alert.params, age_s = 5 } } or {}
    return Ai.decide(s, "monitor", ctx), s
  end
  local aborted = { type = "skill_aborted", skill = "Titanium loop", params = "vein=K1" }
  local function paused(s) s.agents.miner.state = "paused_error" end

  -- resume / restart / unstick: resume_agent on agent_paused
  for _, w in ipairs({ "resume", "restart", "unstick" }) do
    local call = react("Please " .. w .. " stuck agents.", { type = "agent_paused", reason = "invalid_responses" }, paused)
    assert(call.name == "resume_agent" and call.args.agent == "miner", w .. " -> " .. call.name)
    assert(call.reasoning:find("resume", 1, true))
  end
  local call = react("resume stuck agents", aborted)
  assert(call.name ~= "resume_agent" or call.reasoning:find("random", 1, true), "resume does not fit a skill_aborted alert")

  -- skill / switch / reassign: assign_skill on skill_aborted, no_compute, agent_idle
  for _, w in ipairs({ "skill", "switch", "reassign" }) do
    for _, kind in ipairs({ "skill_aborted", "no_compute", "agent_idle" }) do
      call = react("When needed " .. w .. " the agent.", { type = kind, skill = kind == "skill_aborted" and "Titanium loop" or nil,
        params = kind == "skill_aborted" and "vein=K1" or nil })
      assert(call.name == "assign_skill" and call.args.skill == "Titanium loop" and call.args.params.vein, w .. "/" .. kind .. " -> " .. call.name)
      assert(call.args.params.vein ~= "K1" or kind ~= "skill_aborted", "not the depleted vein")
    end
  end
  call = react("reassign skills", { type = "agent_paused" }, paused)
  assert(call.name ~= "assign_skill" or call.reasoning:find("random", 1, true), "reassign does not fit agent_paused")

  -- order / tell: set_order with the fixed text, on any alert
  for _, w in ipairs({ "order", "tell" }) do
    for _, kind in ipairs({ "skill_aborted", "agent_paused", "losing_money" }) do
      call = react("Just " .. w .. " it.", { type = kind, reason = "because" })
      assert(call.name == "set_order" and call.args.text == "Previous plan failed: because. Choose another option.", w .. "/" .. kind .. " -> " .. call.name)
    end
  end

  -- pause + losing: pause_agent on losing_money
  call = react("Pause the agent when it is losing money.", { type = "losing_money", reason = "net_negative" })
  assert(call.name == "pause_agent" and call.args.agent == "miner")
  call = react("Pause agents.", { type = "losing_money", reason = "net_negative" })
  assert(call.name ~= "pause_agent" or call.reasoning:find("random", 1, true), "pause alone enables nothing")
  call = react("pause when losing", { type = "agent_idle", reason = "idle" })
  assert(call.name ~= "pause_agent" or call.reasoning:find("random", 1, true), "only on losing_money")

  -- nothing fits: a random valid action; no alert: wait(60)
  local acts = seen(function(seed)
    local s = monitor()
    s.agents.monitor.directive = "Be helpful."
    for _ = 1, seed do s.randStub() end
    local ctx = s:context("monitor")
    ctx.alerts = { { id = 1, type = "agent_idle", agent = "miner", reason = "idle", age_s = 1 } }
    local c = Ai.decide(s, "monitor", ctx)
    assert(c.reasoning:find("random", 1, true), c.reasoning)
    return c.name
  end, 24)
  local kinds = 0
  for _ in pairs(acts) do kinds += 1 end
  assert(kinds >= 2, "a vague directive behaves erratically")
  call = react("resume skill order", nil)
  assert(call.name == "wait" and call.args.seconds == 60, "no alert: wait(60)")

  -- rotate: the same resource, the highest reserve, on a vein no other ship is using
  local function rotate(withShip2)
    return react("When a skill aborts, rotate to the next vein.", aborted, function(s)
      for _, p in pairs(s.planets) do for _, v in ipairs(p.veins) do v.scanned = true end end
      s.veins.K1.reserve = 0
      s.veins.K2.reserve = s.veins.K2.max * 0.6
      s.veins.A3.reserve = s.veins.A3.max
      if withShip2 then
        assert(s:buyUpgrade("ship2"))
        s.ships.s2.engineMark = 4
        assert(s:apply("miner2", { name = "mine", args = { vein = "A3" } }))
        assert(s.ships.s2.vein.id == "A3")
      end
    end)
  end
  call = rotate(false)
  assert(call.name == "assign_skill" and call.args.params.vein == "A3", "no other ship: the best vein: " .. tostring(call.args.params and call.args.params.vein))
  call = rotate(true)
  assert(call.name == "assign_skill" and call.args.skill == "Titanium loop" and call.args.params.vein == "K2",
    "another ship holds A3: " .. tostring(call.args.params and call.args.params.vein))
  assert(call.reasoning:find("free vein", 1, true))
  call = react("next vein please", aborted, function(s) -- nothing else to rotate to: not an invalid call
    for _, p in pairs(s.planets) do for _, v in ipairs(p.veins) do v.scanned = true; if v.ore == "titanium" then v.reserve = 0 end end end
  end)
  assert(call.name ~= "assign_skill", call.name)
end

print("stub OK")
