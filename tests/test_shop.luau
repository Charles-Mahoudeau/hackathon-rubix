-- Run from repo root: luau tests/test_shop.luau
-- GR5-7: T2 entry, shop upgrades (fleet-wide), Scanner + scan tool, tool slots, command capacity, save round trip.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Prompt = require("@scripts/sim/prompt")
local Persistence = require("@scripts/sim/persistence")
local ShopView = require("@scripts/ui/shop_view")
local Model = require("@scripts/ui/shell_model")

local function rich(tier)
  local s = Sim.new()
  s.tier = tier or 2
  for _, a in pairs(s.agents) do a.tier = s.tier end
  s.resources.credits = 100000
  return s
end

local function buy(s, id) local ok, err = s:buyUpgrade(id) assert(ok, id .. ": " .. tostring(err)) end
local function refused(s, id, why) local ok, err = s:buyUpgrade(id) assert(not ok and err == why, id .. " should fail with " .. why .. ", got " .. tostring(err)) end

-- one K1 trip: seconds and credits earned (the spec §5.1 reference trip, 15 + 50 + 15 s and 300 cr with no upgrade)
local function trip(s, pct)
  local c0, t0 = s.resources.credits, s.tick
  assert(s:apply("miner", { name = "mine", args = { vein = "K1", stop_at_hold_pct = pct } }))
  repeat s:step() until s.ships.s1.state == "idle" or s.tick - t0 > 20000
  return (s.tick - t0) * s.b.tickSeconds, s.resources.credits - c0
end
local function near(a, b, msg) assert(math.abs(a - b) <= 0.5, ("%s: %s vs %s"):format(msg, a, b)) end

-- 1. T2 starts at 1,500 cr of lifetime revenue, and every agent follows
do
  local s = Sim.new()
  s.lifetimeRevenue = 1499
  s:run(2)
  assert(s.tier == 1, "T1 below 1,500")
  s.lifetimeRevenue = 1500
  s:run(1)
  assert(s.tier == 2 and s.agents.miner.tier == 2, "T2 at 1,500")
  s:run(5)
  assert(s.tier == 2, "no further tier from revenue")
end

-- 2. the shop is closed at T1; marks go in order; prices are the spec's
do
  local s = rich(1)
  refused(s, "drill_mk2", "tier_locked")
  s.tier = 2
  for _, a in pairs(s.agents) do a.tier = 2 end
  refused(s, "drill_mk3", "needs_drill_mk2")
  refused(s, "nope", "unknown_item")
  local before = s.resources.credits
  buy(s, "drill_mk2"); buy(s, "hold_mk2"); buy(s, "engine_mk2")
  assert(before - s.resources.credits == 1200 + 1500 + 1000, "Mk2 prices")
  buy(s, "drill_mk3"); buy(s, "hold_mk3"); buy(s, "engine_mk3"); buy(s, "scanner")
  assert(before - s.resources.credits == 1200 + 1500 + 1000 + 4000 + 5000 + 3500 + 800, "all prices")
  refused(s, "drill_mk2", "already_owned")
  local poor = Sim.new(); poor.tier = 2; poor.resources.credits = 799
  refused(poor, "scanner", "not_enough_credits")
  assert(poor.resources.credits == 799, "a refused purchase costs nothing")
end

-- 3. reference trip with each upgrade (K1: 1 jump, richness 1, titanium 10 cr, depot 0.30)
do
  local s = rich(); local t, c = trip(s, 100)
  near(t, 80, "base seconds"); assert(c == 300, "base credits")
  s = rich(); buy(s, "drill_mk2"); t, c = trip(s, 100); near(t, 15 + 100 / 3 + 15, "drill Mk2"); assert(c == 300)
  buy(s, "drill_mk3"); t, c = trip(s, 100); near(t, 15 + 20 + 15, "drill Mk3"); assert(c == 300)
  s = rich(); buy(s, "hold_mk2"); t, c = trip(s, 100); near(t, 15 + 100 + 15, "hold Mk2"); assert(c == 600, "hold Mk2 credits " .. c)
  buy(s, "hold_mk3"); t, c = trip(s, 100); near(t, 15 + 200 + 15, "hold Mk3"); assert(c == 1200, "hold Mk3 credits " .. c)
  s = rich(); buy(s, "engine_mk2"); t, c = trip(s, 100); near(t, 10.5 + 50 + 10.5, "engine Mk2"); assert(c == 300)
  buy(s, "engine_mk3"); t, c = trip(s, 100); near(t, 7.5 + 50 + 7.5, "engine Mk3"); assert(c == 300)
