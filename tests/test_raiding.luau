-- Run from repo root: luau tests/test_raiding.luau
-- B-c (spec §15b.4-15b.6): rival convoys as entities, the interceptor ladder, the Privateer's tools, combat and the wolf
-- pack, Notoriety, standing, the blacklist and retaliation, mission V3, the stub Privateer, skills, UI view-models, saving.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Market = require("@scripts/sim/market")
local World = require("@scripts/config/world")
local Cfg = require("@scripts/config/branches").raiding
local Raiding = require("@scripts/sim/raiding")
local Skills = require("@scripts/sim/skills")
local Persistence = require("@scripts/sim/persistence")
local Prompt = require("@scripts/sim/prompt")
local Model = require("@scripts/ui/shell_model")
local MissionsView = require("@scripts/ui/missions_view")
local ShopView = require("@scripts/ui/shop_view")
local BranchesView = require("@scripts/ui/branches_view")
local Monitor = require("@scripts/sim/monitor")

local function has(list, v) for _, x in ipairs(list) do if x == v then return true end end return false end

-- A T4 company with the raiding branch open (cost paid), no decider: the Privateer is driven by hand.
local function raider(opts)
  opts = opts or {}
  local s = Sim.new({ seed = opts.seed })
  s:enterTier(4)
  s.lifetimeRevenue = 30000
  s.resources.credits = 100000
  s.resources.compute = 500
  assert(s:openBranch("raiding"))
  if opts.quiet then Market.quiet(s.market) end
  return s
end

