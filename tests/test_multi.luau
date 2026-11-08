-- Run from repo root: luau tests/test_multi.luau
-- GR5-28 (M7b, spec §8.6, §15 missions 6-7): several Miners and Logisticians, crowding, parameterized skills on 3 ships,
-- the team view, command capacity and missions 6 and 7.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Skills = require("@scripts/sim/skills")
local Market = require("@scripts/sim/market")
local Missions = require("@scripts/sim/missions")
local MissionsView = require("@scripts/ui/missions_view")
local TeamView = require("@scripts/ui/team_view")
local Persistence = require("@scripts/sim/persistence")
local Shell = require("@scripts/ui/shell")
local Screens = require("@scripts/config/screens")

local function status(s, i) return s.missions[i].status end
local function skipTo(s, n) -- missions 1..n-1 are claimed
  for i = 1, n - 1 do s.missions[i].status = "claimed" end
  Missions.update(s)
end
local function ore(skill) return { name = skill, agent_type = "miner", loop = true, params = { vein = { kind = "vein" } },
  steps = { { tool = "mine", args = { vein = "$vein" } }, { tool = "return" }, { tool = "sell" } } } end

-- A T4 company: hub open, Reputation high enough for 8 agents, `ships` mining ships with their Miners.
local function company(ships)
  local s = Sim.new()
  s:enterTier(3)
  s.lifetimeRevenue = 80000
  s.resources.credits = 500000
  Market.quiet(s.market)
  assert(s:buyUpgrade("warehouse") and s:buyUpgrade("logistics_hub"))
  s.upgrades.archive = 3
  assert(Skills.save(s, ore("ore-run")))
  for i = 2, ships do assert(s:buyUpgrade("ship" .. i), "ship" .. i) end
  return s
end

