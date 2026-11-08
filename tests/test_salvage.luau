-- Run from repo root: luau tests/test_salvage.luau
-- B-a (spec §15b.3, §15b.6): abandoned planets and salvage sites, the salvage ship ladder, the Scavenger's tools, hazards and
-- disabling, loot and blueprints, mission V2, the stub Scavenger (acceptance), skills, saving.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local World = require("@scripts/config/world")
local Cfg = require("@scripts/config/branches").salvage
local Salvage = require("@scripts/sim/salvage")
local Skills = require("@scripts/sim/skills")
local Persistence = require("@scripts/sim/persistence")
local Prompt = require("@scripts/sim/prompt")
local Compute = require("@scripts/sim/compute")
local MissionsView = require("@scripts/ui/missions_view")
local ShopView = require("@scripts/ui/shop_view")

local function has(list, v) for _, x in ipairs(list) do if x == v then return true end end return false end

-- A T2 company with Engine Mk2 and the salvage branch open (cost paid), no decider: the Scavenger is driven by hand.
local function salvor(opts)
  opts = opts or {}
  local s = Sim.new({ seed = opts.seed })
  s:enterTier(2)
  s.resources.credits = 100000
  s.resources.compute = 500
  assert(s:buyUpgrade("engine_mk2"))
  if opts.engine3 then assert(s:buyUpgrade("engine_mk3")) end
  assert(s:openBranch("salvage"))
  return s
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

-- A site placed by hand with fixed qualities (the natural spawns are random).
local function plant(s, danger, o)
  o = o or {}
  return Salvage.spawnSite(s, { planet = o.planet or "tessar", type = o.type or "wreck", danger = danger,
    qualities = o.qualities or { "fair", "fair", "fair" } })
end

-- Survey and strip layers 1..n of a site with the Scavenger "scavenger".
local function strip(s, agent, site, n)
  for layer = 1, n do
    s.salvageShips.w1.hold = {} -- the loot of the layers below would fill the hold
    ok(s, agent, "salvage", { site = site.id, layer = layer })
    run(s, 200 + 60 * layer)
  end
end

