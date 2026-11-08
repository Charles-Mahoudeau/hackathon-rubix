-- Market screen view-model (GR5-10, spec §6.3): who buys what, the price now, the usual price, a trend arrow, the best
-- buyer per resource and the price history for the sparkline, only for the markets that are open (Orbis needs the
-- trading post). Pure reads, so the whole path is testable headless; the shell only lays it out.
local World = require("@scripts/config/world")
local Market = require("@scripts/sim/market")
local Refined = require("@scripts/config/branches").refining

local View = {}

local function arrow(price, usual)
  local r = price / usual
  if r >= 1.1 then return "up" end
  if r <= 0.9 then return "down" end
  return "flat"
end

function View.model(sim)
  local m = sim.market
  local rows, bests = {}, {}
  local goods = {}
  for _, ore in ipairs(World.oreOrder) do goods[#goods + 1] = ore end
  for _, good in ipairs(Refined.recipeOrder) do goods[#goods + 1] = good end
  for _, ore in ipairs(goods) do
    bests[ore] = Market.best(m, ore, function(mid) return sim:marketUnlocked(mid) end)
  end
  for _, r in ipairs(Market.rows(m)) do
    if sim:marketUnlocked(r.market) then
      r.best = bests[r.resource] == r.market
      r.trend = arrow(r.price, r.usual)
      r.text = ("%s %s  %.1f cr (usual %.1f)"):format(r.name, Market.goodName(r.resource), r.price, r.usual)
      rows[#rows + 1] = r
    end
  end
  local notices = {}
  for i = #m.notices, math.max(1, #m.notices - 7), -1 do notices[#notices + 1] = m.notices[i].text end
  return { rows = rows, notices = notices, bestBuyer = bests }
end

function View.signature(sim)
  local m = sim.market
  return ("%d:%d"):format(m.sec // 10, m.noticeSeq)
end

return View