-- 1. fleet: ships #2-#4 need their tier and credits, each brings an empty Miner while command capacity allows
do
  local s = Sim.new()
  s.resources.credits = 100000
  assert(select(2, s:buyUpgrade("ship2")) == "tier_locked")
  s:enterTier(2)
  assert(s:buyUpgrade("ship2") and #s.shipOrder == 2 and s.ships.s2.owner == "miner2" and s.agents.miner2.directive == "")
  assert(select(2, s:buyUpgrade("ship3")) == "tier_locked")
  local s4 = company(4)
  assert(#s4.shipOrder == 4 and #s4.agentOrder == 4, "4 ships, 4 Miners")
  for _, id in ipairs(s4.shipOrder) do assert(s4.ships[id].owner and s4.ships[id].drillRate == s4.ships.s1.drillRate, "fleet-wide upgrades apply") end
  assert(select(2, s4:buyUpgrade("ship4")) == "already_owned" or select(2, s4:buyUpgrade("ship4")) ~= nil)
end

-- 2. two Miners on one vein mine at 0.67x each and the cause is named
do
  local s = company(2)
  s:setDirective("miner", "x"); s:setDirective("miner2", "x")
  assert(s:apply("miner", { name = "mine", args = { vein = "K1" } }) and s:apply("miner2", { name = "mine", args = { vein = "K1" } }))
  s:run(s:ticks(60) + 120)
  local a, b = s.ships.s1, s.ships.s2
  assert(a.state == "mining" and b.state == "mining")
  assert(a.crowdedBy[1] == "miner2" and b.crowdedBy[1] == "miner", "crowded_by")
  local rate = a.drillRate * s.veins.K1.richness * 1.0 * (1 / 1.5)
  assert(math.abs(a.cargoF - b.cargoF) < 1e-6 and a.cargoF > 0)
  assert(rate < a.drillRate * s.veins.K1.richness and math.abs(s:crowdingFor(2) - 2 / 3) < 1e-9)
end

-- 3. one parameterized skill runs on 3 Miners with 3 different veins
do
  local s = company(3)
  local veins = { miner = "K1", miner2 = "K3", miner3 = "K4" }
  s:run(1)
  for id, v in pairs(veins) do
    if v == "K4" then s.veins.K4.hidden = false; s.veins.K4.scanned = true end
    assert(Skills.assign(s, id, "ore-run", { vein = v }), id)
  end
  assert(select(2, Skills.assign(s, "miner", "ore-run", {})) == "bad_params")
  local used = {}
  local compute = s.resources.compute
  for _ = 1, s:ticks(400) do
    s:step()
    for i, sid in ipairs(s.shipOrder) do
      local v = s.ships[sid].vein
      if v then used[sid] = used[sid] or {}; used[sid][v.id] = true end
    end
  end
  for i, sid in ipairs(s.shipOrder) do
    local want = veins[s.ships[sid].owner]
    local n = 0
    for k in pairs(used[sid] or {}) do n += 1; assert(k == want, sid .. " mined " .. k .. ", wanted " .. want) end
    assert(n == 1, sid .. " never mined")
    assert(#s.ships[sid].crowdedBy == 0, "no crowding with split veins")
  end
  assert(s.resources.compute == compute, "skills cost no Compute")
  assert(#Skills.usage(s)["ore-run"] == 3, "the Archive lists the 3 runners")
end

-- 4. two stub Logisticians with a vague directive collide; split directives never do
do
  local function errorsOf(s)
    local n = 0
    for _, id in ipairs({ "logistician", "logistician_2" }) do
      for _, rec in ipairs(s.records[id] or {}) do
        if rec.validation == "not_enough_stock" or rec.validation == "no_free_freighter" then n += 1 end
      end
    end
    return n
  end
  local function station(seed)
    local s = company(1)
    assert(s:hireLogistician("kessa") and s:hireLogistician("kessa"))
    s:buyFreighter("kessa"); s:buyFreighter("kessa")
    s:setDecider(Ai.decide)
    return s
  end
  local collided = 0
  for _ = 1, 3 do
    local s = station()
    s:setDirective("logistician", "Ship stuff."); s:setDirective("logistician_2", "Ship stuff.")
    s.warehouse.cobalt = 500
    s:run(s:ticks(60))
    s.warehouse.cobalt = 500
    s:run(s:ticks(60))
    if errorsOf(s) > 0 then collided += 1 end
  end
  assert(collided > 0, "vague directives collide on stock or freighters")
  local s = station()
  s:setDirective("logistician", "Ship cobalt to Halcyon."); s:setDirective("logistician_2", "Ship titanium to Halcyon.")
  for _ = 1, 10 do
    s.warehouse.cobalt, s.warehouse.titanium = 500, 500
    s:run(s:ticks(60))
  end
  assert(errorsOf(s) == 0, "split directives: no stock or freighter errors")
end

-- 5. mission 6: opens with ship #2, counts crowding, passes with split veins and fails on a shared vein
do
  local s = company(1)
  skipTo(s, 6)
  assert(status(s, 6) == "locked" and MissionsView.model(s).current.progressText == "Buy mining ship #2")
  assert(s:buyUpgrade("ship2"))
  s:run(1)
  assert(status(s, 6) == "active", "ship #2 opens mission 6")
  assert(Skills.assign(s, "miner", "ore-run", { vein = "K1" }) and Skills.assign(s, "miner2", "ore-run", { vein = "K3" }))
  s:run(s:ticks(10 * 60) + 5)
  assert(status(s, 6) == "complete", "split veins pass: " .. Missions.progress(s, s.missions[6]).text)
  local before = s.resources.credits
  assert(Missions.claim(s, 6) and s.resources.credits == before + 2000)
  assert(status(s, 7) == "locked")

  local t = company(1)
  skipTo(t, 6)
  assert(t:buyUpgrade("ship2"))
  t:run(1)
  assert(Skills.assign(t, "miner", "ore-run", { vein = "K1" }) and Skills.assign(t, "miner2", "ore-run", { vein = "K1" }))
  t:run(t:ticks(10 * 60) + 5)
  local p = Missions.progress(t, t.missions[6])
  assert(status(t, 6) == "active" and p.failed, "one shared vein fails the crowding limit")
  assert(MissionsView.model(t).current.retry == "missions.retry.6")
  local hold = t.ships.s2 -- a Miner must sell titanium before it can dig cobalt: empty the hold for this check
  hold.cargo, hold.cargoF, hold.ore, hold.cargoVein = 0, 0, nil, nil
  t:apply("miner2", { name = "return", args = { ship = "s2" } }, { auto = true })
  t:run(t:ticks(120))
  assert(Skills.assign(t, "miner2", "ore-run", { vein = "K3" }))
  assert(Missions.retry(t, 6))
  t:run(t:ticks(10 * 60) + 5)
  local q = Missions.progress(t, t.missions[6])
  assert(status(t, 6) == "complete", "retry after splitting the veins: " .. q.text .. " " .. q.lines[1].text .. " " .. q.lines[2].text)
end

-- 6. mission 7: two Logisticians, 2 deliveries each, zero conflicts; a conflict fails it; +1 freighter on claim
do
  local s = company(1)
  skipTo(s, 7)
  assert(status(s, 7) == "locked" and MissionsView.model(s).current.progressText:find("Hire 2 Logisticians", 1, true))
  assert(s:hireLogistician("kessa"))
  s:run(1)
  assert(status(s, 7) == "locked", "one Logistician is not enough")
  assert(s:hireLogistician("kessa"))
  s:run(1)
  assert(status(s, 7) == "active")
  s:buyFreighter("kessa"); s:buyFreighter("kessa")
  local sent = 0
  local function ship(id, res)
    local ok = s:apply(id, { name = "ship", args = { resource = res, qty = 100, destination = "halcyon" } })
    assert(ok, id .. " ship " .. res)
    sent += 1
  end
  for _ = 1, 2 do
    s.warehouse.cobalt, s.warehouse.titanium = 500, 500
    ship("logistician", "cobalt"); ship("logistician_2", "titanium")
    s:run(s:ticks(500) + 5) -- there and back
  end
  s:run(s:ticks(15 * 60))
  assert(status(s, 7) == "complete", Missions.progress(s, s.missions[7]).text)
  local freighters = #s.freighters
  assert(Missions.claim(s, 7) and #s.freighters == freighters + 1, "+1 freighter at the station")
  assert(MissionsView.model(s).current.id == 8, "the last mission waits for the command center")

  local t = company(1)
  skipTo(t, 7)
  assert(t:hireLogistician("kessa") and t:hireLogistician("kessa"))
  t:run(1)
  t:buyFreighter("kessa")
  t.warehouse.cobalt = 500
  assert(t:apply("logistician", { name = "ship", args = { resource = "cobalt", qty = 100, destination = "halcyon" } }))
  local ok, err = t:apply("logistician_2", { name = "ship", args = { resource = "cobalt", qty = 100, destination = "halcyon" } })
  assert(not ok and err == "no_free_freighter")
  assert(Missions.progress(t, t.missions[7]).failed and MissionsView.model(t).current.retry == "missions.retry.7", "a conflict fails it at once")
  assert(Missions.retry(t, 7) and not Missions.progress(t, t.missions[7]).failed)
end

-- 7. team view: one row per agent with asset, mode, state and errors; a click opens the editor
do
  local s = company(2)
  assert(s:hireLogistician("kessa"))
  assert(Skills.assign(s, "miner2", "ore-run", { vein = "K1" }))
  local m = TeamView.model(s)
  assert(#m.rows == 3 and m.used == 3 and m.capacity == 8)
  assert(m.rows[1].id == "miner" and m.rows[1].asset == "s1" and m.rows[1].mode == "AI")
  assert(m.rows[2].mode == "ore-run" and m.rows[2].asset == "s2")
  assert(m.rows[3].asset == "main@kessa" and m.rows[3].type == "logistician")
  assert(select(2, TeamView.act(s, "team.open.miner2")) == "miner2" and select(2, TeamView.act(s, "team.open.zzz")) == nil)
  assert(not TeamView.act(s, "nav.team"))
  local spec, shown = Shell.spec(s, "team", {})
  assert(shown == "team" and spec)
  assert(Screens.nav[3].id == "team")
  local t = Sim.new()
  assert(select(2, Shell.spec(t, "team", {})) == "map", "team is hidden at T1")
end

-- 8. missions 6-7 survive a save and an old save gets them locked
do
  local s = company(1)
  skipTo(s, 7)
  assert(s:hireLogistician("kessa") and s:hireLogistician("kessa"))
  s:run(s:ticks(5))
  local m = s.market
  m.nextTrend, m.nextRival = 1e9, 1e9
  for _, mk in pairs(m.markets) do mk.nextEvent = 1e9 end
  local st = Persistence.memoryStorage()
  assert(Persistence.save(s, st, "a", 0))
  local r = assert(Persistence.load(st, "a"))
  assert(status(r, 7) == "active" and #r.missions == 8)
  local data = Persistence.serialize(s, 0)
  data = Sim.deepCopy(data)
  local key = data.state and data.state.missions and "state" or nil
  local list = (key and data.state or data).missions
  while #list > 5 do table.remove(list) end
  local old = assert(Persistence.restore(data))
  assert(#old.missions == 8 and old.missions[6].status == "locked")
end

print("multi OK")
