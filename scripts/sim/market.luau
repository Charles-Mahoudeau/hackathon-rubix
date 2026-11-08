-- Market dynamics (spec §6.3): price = base x demand x saturation for Orbis, Halcyon and Meridian. Pure sim logic (no UI):
-- notices leave through `notify`, which the sim wires to its event queue. State is plain data, so a save holds it as is.
-- Streams: `rng.events` rolls the short events, `rng.market` the trends and the rival sales.
local World = require("@scripts/config/world")
local C = require("@scripts/config/market")
local Refined = require("@scripts/config/branches").refining
local Rng = require("./rng")

local Market = {}
Market.__index = Market

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
local function round1(x) return math.floor(x * 10 + 0.5) / 10 end

local function interval(m, stream, seconds, jitter)
  return m.sec + seconds + (Rng.next(m.rng, stream) * 2 - 1) * jitter
end

-- sim: only used to reach `rng`, the tick length and the notice hook.
function Market.new(rng, tickSeconds, notify)
  local m = setmetatable({ rng = rng, notify = notify, tps = math.floor(1 / tickSeconds + 0.5), tick = 0, sec = 0,
    markets = {}, order = {}, history = {}, convoys = {}, notices = {}, noticeSeq = 0 }, Market)
  for _, mid in ipairs(World.marketOrder) do
    local def = World.markets[mid]
    local mk = { id = mid, name = def.name, depth = def.depth, order = {}, res = {} }
    for _, ore in ipairs(World.oreOrder) do
      local b = def.demand[ore]
      if b then
        mk.order[#mk.order + 1] = ore
        mk.res[ore] = { b = b, base = b, d = b, t = b, driftT = b, s = 1 }
        m.history[mid .. "." .. ore] = {}
      end
    end
    mk.nextEvent = interval(m, "events", C.events.everySeconds, C.events.jitterSeconds)
    m.markets[mid] = mk
    m.order[#m.order + 1] = mid
  end
  m.nextTrend = interval(m, "market", C.trends.everyMinutes * 60, C.trends.jitterMinutes * 60)
  m.nextRival = interval(m, "market", C.rivals.everySeconds, C.rivals.jitterSeconds)
  return m
end

local function note(m, kind, text)
  m.noticeSeq += 1
  local list = m.notices
  list[#list + 1] = { id = m.noticeSeq, sec = m.sec, kind = kind, text = text }
  if #list > C.noticesMax then table.remove(list, 1) end
  if m.notify then m.notify(kind, text) end
end

local function oreName(ore) return World.ores[ore] and World.ores[ore].name or Refined.recipes[ore].name end

-- Base price of a raw ore or a refined good.
local function baseOf(ore) return World.ores[ore] and World.ores[ore].basePrice or Refined.recipes[ore].price end

-- The refining branch opened: every market that buys a refined good starts to list it, with its own depth (spec §15b.2).
-- Added on opening, not at start, so a game without the branch keeps its random draws.
function Market.addRefined(m)
  for _, mid in ipairs(m.order) do
    local mk = m.markets[mid]
    for _, good in ipairs(Refined.recipeOrder) do
      local b = Refined.demand[mid] and Refined.demand[mid][good]
      if b and not mk.res[good] then
        mk.order[#mk.order + 1] = good
        mk.res[good] = { b = b, base = b, d = b, t = b, driftT = b, s = 1, depth = Refined.depth }
        m.history[mid .. "." .. good] = {}
      end
    end
  end
end

Market.round1 = round1
Market.goodName = oreName

function Market.has(m, mid, ore) return m.markets[mid] ~= nil and m.markets[mid].res[ore] ~= nil end

-- Current unit price (not rounded); nil when the market does not buy the ore.
function Market.price(m, mid, ore)
  local mk = m.markets[mid]
  local r = mk and mk.res[ore]
  if not r then return nil end
  return baseOf(ore) * r.d * r.s
end

-- The "usual" price: the baseline demand b with no saturation (spec §6.3, the faint line next to the price).
function Market.usual(m, mid, ore)
  local mk = m.markets[mid]
  local r = mk and mk.res[ore]
  if not r then return nil end
  return baseOf(ore) * r.b
end

function Market.saturation(m, mid, ore) return m.markets[mid].res[ore].s end

-- Sell `qty` units: priced before the drop, then the saturation drops. -> unit price, total credits (rounded down).
function Market.sell(m, mid, ore, qty)
  local mk = m.markets[mid]
  local r = mk.res[ore]
  local unit = round1(baseOf(ore) * r.d * r.s)
  r.s = math.max(C.satFloor, r.s - qty / (r.depth or mk.depth))
  return unit, math.floor(qty * unit)
end

-- Best buyer for `ore` among the markets accepted by `allowed(mid)` (all when nil): market id, price.
function Market.best(m, ore, allowed)
  local bestId, best = nil, -1
  for _, mid in ipairs(m.order) do
    local p = Market.price(m, mid, ore)
    if p and (not allowed or allowed(mid)) and p > best then bestId, best = mid, p end
  end
  return bestId, best
end

local function startEvent(m, mk, ore, kind)
  local r, e = mk.res[ore], C.events
  if kind == "drift" then
    r.driftT = r.b * clamp(1 + Rng.normal(m.rng, "events", e.driftSigma), e.driftMin, e.driftMax)
    if not r.untilSec then r.t = r.driftT end
    return
  end
  r.t = r.b * (kind == "shortage" and e.shortageMult or e.glutMult)
  r.untilSec, r.kind = m.sec + e.durationSeconds, kind
  local pct = math.floor((r.t / r.b - 1) * 100 + 0.5)
  note(m, kind, ("%s %s on %s: %s%d%%"):format(oreName(ore), kind, mk.name:match("^(%S+)"), pct >= 0 and "+" or "", pct))
end

local function rollEvent(m, mk)
  local e = C.events
  local ore = mk.order[Rng.pick(m.rng, "events", #mk.order)]
  local roll = Rng.next(m.rng, "events")
  startEvent(m, mk, ore, roll < e.driftChance and "drift" or (roll < e.driftChance + e.shortageChance and "shortage" or "glut"))
  mk.nextEvent = interval(m, "events", e.everySeconds, e.jitterSeconds)
end

local function rollTrend(m)
  local pairsList = {}
  for _, mid in ipairs(m.order) do
    if not C.trends.neverOn[mid] then
      for _, ore in ipairs(m.markets[mid].order) do pairsList[#pairsList + 1] = { mid, ore } end
    end
  end
  m.nextTrend = interval(m, "market", C.trends.everyMinutes * 60, C.trends.jitterMinutes * 60)
  if #pairsList == 0 then return end
  local pick = pairsList[Rng.pick(m.rng, "market", #pairsList)]
  local mk = m.markets[pick[1]]
  local r = mk.res[pick[2]]
  local sign = Rng.next(m.rng, "market") < 0.5 and -1 or 1
  local toward = Rng.next(m.rng, "market")
  if r.b ~= r.base and toward < C.trends.towardChance then sign = r.base > r.b and 1 or -1 end
  local old = r.b
  r.b = clamp(r.b + sign * C.trends.step, C.trends.min, C.trends.max)
  if r.b == old then return end
  local ratio = r.b / old
  r.driftT = r.driftT * ratio
  if r.untilSec then r.t = r.t * ratio else r.t = r.driftT end
  local dir = sign > 0 and "up" or "down"
  local f = C.flavor[pick[1]] and C.flavor[pick[1]][pick[2]]
  note(m, "trend", f and f[dir] or C.trendGeneric[dir]:format(mk.name:match("^(%S+)"), oreName(pick[2])))
end

-- A rival sale lands on `mid`: the ore saturates and a dot shows on the board. Called by the scripted sale below and, once the
-- raiding branch is open, by the real convoy when it arrives (sim/raiding.luau).
function Market.rivalArrives(m, mid, ore, qty)
  local mk = m.markets[mid]
  local r = mk.res[ore]
  r.s = math.max(C.satFloor, r.s - qty / (r.depth or mk.depth))
  m.convoys[#m.convoys + 1] = { market = mid, resource = ore, qty = qty, sec = m.sec }
end

local function rivalSale(m)
  local rv = C.rivals
  if m.convoyHook and m.convoyHook(m) then
    m.nextRival = interval(m, "market", rv.everySeconds, rv.jitterSeconds)
    return
  end
  local mk = m.markets[m.order[Rng.pick(m.rng, "market", #m.order)]]
  local ore = mk.order[Rng.pick(m.rng, "market", #mk.order)]
  local qty = rv.minUnits + math.floor(Rng.next(m.rng, "market") * (rv.maxUnits - rv.minUnits + 1))
  Market.rivalArrives(m, mk.id, ore, qty)
  m.nextRival = interval(m, "market", rv.everySeconds, rv.jitterSeconds)
end

local function secondTick(m)
  m.sec += 1
  local sec = m.sec
  local sat, follow = C.satRecoverPerMinute / 60, C.demandFollowPerMinute / 60
  for _, mid in ipairs(m.order) do
    local mk = m.markets[mid]
    for _, ore in ipairs(mk.order) do
      local r = mk.res[ore]
      r.s += (1 - r.s) * sat
      r.d += (r.t - r.d) * follow
      if r.untilSec and sec >= r.untilSec then r.t, r.untilSec, r.kind = r.driftT, nil, nil end
    end
    if sec >= mk.nextEvent then rollEvent(m, mk) end
  end
  if sec >= m.nextTrend then rollTrend(m) end
  if sec >= m.nextRival then rivalSale(m) end
  local cs = m.convoys
  while cs[1] and sec - cs[1].sec > C.rivals.convoySeconds do table.remove(cs, 1) end
  if sec % C.history.sampleSeconds == 0 then
    local keep = C.history.keepMinutes * 60 / C.history.sampleSeconds
    for _, mid in ipairs(m.order) do
      local mk = m.markets[mid]
      for _, ore in ipairs(mk.order) do
        local h = m.history[mid .. "." .. ore]
        h[#h + 1] = round1(baseOf(ore) * mk.res[ore].d * mk.res[ore].s)
        if #h > keep then table.remove(h, 1) end
      end
    end
  end
end

-- One sim tick; the market moves once per game second.
function Market.step(m)
  m.tick += 1
  if m.tick % m.tps == 0 then secondTick(m) end
end

-- Debug panel: start a shortage or glut now. market defaults to halcyon, ore to the first it buys. -> ok | false, error
function Market:forceEvent(kind, mid, ore)
  if kind ~= "shortage" and kind ~= "glut" then return false, "bad event kind" end
  local mk = self.markets[mid or "halcyon"]
  if not mk then return false, "unknown_market" end
  ore = ore or mk.order[1]
  if not mk.res[ore] then return false, "not_bought_here" end
  startEvent(self, mk, ore, kind)
  return true
end

-- Tests: no scheduled event, trend or rival sale will fire.
function Market.quiet(m)
  for _, mk in pairs(m.markets) do mk.nextEvent = math.huge end
  m.nextTrend, m.nextRival = math.huge, math.huge
end

-- Rows for the Market panel: one per (market, ore) that is bought, with price, usual price, trend arrow and history.
function Market.rows(m)
  local rows = {}
  for _, mid in ipairs(m.order) do
    local mk = m.markets[mid]
    for _, ore in ipairs(mk.order) do
      local r = mk.res[ore]
      local price, usual = Market.price(m, mid, ore), Market.usual(m, mid, ore)
      rows[#rows + 1] = { market = mid, name = mk.name, resource = ore, price = round1(price), usual = round1(usual),
        saturation = r.s, event = r.kind, history = m.history[mid .. "." .. ore] }
    end
  end
  return rows
end

local SAVED = { "tick", "sec", "markets", "order", "history", "convoys", "notices", "noticeSeq", "nextTrend", "nextRival" }

-- Plain data for the save (without the rng reference and the notify hook). Infinity is not JSON: only tests use quiet().
function Market.serialize(m)
  local out = {}
  for _, k in ipairs(SAVED) do out[k] = m[k] end
  return out
end

function Market.load(m, data)
  for _, k in ipairs(SAVED) do if data[k] ~= nil then m[k] = data[k] end end
end

Market.round1 = round1
Market.baseOf = baseOf

return Market