end

-- 4. engine marks open the planets (Lumen needs the T4 deep-range nav on top)
do
  local s = rich()
  assert(not s:inRange(s.ships.s1, "varn") and not s:inRange(s.ships.s1, "ashfall"))
  buy(s, "engine_mk2")
  assert(s:inRange(s.ships.s1, "varn") and not s:inRange(s.ships.s1, "ashfall"), "Mk2 reaches Varn")
  local lit = {}
  for _, p in ipairs(Model.map(s).planets) do lit[p.id] = p.lit end
  assert(lit.varn and not lit.ashfall, "Varn lights up on the map")
  buy(s, "engine_mk3")
  assert(s:inRange(s.ships.s1, "ashfall") and not s:inRange(s.ships.s1, "lumen"), "Mk3 reaches Ashfall, not Lumen")
end

-- 5. upgrades are fleet-wide, including ships bought later (D22); ship #2 comes with an empty Miner
do
  local s = rich()
  buy(s, "drill_mk2"); buy(s, "hold_mk2"); buy(s, "engine_mk2")
  buy(s, "ship2")
  local s2 = s.ships.s2
  assert(s2 and s2.drillRate == 3 and s2.cargoCap == 200 and s2.engineMult == 0.7 and s2.engineMark == 2, "new ship has every upgrade")
  assert(s2.owner == "miner2" and s.agents.miner2.type == "miner" and s.agents.miner2.directive == "", "empty Miner agent")
  buy(s, "drill_mk3")
  assert(s.ships.s1.drillRate == 5 and s.ships.s2.drillRate == 5, "a later upgrade reaches both ships")
  refused(s, "ship2", "already_owned")
end

-- 6. command capacity: without room the ship waits for an agent until Reputation raises the cap
do
  local s = rich()
  s:addAgent("extra", "miner")
  buy(s, "ship2")
  assert(s.ships.s2.owner == nil and s.agents.miner2 == nil, "no room, no agent")
  s:run(3)
  assert(s.ships.s2.owner == nil)
  s.lifetimeRevenue = 25000 -- Rep 1
  s:run(1)
  assert(s.ships.s2.owner == "miner2" and s.agents.miner2, "Rep 1 makes room")
end

