-- Run from repo root: luau tests/test_logistics.luau
-- GR5-12: Reputation + command capacity, logistics hub gating, freighters, hangars, outposts, Logisticians, messages,
-- fleet-wide upgrades, the Fleet view and the save round trip.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Market = require("@scripts/sim/market")
local Persistence = require("@scripts/sim/persistence")
local FleetView = require("@scripts/ui/fleet_view")
local Model = require("@scripts/ui/shell_model")
local Shell = require("@scripts/ui/shell")

local function fail(s, id, why) local ok, err = s:buyUpgrade(id) assert(not ok and err == why, id .. ": want " .. why .. ", got " .. tostring(err)) end

-- A T3 game with the warehouse and Rep 1; the hub is not bought yet.
local function ready(noisy)
  local s = Sim.new()
  s:enterTier(3)
  s.lifetimeRevenue = 30000
  s.resources.credits = 200000
  assert(s:buyUpgrade("warehouse"))
  if not noisy then Market.quiet(s.market) end -- quiet pins event timers at inf, which a save cannot hold
  return s
end
local function reach(s) assert(s:buyUpgrade("engine_mk2") and s:buyUpgrade("engine_mk3")) end
local function withHub(noisy)
  local s = ready(noisy)
  assert(s:buyUpgrade("logistics_hub"))
  return s
end

-- 1. Reputation levels and command capacity (D17)
do
  local s = Sim.new()
  local want = { [0] = 2, 5, 8, 12, 16, 16 }
  local levels = s.b.reputationLevels
  for lvl = 0, 5 do
    s.lifetimeRevenue = lvl == 0 and 0 or levels[lvl]
    assert(s:reputationLevel() == lvl and s:commandCapacity() == want[lvl], "rep " .. lvl)
  end
  s.lifetimeRevenue = levels[1] - 1
  assert(s:reputationLevel() == 0)
  local v = FleetView.model(s).reputation
  assert(v.level == 0 and v.next == 25000 and v.percent == 99 and v.capacity == 2 and v.used == 1, "reputation bar")
end