-- A convoy placed by hand (the natural spawns are random).
local function plant(s, escort, dest, o)
  o = o or {}
  dest = dest or "meridian"
  s.raid.convoySeq += 1
  local c = { id = "C" .. s.raid.convoySeq, corp = o.corp or "korvax", resource = o.resource or "iridium", qty = o.qty or 200, escort = escort,
    dest = dest, from = s.home, total = s:ticks(World.freighterRoutes[s.home][dest]), elapsed = o.elapsed or 0, state = "travel" }
  s.raid.convoys[#s.raid.convoys + 1] = c
  return c
end

local function ok(s, agent, name, args)
  local good, err = s:validate(agent, { name = name, args = args or {} })
  assert(good, name .. ": " .. tostring(err))
  assert(s:apply(agent, { name = name, args = args or {} }))
end
local function refused(s, agent, name, args, why)
  local good, err = s:validate(agent, { name = name, args = args or {} })
  assert(not good and err == why, name .. ": want " .. why .. ", got " .. tostring(err))
end
local function run(s, seconds) s:run(s:ticks(seconds)) end

local function events(s, name)
  local out = {}
  for _, e in ipairs(s.events) do if e.name == name then out[#out + 1] = e.data end end
  return out
end

-- Scan, intercept (and wait for the catch-up) one planted convoy with interceptor i1 of "privateer".
local function alongside(s, agent, c)
  ok(s, agent, "scan_route", { route = c.dest })
  run(s, Cfg.interceptor.scanSeconds + 1)
  ok(s, agent, "intercept", { convoy = c.id })
  run(s, 60)
end

-- 1. nothing exists before the branch is open: no convoys, scripted rival sales as before, no streams drawn
do
  local s = Sim.new()
  assert(s.raid and #s.raid.convoys == 0 and #s.interceptorOrder == 0 and not s.agents.privateer)
  run(s, 1200)
  assert(#s.raid.convoys == 0 and s.raid.convoySeq == 0, "no convoys while the branch is closed")
  assert(s.rng.convoy == nil and s.rng.combat == nil, "the raiding streams are not touched")
  assert(#Raiding.mapConvoys(s) == 0 and #Model.map(s).rivals == 0)
  assert(Raiding.priceFactor(s, "hmc") == 1 and Raiding.notoriety(s) == 0)
  assert(#ShopView.model(s).rows == #s.b.shop.order, "no interceptor in the shop")
  assert(#MissionsView.model(s).optional == 0)
end

-- 2. opening: Tier 4, 20,000 cr, the first interceptor, the Privateer with its tools and a locked-then-active V3
do
  local s = Sim.new()
  assert(select(2, s:openBranch("raiding")) == "tier_locked")
  s:enterTier(4)
  s.resources.credits = 19999
  assert(select(2, s:openBranch("raiding")) == "not_enough_credits")
  s.resources.credits = 25000
  assert(s.raid.mission.status == "locked")
  assert(s:openBranch("raiding") and s.resources.credits == 5000, "the first interceptor costs 20,000")
  local p = s.agents.privateer
  assert(p and p.type == "privateer" and s.interceptors.i1.owner == "privateer")
  local def = s.registry.agentTypes.privateer
  assert(def.toolSlots == 7 and def.branch == "raiding" and has(def.tools, "scan_route") and has(def.tools, "run_skill"))
  local i = s.interceptors.i1
  assert(i.cap == 200 and i.hull == 80 and i.attack == 10 and i.state == "idle" and i.at == s.home)
  assert(s.raid.mission.status == "active")
  assert(s.registry.paramKinds.route.branch == "raiding" and s.registry.paramKinds.convoy_filter.branch == "raiding")
  assert(has(require("@scripts/sim/branches/registry").scopes(s), "raiding"))
  local row = BranchesView.model(s).rows[2]
  assert(row.id == "raiding" and row.state == "open" and row.agents[1] == "privateer")
end

-- 3. the interceptor ladder: #2 15,000, #3 25,000 (needs #2); each comes with an empty Privateer
do
  local s = raider()
  local rows = ShopView.model(s).rows
  local r2, r3 = rows[#rows - 1], rows[#rows]
  assert(r2.id == "interceptor2" and r2.cost == 15000 and r2.state == "available" and r2.action == "shop.buy.interceptor2")
  assert(r3.id == "interceptor3" and r3.cost == 25000 and r3.state == "locked" and r3.note == "Needs Interceptor #2")
  assert(select(2, s:buyUpgrade("interceptor3")) == "needs_interceptor2")
  s.resources.credits = 14999
  assert(select(2, s:buyUpgrade("interceptor2")) == "not_enough_credits")
  s.resources.credits = 100000
  s.lifetimeRevenue = 100000
  assert(s:buyUpgrade("interceptor2") and s.resources.credits == 85000)
  assert(#s.interceptorOrder == 2 and s.interceptors.i2.owner == "privateer2" and s.agents.privateer2.type == "privateer")
  assert(select(2, s:buyUpgrade("interceptor2")) == "already_owned")
  assert(s:buyUpgrade("interceptor3") and s.resources.credits == 60000 and s.agents.privateer3)
  assert(#ShopView.model(s).fleet >= 3)
end

-- 4. convoys: spawn from the rival sales, 70% orange, blue routes are not raidable
do
  local s = raider({ seed = 7 })
  local orange, total = 0, 0
  for _ = 1, 600 do Raiding.spawnConvoy(s, s.market) end
  for _, c in ipairs(s.raid.convoys) do
    total += 1
    if Raiding.isOrange(c.dest) then orange += 1 end
    assert(c.escort >= 0 and c.escort <= 2 and c.qty >= Cfg.convoy.qtyMin and c.qty <= Cfg.convoy.qtyMax and has(Cfg.convoy.corporations, c.corp))
  end
  assert(total == 600 and orange > 0.62 * total and orange < 0.78 * total, "about 70% orange: " .. orange .. "/" .. total)
  local s2 = raider({ seed = 3 })
  run(s2, 1500)
  assert(s2.raid.convoySeq >= 8, "the rival sales became convoys: " .. s2.raid.convoySeq)
  assert(#Model.map(s2).rivals == #Raiding.mapConvoys(s2))
  -- a blue route cannot be scanned or intercepted
  local blue
  for _, r in ipairs(Cfg.blueRoutes) do blue = r end
  assert(blue and not Raiding.isOrange(blue))
  local s3 = raider({ quiet = true })
  refused(s3, "privateer", "scan_route", { route = blue }, "bad route")
  local c = plant(s3, 0, blue)
  refused(s3, "privateer", "intercept", { convoy = c.id }, "not_raidable")
  refused(s3, "privateer", "intercept", { convoy = "C999" }, "convoy_gone")
  refused(s3, "privateer", "attack", {}, "not_intercepting")
  refused(s3, "privateer", "repair", {}, "nothing_to_repair")
end

-- 5. a scan shows bands only, the intercept reveals the truth, a convoy is catchable only early in its trip
do
  local s = raider({ quiet = true })
  local c = plant(s, 2, "meridian", { qty = 260, resource = "cobalt" })
  ok(s, "privateer", "scan_route", { route = "meridian" })
  refused(s, "privateer", "wait", { seconds = 10 }, "ship busy")
  run(s, Cfg.interceptor.scanSeconds + 1)
  local ctx = Raiding.context(s, s.agents.privateer)
  assert(#ctx.scan == 1 and ctx.scan[1].cargo == "large" and ctx.scan[1].escort == "heavy" and ctx.scan[1].resource == "cobalt" and ctx.scan[1].reach)
  assert(ctx.scan[1].qty == nil and ctx.scan[1].eta_s > 0)
  ok(s, "privateer", "intercept", { convoy = c.id })
  assert(s.interceptors.i1.state == "chasing" and s.interceptors.i1.at == "space")
  run(s, 60)
  local i = s.interceptors.i1
  assert(i.state == "alongside" and i.revealed.qty == 260 and i.revealed.escort == 2 and i.revealed.escort_power == 16)
  ok(s, "privateer", "retreat")
  assert(i.state == "idle" and i.at == "space" and i.target == nil)
  refused(s, "privateer", "repair", {}, "not_docked")
  ok(s, "privateer", "return")
  run(s, Cfg.interceptor.returnSeconds + 1)
  assert(i.at == s.home and s.raid.notoriety == 0, "a retreat is not an attack")
  local late = plant(s, 0, "meridian", { elapsed = s:ticks(250) })
  refused(s, "privateer", "intercept", { convoy = late.id }, "out_of_reach")
end

-- 6. combat: the odds, loot, damage, the hold limit, Notoriety and standing at the attack
do
  local s = raider({ quiet = true, seed = 11 })
  local c = plant(s, 1, "halcyon", { corp = "helion", qty = 300, resource = "iridium" })
  alongside(s, "privateer", c)
  ok(s, "privateer", "attack")
  assert(s.interceptors.i1.state == "fighting" and s.raid.notoriety == 1 and s.raid.standing.helion == -1 and s.raid.attacks == 1)
  s.events = {}
  run(s, Cfg.interceptor.attackSeconds + 1)
  local r = events(s, "raid_result")[1]
  assert(r and math.abs(r.chance - (0.5 + (10 - 8) / 40)) < 1e-9, "win chance = 0.5 + (attack - escort) / 40")
  local i = s.interceptors.i1
  assert(#s.raid.convoys == 0 and i.state ~= "fighting")
  if r.won then
    assert(r.loot >= math.floor(300 * 0.3) and r.loot <= math.floor(300 * 0.6) and i.cap >= Raiding.holdTotal(i), "loot is 30-60% of the cargo")
    assert(i.hull >= 80 - 20 and i.hull <= 80, "a win costs 0-20 hull")
    assert(Raiding.holdTotal(i) == r.loot)
  else
    assert(r.loot == 0 and (i.hull <= 80 - 40 or i.state == "disabled"), "a loss costs 40-80 hull")
  end
  -- the hold limits the loot
  local s2 = raider({ quiet = true, seed = 11 })
  s2.interceptors.i1.attack = 1000
  s2.interceptors.i1.hold = { cobalt = 190 }
  local big = plant(s2, 0, "meridian", { qty = 300 })
  alongside(s2, "privateer", big)
  ok(s2, "privateer", "attack")
  s2.events = {}
  run(s2, 20)
  local r2 = events(s2, "raid_result")[1]
  assert(r2.chance == 0.95)
  if r2.won then assert(Raiding.holdTotal(s2.interceptors.i1) <= 200 and r2.loot <= 10, "only the free hold is looted") end
  -- the odds at the bounds
  local s3 = raider({ quiet = true })
  s3.interceptors.i1.attack = 0
  local hard = plant(s3, 2, "meridian")
  alongside(s3, "privateer", hard)
  ok(s3, "privateer", "attack")
  s3.events = {}
  run(s3, 20)
  assert(events(s3, "raid_result")[1].chance == 0.1, "clamped to 10%")
end

-- 7. a ship that loses its hull is disabled: cargo lost, towed home, back after the repair delay; repair costs credits and time
do
  local found
  for seed = 1, 60 do
    local s = raider({ quiet = true, seed = seed })
    s.interceptors.i1.attack = 0
    s.interceptors.i1.hold = { iridium = 50 }
    local c = plant(s, 2, "meridian")
    alongside(s, "privateer", c)
    ok(s, "privateer", "attack")
    run(s, 20)
    local i = s.interceptors.i1
    if i.state == "disabled" then found = { s = s, i = i } break end
  end
  assert(found, "a loss can disable the ship")
  local s, i = found.s, found.i
  assert(i.at == s.home and i.hull == Cfg.interceptor.towedHull and Raiding.holdTotal(i) == 0)
  refused(s, "privateer", "repair", {}, "disabled")
  run(s, Cfg.interceptor.disabledSeconds + 1)
  assert(i.state == "idle")
  local before = s.resources.credits
  local missing = i.hullMax - i.hull
  ok(s, "privateer", "repair")
  assert(before - s.resources.credits == missing * 10, "10 cr per hull point")
  run(s, math.ceil(missing / 10) * 5 + 1)
  assert(i.hull == i.hullMax and i.state == "idle")
end

-- 8. the wolf pack: two interceptors on one convoy add their attack, share loot and damage; the latecomer gets convoy_gone
do
  local s = raider({ quiet = true, seed = 5 })
  s.resources.credits = 200000
  assert(s:buyUpgrade("interceptor2"))
  local c = plant(s, 2, "meridian", { qty = 300 })
  ok(s, "privateer", "scan_route", { route = "meridian" })
  ok(s, "privateer2", "scan_route", { route = "meridian" })
  run(s, 11)
  ok(s, "privateer", "intercept", { convoy = c.id })
  ok(s, "privateer2", "intercept", { convoy = c.id })
  run(s, 60)
  assert(s.interceptors.i1.state == "alongside" and s.interceptors.i2.state == "alongside")
  ok(s, "privateer", "attack")
  assert(s.interceptors.i2.state == "fighting", "the second interceptor joins the attack")
  s.events = {}
  run(s, 20)
  local r = events(s, "raid_result")[1]
  assert(r.pack == 2 and math.abs(r.chance - (0.5 + (20 - 16) / 40)) < 1e-9, "combined attack 20 against escort 16")
  assert(s.raid.attacks == 1 and s.raid.notoriety == 1, "one attack for the pack")
  if r.won then
    local a, b = Raiding.holdTotal(s.interceptors.i1), Raiding.holdTotal(s.interceptors.i2)
    assert(a + b == r.loot and math.abs(a - b) <= 1, "loot is shared")
  end
  -- a latecomer
  local s2 = raider({ quiet = true, seed = 5 })
  s2.resources.credits = 200000
  assert(s2:buyUpgrade("interceptor2"))
  local c2 = plant(s2, 0, "meridian")
  ok(s2, "privateer", "scan_route", { route = "meridian" })
  ok(s2, "privateer2", "scan_route", { route = "meridian" })
  run(s2, 11)
  ok(s2, "privateer", "intercept", { convoy = c2.id })
  run(s2, 60)
  ok(s2, "privateer", "attack")
  refused(s2, "privateer2", "intercept", { convoy = c2.id }, "convoy_gone")
end

-- 9. Notoriety: +1 per attack up to 5, -1 per 20 min without one; alerts and the price blacklist at 3
do
  local s = raider({ quiet = true, seed = 2 })
  s.interceptors.i1.attack = 1000
  s.interceptors.i1.hull, s.interceptors.i1.hullMax = 100000, 100000
  assert(s:setMonitorSettings({ scope = "company" }))
  for n = 1, 3 do
    local c = plant(s, 0, "meridian", { corp = "korvax" })
    alongside(s, "privateer", c)
    ok(s, "privateer", "attack")
    run(s, 20)
    ok(s, "privateer", "return")
    run(s, 40)
    ok(s, "privateer", "sell")
    assert(s.raid.notoriety == n)
  end
  assert(Raiding.blacklisted(s) and Raiding.priceFactor(s, "hmc") == 0.8 and Raiding.priceFactor(s, "orbis") == 0.8)
  assert(Raiding.priceFactor(s, "halcyon") == 1 and Raiding.priceFactor(s, "meridian") == 1, "only HMC and Orbis")
  run(s, 1)
  local kinds = {}
  for _, a in ipairs(s.alerts.list) do kinds[a.type or a.kind] = (kinds[a.type or a.kind] or 0) + 1 end
  assert((kinds.notoriety_high or 0) == 1, "notoriety_high is raised once")
  run(s, 30)
  assert((function() local n = 0 for _, a in ipairs(s.alerts.list) do if (a.type or a.kind) == "notoriety_high" then n += 1 end end return n end)() == 1)
  assert(s.raid.standing.korvax == -3)
  -- decay: -1 per 20 minutes without an attack, standing recovers with it
  run(s, 20 * 60)
  assert(s.raid.notoriety == 2 and not Raiding.blacklisted(s) and Raiding.priceFactor(s, "hmc") == 1)
  run(s, 20 * 60)
  assert(s.raid.notoriety == 1)
  run(s, 20 * 60)
  assert(s.raid.notoriety == 0 and s.raid.standing.korvax == 0)
  -- the cap
  s.raid.notoriety = 5
  local c = plant(s, 0, "meridian")
  alongside(s, "privateer", c)
  ok(s, "privateer", "attack")
  assert(s.raid.notoriety == 5)
end

-- 10. the blacklist applies to every HMC / Orbis sale of the company
do
  local function sale(notoriety)
    local s = raider({ quiet = true })
    s.raid.notoriety = notoriety
    s.ships.s1.cargo, s.ships.s1.ore = 80, "iridium"
    local before = s.resources.credits
    local good = s:apply("miner", { name = "sell", args = {} })
    assert(good)
    return s.resources.credits - before
  end
  local clean, dirty = sale(2), sale(3)
  assert(clean > 0 and math.abs(dirty - math.floor(clean * 0.8)) <= 1, ("HMC pays 20%% less: %d vs %d"):format(clean, dirty))
end

-- 11. retaliation: freighters on orange routes, at Notoriety >= 3, lose 30% of their cargo with 10% x Notoriety per trip
do
  local s = raider({ quiet = true, seed = 4 })
  local function trip(n, dest)
    s.raid.notoriety = n
    local f = { id = "f1", owner = nil, load = { destination = dest, resource = "iridium", qty = 100 } }
    return Raiding.retaliation(s, f), f
  end
  for _, n in ipairs({ 0, 1, 2 }) do
    for _ = 1, 50 do assert(trip(n, "meridian") == 0, "no retaliation below Notoriety 3") end
  end
  for _ = 1, 50 do assert(trip(5, "orbis") == 0, "blue routes are safe") end
  local hits = 0
  for _ = 1, 400 do
    local lost, f = trip(5, "meridian")
    if lost > 0 then hits += 1 assert(lost == 30 and f.load.qty == 70) end
  end
  assert(hits > 140 and hits < 260, "about 50% at Notoriety 5: " .. hits)
  hits = 0
  for _ = 1, 400 do if trip(3, "halcyon") > 0 then hits += 1 end end
  assert(hits > 85 and hits < 160, "about 30% at Notoriety 3: " .. hits)
  local kinds = {}
  for _, a in ipairs(s.alerts.list) do kinds[a.type or a.kind] = true end
  assert(kinds.retaliation, "a retaliation alert")
  -- a branch that is closed never retaliates
  local closed = Sim.new()
  closed.raid.notoriety = 5
  for _ = 1, 50 do assert(Raiding.retaliation(closed, { load = { destination = "meridian", resource = "iridium", qty = 100 } }) == 0) end
end

-- 12. standing: at <= -3 a corporation's convoys travel with one more escort
do
  local s = raider({ seed = 9 })
  s.market.convoyHook = nil
  s.raid.standing.korvax = -3
  for _ = 1, 300 do Raiding.spawnConvoy(s, s.market) end
  local seen, other0 = 0, 0
  for _, c in ipairs(s.raid.convoys) do
    if c.corp == "korvax" then
      seen += 1
      assert(c.escort >= 1, "hostile corporation: escort +1")
    elseif c.escort == 0 then other0 += 1 end
  end
  assert(seen > 50 and other0 > 20)
end

-- 13. mission V3: three won attacks while Notoriety stays below 3; 5,000 cr; restart after failing
do
  local s = raider({ quiet = true, seed = 6 })
  local i = s.interceptors.i1
  i.attack, i.hull, i.hullMax = 1000, 100000, 100000
  local m = Raiding.mission(s)
  assert(m.id == "V3" and m.status == "active" and m.wins == 0 and m.target == 3 and m.reward == 5000)
  local function winOne(notoriety)
    for _ = 1, 30 do
      i.hold, i.hull = {}, i.hullMax
      s.raid.notoriety = notoriety
      local c = plant(s, 0, "meridian")
      alongside(s, "privateer", c)
      local wins = s.raid.wins
      ok(s, "privateer", "attack")
      run(s, 20)
      if s.raid.wins > wins then return true end
    end
    return false
  end
  assert(winOne(0) and s.raid.mission.wins == 1)
  assert(select(2, Raiding.claimMission(s)) == "not_complete")
  assert(winOne(0) and s.raid.mission.wins == 2)
  local view = MissionsView.model(s).optional[1]
  assert(view.id == "V3" and view.progressText == "2 / 3 wins" and not view.claim, tostring(view.progressText))
  -- a win that takes Notoriety to 3 fails the mission instead of counting
  assert(winOne(2) and s.raid.notoriety == 3)
  assert(s.raid.mission.status == "active" and s.raid.mission.failed == true and s.raid.mission.wins == 2)
  view = MissionsView.model(s).optional[1]
  assert(view.retry == "missions.retry.V3" and view.failed)
  assert(select(1, MissionsView.act(s, "missions.retry.V3")) and s.raid.mission.wins == 0 and not s.raid.mission.failed)
  -- spaced attacks keep Notoriety under 3
  assert(winOne(0) and winOne(0) and winOne(0) and s.raid.mission.status == "complete")
  view = MissionsView.model(s).optional[1]
  assert(view.claim == "missions.claim.V3")
  local before = s.resources.credits
  local handled, good = MissionsView.act(s, view.claim)
  assert(handled and good and s.resources.credits - before == 5000 and s.raid.mission.status == "claimed")
  assert(select(2, Raiding.claimMission(s)) == "already_claimed")
  -- the linear missions are untouched
  assert(#s.missions == 8)
end

-- 14. the stub Privateer: "maximize profit" reaches Notoriety 3 within 30 game minutes, a constrained directive does not
do
  local function play(seed, directive)
    local s = raider({ seed = seed })
    s:setDecider(Ai.decide)
    s:setDirective("privateer", directive)
    local peak, at = 0, nil
    for t = 1, 30 * 600 do
      s:step()
      if s.raid.notoriety > peak then peak = s.raid.notoriety end
      if peak >= 3 and not at then at = t end
    end
    return peak, at, s
  end
  for seed = 1, 5 do
    local peak, at = play(seed, "maximize profit")
    assert(peak >= 3 and at <= 30 * 600, ("seed %d: maximize profit reached Notoriety %d"):format(seed, peak))
    local cpeak, _, s = play(seed, "Only attack unescorted convoys, retreat if hull below 40, notoriety below 3")
    assert(cpeak < 3, ("seed %d: constrained reached Notoriety %d"):format(seed, cpeak))
    assert(s.agents.privateer.state ~= "paused_error", "the stub never sends an invalid call")
  end
  -- the stub keeps its constraints in the attacks it makes
  local _, _, s = play(2, "Only attack unescorted convoys, retreat if hull below 40, notoriety below 3")
  for _, e in ipairs(s.feed) do
    if e.agent == "privateer" and e.tool == "attack" then
      assert(e.status ~= "failed" or e.text:find("lost"), e.text)
    end
  end
end

-- 15. skills: a Privateer skill with route and convoy_filter parameters
do
  local s = raider({ seed = 3 })
  s.skills = {}
  local skill = { name = "raid-lane", agent_type = "privateer", loop = true,
    params = { lane = { kind = "route" }, target = { kind = "convoy_filter" } },
    steps = { { tool = "scan_route", args = { route = "$lane" } }, { tool = "intercept", args = { convoy = "$target" } }, { tool = "attack" },
      { tool = "return" }, { tool = "sell" }, { tool = "repair" } } }
  assert(Skills.save(s, skill, { agent = "privateer" }))
  assert(select(2, Skills.assign(s, "privateer", "raid-lane", {})) == "bad_params")
  assert(select(2, Skills.assign(s, "privateer", "raid-lane", { lane = "orbis", target = { max_escort = 0 } })) == "bad_params", "orbis is a blue route")
  assert(select(2, Skills.assign(s, "privateer", "raid-lane", { lane = "meridian", target = { max_escort = 3 } })) == "bad_params")
  assert(select(2, Skills.assign(s, "privateer", "raid-lane", { lane = "meridian", target = { resources = { "unobtainium" } } })) == "bad_params")
  assert(Skills.assign(s, "privateer", "raid-lane", { lane = "meridian", target = { max_escort = 1 } }))
  s:setDecider(Ai.decide)
  for _ = 1, 30 * 600 do s:step() end
  assert(s.raid.attacks >= 1, "the skill raided on its own: " .. s.raid.attacks)
  assert(s.agents.privateer.mode == "skill" and s.agents.privateer.state ~= "paused_error")
  for _, e in ipairs(s.raid.convoys) do assert(e.state ~= nil) end
  -- a Monitor-scope, raiding-only agent list
  local rows = Monitor.agentRows(s)
  local found
  for _, r in ipairs(rows) do if r.id == "privateer" then found = r end end
  assert(found and found.type == "privateer" and found.at ~= nil)
end

-- 16. the Privateer's prompt shows its ship, Notoriety, scans and tools
do
  local s = raider({ quiet = true })
  local c = plant(s, 0, "meridian")
  ok(s, "privateer", "scan_route", { route = c.dest })
  run(s, 11)
  local built = Prompt.build(s, "privateer")
  local text = built.text or (built.parts and table.concat(built.parts, "\n")) or ""
  if text == "" then for _, v in pairs(built) do if type(v) == "string" then text ..= v .. "\n" end end end
  assert(text:find("privateer", 1, true) and text:find("notoriety", 1, true) and text:find("scan_route", 1, true) and text:find(c.id, 1, true), text)
end

-- 17. determinism and the save round trip (convoys, fights, interceptors, Notoriety, streams)
do
  local function play(seed, ticks, s)
    s = s or raider({ seed = seed })
    if not s.decide then
      s:setDecider(Ai.decide)
      s:setDirective("privateer", "maximize profit")
    end
    s:run(ticks)
    return s
  end
  local function digest(s)
    local out = { s.raid.notoriety, s.raid.attacks, s.raid.wins, s.raid.convoySeq, #s.raid.convoys, math.floor(s.resources.credits) }
    for _, id in ipairs(s.interceptorOrder) do
      local i = s.interceptors[id]
      out[#out + 1] = i.state .. ":" .. i.hull .. ":" .. Raiding.holdTotal(i) .. ":" .. i.at
    end
    for _, c in ipairs(s.raid.convoys) do out[#out + 1] = c.id .. c.dest .. c.elapsed .. c.escort end
    return table.concat(out, ",")
  end
  local a, b = play(8, 9000), play(8, 9000)
  assert(digest(a) == digest(b), "same seed, same raids")
  assert(digest(a) ~= digest(play(9, 9000)))
  -- save in the middle of a raid, restore, and both continue identically
  local s = play(8, 4200)
  local text = Persistence.encode(Persistence.serialize(s, 100))
  local back = assert(Persistence.restore(Persistence.decode(text)))
  assert(digest(back) == digest(s), "restored state is identical")
  assert(back.branchesOpen.raiding and back.agents.privateer and back.interceptors.i1 and back.raid.mission.status == s.raid.mission.status)
  assert(back.market.convoyHook ~= nil)
  back:setDecider(Ai.decide)
  s:run(6000)
  back:run(6000)
  assert(digest(s) == digest(back), "the restored game continues the same raids:\n" .. digest(s) .. "\n" .. digest(back))
end

-- 18. UI view-models: rival dots on the map, the Privateer in the Monitor's list
do
  local s = raider({ quiet = true })
  local c = plant(s, 1, "meridian", { elapsed = s:ticks(100) })
  local blue = plant(s, 0, "orbis")
  s.tier = 5
  local map = Model.map(s)
  assert(#map.rivals == 2)
  local dot
  for _, d in ipairs(map.rivals) do if d.id == c.id then dot = d end end
  assert(dot and dot.orange and dot.from == s.home and dot.to == "meridian" and dot.t > 0.3 and dot.t < 0.4)
  for _, d in ipairs(map.rivals) do if d.id == blue.id then assert(not d.orange) end end
end

print("raiding OK")
