-- Run from repo root: luau tests/test_market.luau
-- GR5-10 / spec §6.3: price = base x demand x saturation, events, trends, rival sales, history, determinism, M6.
local Sim = require("@scripts/sim/sim")
local Market = require("@scripts/sim/market")
local Persistence = require("@scripts/sim/persistence")
local Json = require("./support/engine_json")
local World = require("@scripts/config/world")

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end
local function fresh(seed)
  local s = Sim.new({ seed = seed })
  Market.quiet(s.market)
  return s
end
local function seconds(s, n) for _ = 1, n * 10 do s:step() end end

-- 1. price = base x d x s, baselines of §4.4, Orbis generalist 0.6 with depth 4,000
do
  local s = fresh()
  local m = s.market
  assert(near(Market.price(m, "orbis", "titanium"), 10 * 0.6))
  assert(near(Market.price(m, "halcyon", "titanium"), 10 * 1.3))
  assert(near(Market.price(m, "meridian", "crystal"), 150 * 1.4))
  assert(Market.price(m, "halcyon", "crystal") == nil and not Market.has(m, "halcyon", "crystal"))
  assert(m.markets.orbis.depth == 4000)
  assert(near(Market.usual(m, "meridian", "iridium"), 60 * 1.3))
  local id, p = Market.best(m, "titanium")
  assert(id == "halcyon" and near(p, 13))
  id = Market.best(m, "titanium", function(mid) return mid ~= "halcyon" end)
  assert(id ~= "halcyon")
end

-- 2. a sale is priced before the drop, saturates by qty/depth, and recovers slowly
do
  local s = fresh()
  local m = s.market
  local unit, total = Market.sell(m, "orbis", "cobalt", 400)
  assert(near(unit, 24 * 0.6) and total == math.floor(400 * unit))
  assert(near(Market.saturation(m, "orbis", "cobalt"), 1 - 400 / 4000))
  assert(Market.price(m, "orbis", "cobalt") < unit)
  Market.sell(m, "orbis", "cobalt", 100000)
  assert(near(Market.saturation(m, "orbis", "cobalt"), 0.4), "floor 0.4")
  seconds(s, 300)
  local back = Market.saturation(m, "orbis", "cobalt")
  assert(back > 0.4 and back < 1, "recovers but not at once: " .. back)
  seconds(s, 3600)
  assert(Market.saturation(m, "orbis", "cobalt") > 0.95)
end

-- 3. events: shortage / glut move the target, demand follows, then it returns
do
  local s = fresh()
  local m = s.market
  local seen = 0
  assert(m:forceEvent("shortage", "halcyon", "iridium"))
  assert(not m:forceEvent("shortage", "halcyon", "crystal") and not m:forceEvent("nope"))
  local p0 = Market.price(m, "halcyon", "iridium")
  seconds(s, 60)
  assert(Market.price(m, "halcyon", "iridium") > p0, "demand follows the target up")
  seconds(s, 600)
  assert(Market.price(m, "halcyon", "iridium") < 60 * 0.9 * 1.5 * 0.99 and m.markets.halcyon.res.iridium.kind == nil, "event over")
  seconds(s, 3000)
  assert(near(Market.price(m, "halcyon", "iridium"), 60 * 0.9, 0.5), "back to the baseline")
  for _, e in ipairs(s:drainEvents()) do if e.name == "market_notice" then seen += 1 end end
  assert(seen >= 1 and #m.notices >= 1, "events send notices through the sim event queue")
  assert(m:forceEvent("glut", "meridian", "crystal"))
  seconds(s, 90)
  assert(Market.price(m, "meridian", "crystal") < 150 * 1.4)
end

-- 4. unscheduled: events, trends and rivals fire on their own, trends never on Orbis, history keeps 30 min
do
  local s = Sim.new({ seed = 3 })
  local trends, kinds = 0, {}
  local notify = s.market.notify
  s.market.notify = function(kind, text) kinds[kind] = (kinds[kind] or 0) + 1; notify(kind, text) end
  seconds(s, 3 * 3600)
  assert((kinds.trend or 0) >= 3, "slow trends with notifications")
  assert(#s.market.convoys >= 0 and s.market.nextRival < math.huge)
  for _, n in ipairs(s.market.notices) do
    if n.kind == "trend" then assert(not n.text:find("Orbis")) end
  end
  assert(s.market.markets.orbis.res.titanium.b == s.market.markets.orbis.res.titanium.base, "no trend on Orbis")
  for _, rows in pairs(s.market.history) do assert(#rows == 180, "30 min at 10 s = 180 samples: " .. #rows) end
  for _, r in ipairs(Market.rows(s.market)) do
    assert(r.price > 0 and r.usual > 0 and #r.history == 180)
  end
  for _, mk in pairs(s.market.markets) do
    for _, r in pairs(mk.res) do assert(r.s >= 0.4 and r.s <= 1 and r.b >= 0.5 and r.b <= 1.6) end
  end
end

-- 5. deterministic per seed, different across seeds, identical after a save round trip
do
  local function run(seed, n)
    local s = Sim.new({ seed = seed })
    seconds(s, n)
    return Json.encode(Market.serialize(s.market))
  end
  assert(run(5, 2400) == run(5, 2400))
  assert(run(5, 2400) ~= run(6, 2400))
  local a = Sim.new({ seed = 9 })
  seconds(a, 1800)
  local storage = Persistence.memoryStorage()
  assert(Persistence.save(a, storage, "m.json", 0))
  local b = assert(Persistence.load(storage, "m.json"))
  seconds(a, 1800); seconds(b, 1800)
  assert(Json.encode(Market.serialize(a.market)) == Json.encode(Market.serialize(b.market)), "market diverged after load")
end

-- 6. M6: with a scripted seller always dumping on the best buyer, the best buyer changes for >= 2 resources in 3 h
do
  for _, seed in ipairs({ 1, 2, 3 }) do
    local s = Sim.new({ seed = seed })
    local m = s.market
    local first, changed = {}, {}
    for _, ore in ipairs(World.oreOrder) do first[ore] = Market.best(m, ore) end
    for sec = 1, 3 * 3600 do
      seconds(s, 1)
      if sec % 60 == 0 then
        for _, ore in ipairs(World.oreOrder) do
          local mid = Market.best(m, ore)
          if mid ~= first[ore] then changed[ore] = true end
          Market.sell(m, mid, ore, 250)
        end
      end
    end
    local n = 0
    for _ in pairs(changed) do n += 1 end
    assert(n >= 2, ("seed %d: best buyer changed for %d resources"):format(seed, n))
  end
end

print("market OK")