-- 7. Scanner and the scan tool
do
  local s = rich()
  assert(not s:hasTool("miner", "scan") and #s:equippedTools("miner") == 6)
  local ok, err = s:apply("miner", { name = "scan", args = { planet = "kessa" } })
  assert(not ok and err:find("not equipped"), "scan refused without the Scanner: " .. tostring(err))
  local logged = false
  for _, l in ipairs(s.logs) do if l.level == "ERROR" and l.msg:find("rejected scan") then logged = true end end
  assert(logged, "the refusal is in the logs")
  local used0, max = s:toolSlots("miner")
  local tokens0 = Prompt.build(s, "miner").sections.tools
  buy(s, "scanner")
  local used1 = s:toolSlots("miner")
  assert(used0 == 4 and used1 == 5 and max == 5, "scan takes one of 5 slots")
  assert(Prompt.build(s, "miner").sections.tools > tokens0, "the scan schema is in every prompt")
  -- before: a band and no reserve; after the scan: exact numbers, for the rest of the game
  local function vein(planetId, id) for _, v in ipairs(s:context("miner").planets[planetId].veins) do if v.id == id then return v end end end
  assert(vein("kessa", "K4") == nil and vein("kessa", "K1").richness == nil and vein("kessa", "K1").band == "low")
  assert(s:apply("miner", { name = "scan", args = { planet = "kessa" } }))
  s:run(99)
  assert(s.ships.s1.state == "scanning", "a scan takes 10 s")
  s:run(2)
  assert(s.ships.s1.state == "idle")
  assert(vein("kessa", "K4").richness == 1.8 and vein("kessa", "K4").reserve == 4000 and vein("kessa", "K1").richness == 1.0, "exact values")
  assert(vein("varn", "V1").richness == nil, "each planet is scanned separately")
  local ok2, err2 = s:apply("miner", { name = "scan", args = { planet = "kessa" } })
  assert(not ok2 and err2 == "already_scanned")
  local _, err3 = s:apply("miner", { name = "scan", args = { planet = "varn" } })
  assert(err3 == "out_of_range", "Varn needs Engine Mk2")
  buy(s, "engine_mk2")
  local t0 = s.tick
  assert(s:apply("miner", { name = "scan", args = { planet = "varn" } }))
  repeat s:step() until s.ships.s1.state == "idle"
  near((s.tick - t0) * s.b.tickSeconds, 60 * 0.7 + 10, "scan = travel (Mk2) + 10 s")
  assert(s.ships.s1.at == "varn" and vein("varn", "V2").richness == 2.2)
end

-- 8. a precise directive uses the scan to find the richest vein (K4); without it that vein stays out of reach
do
  local directive = "Scan, then mine the richest vein."
  local function firstMine(scanner)
    local s = rich()
    if scanner then buy(s, "scanner") end
    s:setDecider(Ai.decide)
    s:setDirective("miner", directive)
    s:run(900)
    for _, e in ipairs(s.feed) do if e.kind == "call" and e.tool == "mine" then return e.text end end
  end
  local with, without = firstMine(true), firstMine(false)
  assert(with and with:find("mine(K4", 1, true), "scan then K4: " .. tostring(with))
  assert(without and not without:find("K4", 1, true), "no scan, no K4: " .. tostring(without))
end

-- 9. skill slots from the Archive, up to 3 purchases
do
  local s = rich()
  assert(s:skillSlots("miner") == 1)
  buy(s, "archive"); buy(s, "archive"); buy(s, "archive")
  assert(s:skillSlots("miner") == 4)
  refused(s, "archive", "already_owned")
  s.resources.credits = 20000
  buy(s, "warehouse")
  assert(s:skillSlots("miner") == 6, "the warehouse adds 2 skill slots")
end

-- 10. save round trip keeps upgrades, both ships and the new agent
do
  local s = rich()
  s:setDecider(Ai.decide)
  buy(s, "drill_mk2"); buy(s, "scanner"); buy(s, "archive"); buy(s, "ship2")
  s:setDirective("miner2", "Mine titanium on K1.")
  s:run(300)
  local storage = Persistence.memoryStorage()
  assert(Persistence.save(s, storage, "save.json", 0))
  local r = assert(Persistence.load(storage, "save.json"))
  r:setDecider(Ai.decide)
  assert(r.upgrades.drill == 2 and r.upgrades.scanner and r.upgrades.archive == 1 and r.upgrades.ships == 1)
  assert(#r.shipOrder == 2 and r.ships.s2.drillRate == 3 and #r.agentOrder == 2 and r.agents.miner2.directive == "Mine titanium on K1.")
  s:run(1500); r:run(1500)
  assert(r.resources.credits == s.resources.credits and r.ships.s2.cargo == s.ships.s2.cargo, "restored game == original")
end

-- 11. shop view: rows, states and the buy action
do
  local s = rich()
  s.resources.credits = 1000
  local m = ShopView.model(s)
  local by = {}
  for _, r in ipairs(m.rows) do by[r.id] = r end
  assert(#m.rows == 16 and by.drill_mk2.state == "unaffordable" and by.engine_mk2.state == "available" and by.drill_mk3.state == "locked")
  assert(by.drill_mk3.note == "Needs Drill Mk2" and by.engine_mk2.action == "shop.buy.engine_mk2" and by.engine_mk2.costText == "1000 cr")
  local handled, ok = ShopView.act(s, "shop.buy.engine_mk2")
  assert(handled and ok and s.upgrades.engine == 2 and s.resources.credits == 0)
  assert(ShopView.act(s, "nav.map") == false)
  local sig = ShopView.signature(s)
  assert(sig ~= ShopView.signature(rich()), "the signature moves with what is owned")
  local closed = ShopView.model(Sim.new())
  assert(closed.rows[1].state == "locked" and closed.rows[1].note == "Reach tier 2")
end

print("shop OK")