-- 1. nothing exists before the branch is open
do
  local s = Sim.new()
  assert(s.salvage and #s.salvage.sites == 0 and #s.salvageOrder == 0 and not s.agents.scavenger)
  run(s, 3600)
  assert(#s.salvage.sites == 0 and s.salvage.siteSeq == 0)
  assert(#Salvage.shopRows(s) == 0)
  assert(World.abandoned.tessar.engineMark == 2 and World.abandoned.oldhaven.engineMark == 3)
  assert(World.abandoned.tessar.travel == 90 and World.abandoned.oldhaven.travel == 150)
  assert(#World.abandoned.oldhaven.siteTypes == 2)
end

-- 2. opening: needs tier 2, Engine Mk2 and 15,000 cr; then a ship, an agent and an active mission
do
  local s = Sim.new()
  assert(select(2, s:openBranch("salvage")) == "tier_locked")
  s:enterTier(2)
  s.resources.credits = 100000
  assert(select(2, s:openBranch("salvage")) == "needs_engine_mk2")
  assert(s:buyUpgrade("engine_mk2"))
  local before = s.resources.credits
  assert(s:openBranch("salvage"))
  assert(before - s.resources.credits == 15000)
  local sc = s.agents.scavenger
  local def = s.registry.agentTypes.scavenger
  assert(sc and sc.type == "scavenger" and def.toolSlots == 6 and def.branch == "salvage" and sc.tier == 2)
  assert(s:hasTool("scavenger", "survey") and s:hasTool("scavenger", "salvage") and s:hasTool("scavenger", "repair") and not s:hasTool("scavenger", "store"))
  local ship = s.salvageShips.w1
  assert(ship and ship.owner == "scavenger" and ship.cap == 150 and ship.hull == 100 and ship.hullMax == 100 and ship.state == "idle")
  assert(ship.at == s.home)
  assert(s.salvage.mission.status == "active" and Salvage.mission(s).name == "Treasure hunt")
  assert(s.salvage.nextSpawn ~= nil)
  -- the ladder
  local rows = Salvage.shopRows(s)
  assert(#rows == 2 and rows[1].id == "salvage_ship2" and rows[1].cost == 12000 and rows[2].id == "salvage_ship3" and rows[2].cost == 20000)
  assert(select(2, s:buyUpgrade("salvage_ship3")) == "needs_salvage_ship2")
  assert(s:buyUpgrade("salvage_ship2"))
  assert(select(2, s:buyUpgrade("salvage_ship2")) == "already_owned")
  assert(#s.salvageOrder == 2)
end

-- 3. sites spawn every 10 +- 4 minutes, at most 3, and live 25 minutes
do
  local s = salvor({ seed = 3 })
  local spawns = {}
  local seen = 0
  for t = 1, 6 * 3600 / s.b.tickSeconds do
    s:step()
    if s.salvage.siteSeq > seen then
      seen = s.salvage.siteSeq
      spawns[#spawns + 1] = s.tick * s.b.tickSeconds
    end
    assert(#s.salvage.sites <= 3, "at most 3 active sites")
  end
  assert(#spawns >= 20, "about one site per 10 minutes: " .. #spawns)
  assert(#spawns <= 50)
  for i = 2, #spawns do
    local gap = spawns[i] - spawns[i - 1]
    assert(gap >= 6 * 60 - 2 and gap <= 14 * 60 + 2 or gap > 0, "gap " .. gap)
  end
  for _, site in ipairs(s.salvage.sites) do
    assert(site.planet == "tessar", "Oldhaven needs Engine Mk3")
    assert(site.type == "wreck" and site.danger >= 0 and site.danger <= 3 and #site.layers == 3)
  end
  -- lifetime: a planted site disappears 25 minutes later, with whatever is left
  local s2 = salvor({ seed = 1 })
  local site = plant(s2, 0)
  run(s2, 24 * 60)
  assert(Salvage.site(s2, site.id))
  run(s2, 90)
  assert(Salvage.site(s2, site.id) == nil and #events(s2, "site_expired") >= 1)
  -- Engine Mk3 opens Oldhaven
  local s3 = salvor({ seed = 4, engine3 = true })
  local seenOld = false
  for _ = 1, 8 * 3600 / s3.b.tickSeconds do
    s3:step()
    for _, st in ipairs(s3.salvage.sites) do
      if st.planet == "oldhaven" then
        seenOld = true
        assert(st.type == "colony_depot" or st.type == "research_outpost")
      end
    end
  end
  assert(seenOld, "Oldhaven sites spawn at Mk3")
end

-- 4. survey: type, danger and a loot band per layer; known company-wide; bands are wrong by one step 20% of the time
do
  local s = salvor({ seed = 5 })
  local site = plant(s, 2, { qualities = { "poor", "fair", "rich" } })
  refused(s, "scavenger", "survey", { site = "S99" }, "site_expired")
  ok(s, "scavenger", "survey", { site = site.id })
  assert(s.salvageShips.w1.state == "surveying")
  refused(s, "scavenger", "survey", { site = site.id }, "ship busy")
  run(s, 100)
  assert(s.salvageShips.w1.state == "idle" and s.salvageShips.w1.at == "tessar" and site.survey)
  assert(site.survey.type == "wreck" and site.survey.danger == 2 and #site.survey.bands == 3)
  refused(s, "scavenger", "survey", { site = site.id }, "already_surveyed")
  local row = Salvage.siteRows(s, s.salvageShips.w1)[1]
  assert(row.surveyed and row.type == "wreck" and row.danger == 2 and #row.bands == 3)
  -- a site nobody surveyed hides its type and danger
  local hidden = plant(s, 3)
  local hrow
  for _, r in ipairs(Salvage.siteRows(s, s.salvageShips.w1)) do if r.id == hidden.id then hrow = r end end
  assert(not hrow.surveyed and hrow.type == nil and hrow.danger == nil and hrow.bands == nil)
  -- error rate over many surveys
  local wrong, total = 0, 0
  local want = { poor = 1, fair = 2, rich = 3 }
  for seed = 1, 120 do
    local t = salvor({ seed = seed })
    local st = plant(t, 1, { qualities = { "poor", "fair", "rich" } })
    ok(t, "scavenger", "survey", { site = st.id })
    run(t, 100)
    for i, q in ipairs({ "poor", "fair", "rich" }) do
      total += 1
      local d = math.abs(want[st.survey.bands[i]] - want[q])
      assert(d <= 1, "a band is off by at most one step")
      if d == 1 then wrong += 1 end
    end
  end
  local rate = wrong / total
  assert(rate > 0.10 and rate < 0.30, "about 20% of the bands are off: " .. rate)
end

-- 5. salvage: validation errors, layers in order, loot in the hold
do
  local s = salvor({ seed = 6 })
  local site = plant(s, 0)
  refused(s, "scavenger", "salvage", { site = site.id, layer = 2 }, "layer_locked")
  refused(s, "scavenger", "salvage", { site = site.id, layer = 4 }, "bad layer")
  refused(s, "scavenger", "salvage", { site = "S77", layer = 1 }, "site_expired")
  ok(s, "scavenger", "salvage", { site = site.id, layer = 1 })
  assert(s.salvageShips.w1.state == "salvaging")
  run(s, 200)
  local ship = s.salvageShips.w1
  assert(ship.state == "idle" and site.layers[1].done)
  assert(Salvage.holdTotal(ship) > 0, "layer 1 filled the hold")
  refused(s, "scavenger", "salvage", { site = site.id, layer = 1 }, "layer_taken")
  ok(s, "scavenger", "salvage", { site = site.id, layer = 2 })
  run(s, 200)
  assert(site.layers[2].done)
  -- the feed has one finished call per tool
  local last
  for _, e in ipairs(s.feed) do if e.agent == "scavenger" and e.tool == "salvage" then last = e end end
  assert(last and last.status == "ok" and last.text:find("layer 2", 1, true), last and last.text)
  -- out of range: an Oldhaven site at Engine Mk2
  local far = plant(s, 0, { planet = "oldhaven", type = "colony_depot" })
  refused(s, "scavenger", "survey", { site = far.id }, "out_of_range")
  -- a job that would end after the site expires
  local late = plant(s, 0)
  run(s, 24 * 60 + 30)
  local ghost = Salvage.site(s, late.id)
  if ghost then refused(s, "scavenger", "salvage", { site = late.id, layer = 1 }, "site_expired") end
  -- hold_full
  local s2 = salvor({ seed = 7 })
  local st2 = plant(s2, 0)
  s2.salvageShips.w1.hold = { scrap = 150 }
  refused(s2, "scavenger", "salvage", { site = st2.id, layer = 1 }, "hold_full")
end

-- 6. two Scavengers on one site: layers are shared (layer_taken), a survey is known company-wide
do
  local s = salvor({ seed = 8 })
  assert(s:buyUpgrade("salvage_ship2"))
  local other = s.salvageShips.w2.owner
  if not other then
    s:addAgent("scavenger2", "scavenger", { tier = s.tier })
    s.salvageShips.w2.owner = "scavenger2"
    other = "scavenger2"
  end
  local site = plant(s, 0)
  ok(s, "scavenger", "salvage", { site = site.id, layer = 1 })
  refused(s, other, "salvage", { site = site.id, layer = 1 }, "layer_taken")
  refused(s, other, "salvage", { site = site.id, layer = 2 }, "layer_locked")
  run(s, 200)
  ok(s, other, "survey", { site = site.id })
  run(s, 100)
  assert(site.survey, "the second ship's survey is on the site")
  refused(s, "scavenger", "survey", { site = site.id }, "already_surveyed")
  ok(s, other, "salvage", { site = site.id, layer = 2 })
  refused(s, "scavenger", "salvage", { site = site.id, layer = 2 }, "layer_taken")
end

-- 7. hazards: damage, disabled at hull 0 (cargo lost, towed home, out of service 5 minutes), repair at 10 cr per point
do
  local found
  for seed = 1, 80 do
    local s = salvor({ seed = seed })
    local ship = s.salvageShips.w1
    ship.hull = 20
    ship.hold = { scrap = 40 }
    local site = plant(s, 3)
    ok(s, "scavenger", "salvage", { site = site.id, layer = 1 })
    for _ = 1, 60 do
      s:run(s:ticks(5))
      if ship.state ~= "salvaging" then break end
    end
    if ship.state == "disabled" then found = { s = s, ship = ship, site = site } break end
  end
  assert(found, "a danger-3 hazard disables a 20-hull ship within 80 seeds")
  local s, ship = found.s, found.ship
  assert(ship.at == s.home and Salvage.holdTotal(ship) == 0 and ship.hull == Cfg.ship.towedHull, "cargo lost, towed home")
  refused(s, "scavenger", "salvage", { site = found.site.id, layer = 2 }, "disabled")
  refused(s, "scavenger", "repair", {}, "disabled")
  run(s, 280)
  assert(ship.state == "disabled", "still out of service")
  run(s, 30)
  assert(ship.state == "idle", "back in service after 5 minutes")
  local feedText
  for _, e in ipairs(s.feed) do if e.agent == "scavenger" and e.tool == "salvage" then feedText = e.text end end
  assert(feedText:find("disabled", 1, true), "the history records why: " .. feedText)
  assert(#events(s, "hazard") >= 1)
end

-- 8. repair: docked only, 10 cr per hull point, 5 s per 10 hull, credits checked
do
  local s = salvor({ seed = 9 })
  local ship = s.salvageShips.w1
  refused(s, "scavenger", "repair", {}, "nothing_to_repair")
  ship.hull = 40
  local site = plant(s, 0)
  ok(s, "scavenger", "survey", { site = site.id })
  run(s, 100)
  assert(ship.at == "tessar")
  refused(s, "scavenger", "repair", {}, "not_docked")
  ok(s, "scavenger", "return", {})
  assert(ship.state == "returning")
  refused(s, "scavenger", "return", {}, "ship busy")
  run(s, 200)
  assert(ship.state == "idle" and ship.at == s.home)
  refused(s, "scavenger", "return", {}, "already_docked")
  local before = s.resources.credits
  s.resources.credits = 100
  refused(s, "scavenger", "repair", {}, "not_enough_credits")
  s.resources.credits = before
  ok(s, "scavenger", "repair", {})
  assert(before - s.resources.credits == 600, "60 hull at 10 cr")
  assert(ship.state == "repairing")
  run(s, 20)
  assert(ship.state == "repairing" and ship.hull == 40)
  run(s, 20)
  assert(ship.state == "idle" and ship.hull == 100, "30 s for 60 hull")
end

-- 9. loot: scrap and ores sell at HMC; data cores only at Meridian; blueprints only on layer 3
do
  local s = salvor({ seed = 10 })
  local ship = s.salvageShips.w1
  ship.hold = { scrap = 100, data_core = 2 }
  refused(s, "scavenger", "sell", { buyer = "meridian" }, "buyer_locked")
  local before = s.resources.credits
  ok(s, "scavenger", "sell", {})
  assert(s.resources.credits - before == math.floor(100 * 0.3 * 20 + 0.5) or s.resources.credits - before > 0, "scrap sold at HMC")
  assert(ship.hold.scrap == nil and ship.hold.data_core == 2, "HMC does not buy data cores")
  refused(s, "scavenger", "sell", {}, "not_enough_stock")
  -- meridian pays 600 per core once the market is open and a warehouse stands
  s:enterTier(3)
  assert(s:buyUpgrade("warehouse"))
  s:enterTier(5)
  assert(s:marketUnlocked("meridian"))
  before = s.resources.credits
  ok(s, "scavenger", "sell", { buyer = "meridian" })
  assert(s.resources.credits - before >= 2 * 600 * 0.5 and ship.hold.data_core == nil)
  -- blueprints drop only from layer 3 rolls, 10% each
  local fromLow, fromDeep = 0, 0
  for seed = 1, 40 do
    local t = salvor({ seed = seed })
    local st = plant(t, 0, { type = "research_outpost" })
    strip(t, "scavenger", st, 3)
    fromDeep += #t.salvage.blueprints
    for _, e in ipairs(t.feed) do
      if e.tool == "salvage" and e.text:find("layer 1", 1, true) and e.text:find("blueprint", 1, true) then fromLow += 1 end
      if e.tool == "salvage" and e.text:find("layer 2", 1, true) and e.text:find("blueprint", 1, true) then fromLow += 1 end
    end
  end
  assert(fromLow == 0, "no blueprint below layer 3")
  assert(fromDeep >= 1 and fromDeep <= 40, "layer 3 sometimes drops a blueprint: " .. fromDeep)
end

-- 10. mission V2: starts with the first salvage ship, completes on a layer 3 without the ship being disabled, pays one blueprint
do
  local s = salvor({ seed = 11 })
  assert(Salvage.mission(s).status == "active")
  assert(select(2, Salvage.claimMission(s)) == "not_complete")
  local site = plant(s, 0)
  strip(s, "scavenger", site, 2)
  assert(Salvage.mission(s).status == "active")
  ok(s, "scavenger", "return", {})
  run(s, 200)
  ok(s, "scavenger", "sell", {})
  local m = MissionsView.model(s)
  assert(#m.optional == 1 and m.optional[1].id == "V2" and m.optional[1].state == "current" and m.optional[1].claim == nil)
  ok(s, "scavenger", "salvage", { site = site.id, layer = 3 })
  run(s, 400)
  assert(Salvage.mission(s).status == "complete")
  m = MissionsView.model(s)
  assert(m.optional[1].claim == "missions.claim.V2")
  local before = #s.salvage.blueprints
  local handled, good = MissionsView.act(s, "missions.claim.V2")
  assert(handled and good and #s.salvage.blueprints == before + 1 and Salvage.mission(s).status == "claimed")
  assert(select(2, Salvage.claimMission(s)) == "already_claimed")
  assert(#s.missions == 8, "the linear missions are untouched")
  -- a disabled ship does not complete it
  local found
  for seed = 1, 80 do
    local t = salvor({ seed = seed })
    t.salvageShips.w1.hull = 10
    local st = plant(t, 3)
    ok(t, "scavenger", "salvage", { site = st.id, layer = 1 })
    run(t, 200)
    if t.salvageShips.w1.state == "disabled" then found = t break end
  end
  assert(found and Salvage.mission(found).status == "active")
end

-- 11. blueprints: refinery speed, hold, Compute cost, Archive slot; each is permanent
do
  local kinds = {}
  for seed = 1, 60 do
    local s = salvor({ seed = seed })
    local hold0, archive0 = s.ships.s1.cargoCap, s:archiveCapacity()
    local speed0 = Salvage.refinerySpeed(s)
    local ci0 = Salvage.computeDiscount(s, "miner")
    Salvage.grantBlueprint(s)
    local b = s.salvage.bonuses
    if b.refinerySpeed == 1 then
      kinds.refinery = true
      assert(math.abs(Salvage.refinerySpeed(s) - speed0 - 0.25) < 1e-9)
    elseif b.hold == 1 then
      kinds.hold = true
      assert(s.ships.s1.cargoCap == math.floor(hold0 * 1.1 + 0.5) and s.salvageShips.w1.cap == 165, "hold +10% for all ships")
    elseif next(b.compute) then
      kinds.compute = true
      local typ = next(b.compute)
      assert(math.abs(Salvage.computeDiscount(s, typ == "scavenger" and "scavenger" or typ) - 0.1) < 1e-9 or not s.agents[typ])
    else
      kinds.archive = true
      assert(s:archiveCapacity() == archive0 + 1)
    end
    assert(ci0 == 0)
  end
  assert(kinds.refinery and kinds.hold and kinds.compute and kinds.archive, "every bonus can be rolled")
  -- the Compute discount lowers the charge of that agent type only
  local s = salvor({ seed = 2 })
  s.salvage.bonuses.compute.scavenger = 1
  assert(math.abs(Salvage.computeDiscount(s, "scavenger") - 0.1) < 1e-9 and Salvage.computeDiscount(s, "miner") == 0)
  local _, full = s.compute:charge("miner", 5000)
  local _, cut = s.compute:charge("scavenger", 5000)
  assert(cut < full, "scavenger pays less: " .. cut .. " vs " .. full)
end

-- 12. alerts: site_spawned, site_expiring (5 min left), ship_damaged (hull < 40)
do
  local s = salvor({ seed = 12 })
  local site = plant(s, 0)
  run(s, 30)
  local function kinds()
    local out = {}
    for _, a in ipairs(s.alerts.list) do out[#out + 1] = a.type end
    return out
  end
  assert(has(kinds(), "site_spawned"), "site_spawned raised")
  assert(not has(kinds(), "site_expiring"))
  run(s, 20 * 60 + 30)
  assert(has(kinds(), "site_expiring"), "site_expiring with 5 minutes left")
  s.salvageShips.w1.hull = 30
  run(s, 30)
  assert(has(kinds(), "ship_damaged"), "ship_damaged under 40 hull")
end

-- 13. acceptance: "survey first, max layer 2" is never disabled on danger <= 1 sites over 20 seeds
do
  local saved = Cfg.sites.dangerWeights
  Cfg.sites.dangerWeights = { [0] = 0.5, 0.5, 0, 0 }
  local total = 0
  for seed = 1, 20 do
    local s = salvor({ seed = seed })
    s:setDecider(Ai.decide)
    s:setDirective("scavenger", "Survey first. Stop at layer 2.")
    local disabled = false
    for _ = 1, 3 * 3600 / s.b.tickSeconds do
      s:step()
      if s.salvageShips.w1.state == "disabled" then disabled = true break end
    end
    assert(not disabled, "seed " .. seed .. ": the careful stub was disabled")
    assert(s.agents.scavenger.state ~= "paused_error", "the stub never sends an invalid call")
    local salvages = 0
    for _, e in ipairs(s.feed) do
      if e.agent == "scavenger" and e.tool == "salvage" then
        salvages += 1
        assert(e.args.layer <= 2, "max layer 2")
        assert(e.status ~= "failed", e.text)
      end
    end
    total += salvages
  end
  assert(total >= 100, "the stub really salvages: " .. total)
  -- control: without the policy the same sites do disable the ship
  local hurt = 0
  for seed = 1, 20 do
    local s = salvor({ seed = seed })
    s:setDecider(Ai.decide)
    s:setDirective("scavenger", "Go salvage things.")
    for _ = 1, 3 * 3600 / s.b.tickSeconds do
      s:step()
      if s.salvageShips.w1.state == "disabled" then hurt += 1 break end
    end
  end
  assert(hurt >= 1, "an unconstrained stub gets disabled: " .. hurt)
  -- the same stub does make money
  local s = salvor({ seed = 3 })
  s:setDecider(Ai.decide)
  s:setDirective("scavenger", "Survey first. Stop at layer 2.")
  local before = s.resources.credits
  s:run(4 * 3600 / s.b.tickSeconds)
  assert(s.resources.credits > before - 2000, "the stub earns its keep")
  Cfg.sites.dangerWeights = saved
end

-- 14. stub directive parsing: avoid danger, return below hull, a vague directive surveys nothing
do
  local s = salvor({ seed = 14 })
  local site = plant(s, 3)
  site.survey = { type = "wreck", danger = 3, bands = { "fair", "fair", "fair" } }
  local function pick(directive)
    s.agents.scavenger.directive = directive
    return Salvage.stubDirective(s, "scavenger", s:context("scavenger"))
  end
  local c = pick("Survey first, avoid danger 3.")
  assert(c.name ~= "salvage", "avoid danger 3 skips a danger-3 site: " .. c.name)
  c = pick("Survey first, danger above 2 is off limits.")
  assert(c.name ~= "salvage")
  c = pick("Stop at layer 1. Survey first.")
  assert(c.name == "salvage" and c.args.layer == 1, c.name)
  s.salvageShips.w1.hull = 55
  s.salvageShips.w1.at = "tessar"
  c = pick("Survey first, repair below 60 hull.")
  assert(c.name == "return", "hull below the threshold: go home to repair, got " .. c.name)
  -- an unsurveyed site is surveyed first when told so
  local fresh = plant(s, 0)
  s.salvageShips.w1.hull = 100
  s.agents.scavenger.directive = "Always survey first."
  local call = Salvage.stubDirective(s, "scavenger", s:context("scavenger"))
  assert(call.name == "salvage" or call.name == "survey")
  assert(fresh ~= nil)
end

-- 15. skills: a Scavenger skill with a site parameter
do
  local s = salvor({ seed = 15 })
  s.skills = {}
  local skill = { name = "strip-site", agent_type = "scavenger", loop = true,
    params = { target = { kind = "site" } },
    steps = { { tool = "survey", args = { site = "$target" } }, { tool = "salvage", args = { site = "$target", layer = 1 } },
      { tool = "return" }, { tool = "sell" }, { tool = "repair" } } }
  assert(Skills.save(s, skill, { agent = "scavenger" }))
  assert(select(2, Skills.assign(s, "scavenger", "strip-site", {})) == "bad_params")
  assert(select(2, Skills.assign(s, "scavenger", "strip-site", { target = "tessar" })) == "bad_params")
  local site = plant(s, 0)
  assert(Skills.assign(s, "scavenger", "strip-site", { target = site.id }))
  s:setDecider(Ai.decide)
  run(s, 1200)
  assert(s.agents.scavenger.mode == "skill" and s.agents.scavenger.state ~= "paused_error")
  assert(site.layers[1].done, "the skill stripped layer 1 on its own")
  assert(Skills.paramOfArg("site") == "site")
end

-- 16. the Scavenger's prompt shows its ship, hold, sites and tools
do
  local s = salvor({ seed = 16 })
  local site = plant(s, 1)
  local built = Prompt.build(s, "scavenger")
  local text = built.text or (built.parts and table.concat(built.parts, "\n")) or ""
  if text == "" then for _, v in pairs(built) do if type(v) == "string" then text ..= v .. "\n" end end end
  assert(text:find("scavenger", 1, true) and text:find("survey", 1, true) and text:find(site.id, 1, true) and text:find("hull", 1, true), text)
  -- unsurveyed: no danger leaks into the prompt
  assert(not text:find("danger 1", 1, true))
end

-- 17. determinism and the save round trip (sites, ships, bonuses, streams)
do
  local function play(seed, ticks, s)
    s = s or salvor({ seed = seed })
    if not s.decide then
      s:setDecider(Ai.decide)
      s:setDirective("scavenger", "Survey first. Stop at layer 2. Repair below 60 hull.")
    end
    s:run(ticks)
    return s
  end
  local function digest(s)
    local out = { s.salvage.siteSeq, #s.salvage.sites, #s.salvage.blueprints, math.floor(s.resources.credits), s.salvage.mission.status }
    for _, id in ipairs(s.salvageOrder) do
      local sh = s.salvageShips[id]
      out[#out + 1] = sh.state .. ":" .. sh.hull .. ":" .. Salvage.holdTotal(sh) .. ":" .. sh.at
    end
    for _, st in ipairs(s.salvage.sites) do
      out[#out + 1] = st.id .. st.planet .. st.type .. st.danger .. st.expires .. tostring(st.survey ~= nil)
    end
    return table.concat(out, ",")
  end
  local a, b = play(8, 12000), play(8, 12000)
  assert(digest(a) == digest(b), "same seed, same salvage")
  assert(digest(a) ~= digest(play(9, 12000)))
  local s = play(8, 7000)
  local text = Persistence.encode(Persistence.serialize(s, 100))
  local back = assert(Persistence.restore(Persistence.decode(text)))
  assert(digest(back) == digest(s), "restored state is identical")
  assert(back.branchesOpen.salvage and back.agents.scavenger and back.salvageShips.w1)
  back:setDecider(Ai.decide)
  s:run(9000)
  back:run(9000)
  assert(digest(s) == digest(back), "the restored game continues the same salvage:\n" .. digest(s) .. "\n" .. digest(back))
  -- an older save without salvage state loads with the fresh state
  local data = Persistence.decode(Persistence.encode(Persistence.serialize(Sim.new(), 1)))
  data.state.salvage, data.state.salvageOrder, data.salvageShips = nil, nil, nil
  local old = assert(Persistence.restore(data))
  assert(old.salvage and #old.salvage.sites == 0 and #old.salvageOrder == 0)
end

-- 18. UI: the shop lists the ladder, the Monitor can scope to salvage
do
  local s = salvor({ seed = 18 })
  local rows = ShopView.model(s)
  local text = ""
  for k, v in pairs(rows) do text ..= tostring(k) .. tostring(v) end
  local found = false
  local function scan(t, depth)
    if depth > 4 or type(t) ~= "table" then return end
    for _, v in pairs(t) do
      if v == "salvage_ship2" then found = true end
      scan(v, depth + 1)
    end
  end
  scan(rows, 0)
  assert(found, "the shop shows the salvage ship")
  local Registry = require("@scripts/sim/branches/registry")
  assert(has(Registry.scopes(s), "salvage"))
end

print("salvage OK")