-- 2. The hub needs the Warehouse and Rep 1; nothing logistic exists before it
do
  local s = Sim.new()
  s:enterTier(3)
  s.resources.credits = 100000
  fail(s, "logistics_hub", "needs_warehouse")
  assert(s:buyUpgrade("warehouse"))
  fail(s, "logistics_hub", "reputation_1")
  s.lifetimeRevenue = 25000
  s.resources.credits = 19999
  fail(s, "logistics_hub", "not_enough_credits")
  s.resources.credits = 20000
  s.tier = 3
  assert(s.upgrades.hub == false)
  local ok, err = s:buyFreighter("kessa"); assert(not ok and err == "hub_locked", "no freighter before the hub")
  ok, err = s:hireLogistician("kessa"); assert(not ok and err == "hub_locked", "no Logistician before the hub")
  ok, err = s:buyHangar("kessa"); assert(not ok and err == "hub_locked")
  assert(not s.agents.logistician and #s.agentOrder == 1, "only the Miner at the start")
  local m = FleetView.model(s)
  assert(m.hubOpen == false and #m.stations == 1 and m.stations[1].idleText == "Idle: Build the logistics hub first")
  assert(s:buyUpgrade("logistics_hub"))
  assert(s.upgrades.hub and s.tier == 4 and s.resources.credits == 0, "hub: 20,000 cr, enters T4")
end

-- 3. Freighters: 6,000 cr, 2 per station, +2 per hangar extension (8,000 cr)
do
  local s = withHub()
  s.resources.credits = 100000
  local c0 = s.resources.credits
  assert(s:buyFreighter("kessa") and s.resources.credits == c0 - 6000)
  assert(s:buyFreighter("kessa"))
  local ok, err = s:buyFreighter("kessa"); assert(not ok and err == "hangar_full")
  assert(s:buyHangar("kessa") and s.resources.credits == c0 - 12000 - 8000)
  assert(s:buyFreighter("kessa") and s:buyFreighter("kessa"))
  ok, err = s:buyFreighter("kessa"); assert(not ok and err == "hangar_full")
  assert(s.stations.kessa.hangar == 1 and #s.freighters == 4)
  s.resources.credits = 5999
  s.stations.kessa.hangar = 2
  ok, err = s:buyFreighter("kessa"); assert(not ok and err == "not_enough_credits")
  ok, err = s:buyFreighter("nowhere"); assert(not ok and err == "unknown_station")
end

-- 4. A convoy: the dot moves, credits and an inbox message arrive on delivery
do
  local s = withHub()
    assert(s:hireLogistician("kessa"))
  assert(s:buyFreighter("kessa"))
  s.warehouse.cobalt = 500
  local ok, r = s:apply("logistician", { name = "ship", args = { resource = "cobalt", qty = 500, destination = "halcyon" } })
  assert(ok and r.eta_s == 240 and s.warehouse.cobalt == 0)
  s:run(s:ticks(120))
  local convoys = Model.map(s).convoys
  assert(#convoys == 1 and convoys[1].from == "kessa" and convoys[1].to == "halcyon" and convoys[1].t > 0.3 and convoys[1].t < 0.7, "convoy dot")
  local c0, inbox0 = s.resources.credits, #s.agents.logistician.inbox
  s:run(s:ticks(120) + 2)
  assert(math.abs(s.resources.credits - c0 - 500 * 24 * 1.2) <= 2, "credits arrive on delivery")
  assert(#s.agents.logistician.inbox == inbox0 + 1 and s.agents.logistician.inbox[#s.agents.logistician.inbox]:find("F1 delivered", 1, true), "delivery message")
  assert(#Model.map(s).convoys == 0, "freighter returns empty")
  s:run(s:ticks(240) + 2)
  assert(s.freighters[1].state == "idle")
end

-- 5. Two Logisticians on one station reproduce the §8.6 conflicts through the real stub pipeline
do
  local s = withHub()
  assert(s:hireLogistician("kessa") and s:hireLogistician("kessa"))
  local ok, err = s:hireLogistician("kessa"); assert(not ok and err == "station_full", "2 Logisticians per station")
  assert(s.agents.logistician_2 and s.agents.logistician_2.station == "kessa")
  assert(s:buyFreighter("kessa") and s:buyFreighter("kessa"))
  s.warehouse.cobalt = 500
  assert(s:apply("logistician", { name = "ship", args = { resource = "cobalt", qty = 500, destination = "halcyon" } }))
  local ok1, e1 = s:apply("logistician_2", { name = "ship", args = { resource = "cobalt", qty = 500, destination = "halcyon" } })
  assert(not ok1 and e1 == "not_enough_stock")
  assert(s:apply("logistician_2", { name = "ship", args = { resource = "cobalt", qty = 1, destination = "halcyon" }}) == false)
  s.warehouse.titanium = 300
  assert(s:apply("logistician", { name = "ship", args = { resource = "titanium", qty = 100, destination = "halcyon" } }))
  local ok2, e2 = s:apply("logistician_2", { name = "ship", args = { resource = "titanium", qty = 100, destination = "halcyon" } })
  assert(not ok2 and e2 == "no_free_freighter")
  local ok3, e3 = s:apply("logistician_2", { name = "ship", args = { resource = "cobalt", qty = 1, destination = "meridian" } })
  assert(not ok3 and (e3 == "not_bought_here" or e3 == "not_enough_stock"))
end

-- 6. The stub Logistician acts from the directive, waits with nothing to do, and the cooldown spaces its calls
do
  local s = withHub()
  assert(s:hireLogistician("kessa") and s:buyFreighter("kessa"))
  s:setDecider(Ai.decide)
  s:setDirective("logistician", "Ship cobalt to Halcyon.")
  s.warehouse.cobalt = 500
  s:run(40)
  local sent = false
  for _, f in ipairs(s.freighters) do if f.state ~= "idle" then sent = true end end
  assert(sent and s.warehouse.cobalt == 0, "the stub ships cobalt from the directive")
  local before = #s.agents.logistician.history
  s:run(30)
  assert(#s.agents.logistician.history - before <= 4, "cooldown between calls")
end

-- 7. Outposts: 12,000 cr, own stock, own freighters, Logisticians; not on Kessa; out of range without the engine
do
  local s = withHub()
  s.resources.credits = 100000
  local ok, err = s:buildOutpost("kessa"); assert(not ok and err == "home_planet")
  ok, err = s:buildOutpost("varn"); assert(not ok and err == "out_of_range", "needs the engine: " .. tostring(err))
  assert(s:buyUpgrade("engine_mk2") and s:buyUpgrade("engine_mk3"))
  ok, err = s:buildOutpost("lumen"); assert(not ok and err == "out_of_range", "needs deep range: " .. tostring(err))
  local c0 = s.resources.credits
  assert(s:buildOutpost("varn") and s.resources.credits == c0 - 12000)
  ok, err = s:buildOutpost("varn"); assert(not ok and err == "already_built")
  local st = s.stations.varn
  assert(st.kind == "outpost" and st.stock ~= s.warehouse and s.stations.kessa.stock == s.warehouse, "own stock")
  assert(s:buyFreighter("varn") and s:buyFreighter("varn"))
  ok, err = s:buyFreighter("varn"); assert(not ok and err == "hangar_full", "2 freighters at an outpost")
  assert(s:hireLogistician("varn") and s.agents.logistician.station == "varn")
  s.warehouse.cobalt = 100
  st.stock.cobalt = 400
  local c = s:context("logistician")
  assert(c.station.kind == "outpost" and c.stock.cobalt == 400, "context shows the outpost stock")
  local good, r = s:apply("logistician", { name = "ship", args = { resource = "cobalt", qty = 400, destination = "halcyon" } })
  assert(good and r.eta_s == 200 and st.stock.cobalt == 0, "ships from the outpost stock, Varn route 200 s: " .. tostring(r))
  local bad, why = s:apply("logistician", { name = "ship", args = { resource = "cobalt", qty = 100, destination = "halcyon" } })
  assert(not bad and why == "not_enough_stock", "the warehouse stock is not the outpost's: " .. tostring(why))
  assert(s.warehouse.cobalt == 100, "main stock untouched")
  local Logistics = require("@scripts/sim/logistics")
  st.stock.titanium = 300
  assert(Logistics.room(s, st) == 1000 - Logistics.used(st) and Logistics.storageCap(s, st) == 1000, "outpost storage 1,000")
  -- routes and convoys on the map
  local map = Model.map(s)
  local n = 0
  for _, rt in ipairs(map.routes) do if rt.from == "varn" then n += 1 end end
  assert(n == 3, "outpost routes")
end

-- 8. Command capacity is enforced and the UI says why
do
  local s = withHub()
  assert(s:commandCapacity() == 5)
  assert(s:hireLogistician("kessa") and s:hireLogistician("kessa"))
  assert(s:buyUpgrade("engine_mk2") and s:buyUpgrade("engine_mk3"))
  assert(s:buildOutpost("varn"))
  assert(s:hireLogistician("varn"))
  assert(s:buyUpgrade("ship2"), "second ship takes a command slot")
  assert(#s.agentOrder == 5)
  local ok, err = s:hireLogistician("varn"); assert(not ok and err == "station_full" or err == "command_capacity")
  assert(s:buildOutpost("ashfall"))
  ok, err = s:hireLogistician("ashfall")
  assert(not ok and err == "command_capacity", "capacity: " .. tostring(err))
  local m = FleetView.model(s)
  for _, st in ipairs(m.stations) do if st.id == "ashfall" then assert(st.idleText:find("Command capacity", 1, true), st.idleText) end end
  assert(m.reputation.used == 5 and m.reputation.capacity == 5)
  s.lifetimeRevenue = 80000
  assert(s:hireLogistician("ashfall"), "Rep 2 raises capacity")
end

-- 9. A ship without an agent idles, and the UI says why
do
  local s = withHub()
  assert(s:buyUpgrade("ship2"))
  s.agents.miner2 = nil
  for i, id in ipairs(s.agentOrder) do if id == "miner2" then table.remove(s.agentOrder, i) break end end
  s.ships.s2.owner = nil
  local m = FleetView.model(s)
  assert(m.ships[2].text:find("Idle", 1, true), m.ships[2].text)
end

-- 10. report(message, to) lands in the recipient's inbox
do
  local s = withHub()
  assert(s:hireLogistician("kessa"))
  local ok = s:apply("miner", { name = "report", args = { message = "titanium low", to = "logistician" } })
  assert(ok and s.agents.logistician.inbox[#s.agents.logistician.inbox]:find("titanium low", 1, true))
  local bad, err = s:apply("miner", { name = "report", args = { message = "x", to = "ghost" } })
  assert(not bad and err == "unknown_recipient")
end

-- 11. The Logistician context (§9.2.3): station, stock, freighters, others_here, no market tool
do
  local s = withHub()
  assert(s:hireLogistician("kessa") and s:hireLogistician("kessa") and s:buyFreighter("kessa"))
  assert(not s.agents.logistician.tools.read_market)
  local c = s:context("logistician")
  assert(c.station.id == "kessa" and c.stock.cobalt ~= nil and #c.freighters == 1, "station, stock, freighters")
  assert(c.others_here and #c.others_here == 1 and c.others_here[1] == "logistician_2", "others_here lists the other Logistician")
  assert(c.markets and #c.markets >= 1)
end

-- 12. Fleet-wide upgrades reach ships bought after them, and a ship bought at #3 gets them
do
  local s = withHub()
  assert(s:buyUpgrade("drill_mk2"))
  assert(s:buyUpgrade("ship2"))
  assert(s.ships.s2.drillRate == s.ships.s1.drillRate, "fleet-wide drill")
  assert(s:buyUpgrade("ship3"), "ship #3 at 15,000 cr")
  assert(s.ships.s3.drillRate == s.ships.s1.drillRate)
  assert(s:commandCapacity() >= #s.agentOrder)
end

-- 13. Save round trip keeps stations, outposts, freighters, hangars, Logisticians
do
  local s = withHub(true)
  s.resources.credits = 100000
  reach(s)
  assert(s:buildOutpost("varn") and s:buyFreighter("varn") and s:buyFreighter("kessa") and s:buyHangar("kessa"))
  assert(s:hireLogistician("kessa") and s:hireLogistician("varn"))
  s.stations.varn.stock.titanium = 123
  s.warehouse.cobalt = 400
  s:apply("logistician", { name = "ship", args = { resource = "cobalt", qty = 400, destination = "halcyon" } })
  s:run(50)
  local storage = Persistence.memoryStorage()
  assert(Persistence.save(s, storage, "save.json", 0))
  local r = assert(Persistence.load(storage, "save.json"))
  assert(r.stations.varn.kind == "outpost" and r.stations.varn.stock.titanium == 123 and r.stations.kessa.hangar == 1)
  assert(r.stations.kessa.stock == r.warehouse and r.warehouse.cobalt == s.warehouse.cobalt)
  assert(#r.freighters == #s.freighters and r.agents.logistician.station == "kessa" and r.agents.logistician_2.station == "varn")
  s:run(600); r:run(600)
  assert(r.resources.credits == s.resources.credits, "restored game == original")
end

-- 14. Fleet view: actions run the sim, the Fleet screen renders at T4 with the hub open
do
  local s = withHub()
  s.resources.credits = 100000
  reach(s)
  local m = FleetView.model(s)
  assert(m.hubOpen and m.stations[1].canFreighter and m.stations[1].canHire and #m.outposts == 3)
  local handled, ok = FleetView.act(s, "fleet.freighter.kessa")
  assert(handled and ok and #s.freighters == 1)
  handled, ok = FleetView.act(s, "fleet.hire.kessa")
  assert(handled and ok and s.agents.logistician)
  handled, ok = FleetView.act(s, "fleet.outpost.varn")
  assert(handled and ok and s.stations.varn)
  assert(FleetView.act(s, "shop.buy.x") == false)
  assert(FleetView.signature(s) ~= "")
  local spec = Shell.spec(s, "fleet", {})
  assert(spec ~= nil)
end

print("logistics OK")
