-- View-models of the UI shell (GR5-3): plain tables the layout and the map draw. Pure reads of the sim, no engine calls,
-- so the numbers and the unlock rules are testable headless and the drawing code only lays them out.
local Balance = require("@scripts/config/balance")
local World = require("@scripts/config/world")
local Screens = require("@scripts/config/screens")
local ComputeView = require("@scripts/ui/compute_view")
local Clock = require("@scripts/sim/clock")
local Raiding = require("@scripts/sim/raiding")
local Salvage = require("@scripts/sim/salvage")

local Model = {}

local function round(x: number) return math.floor(x + 0.5) end

-- "1,234" with thousands separators.
function Model.thousands(n: number)
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

-- Reputation level from lifetime revenue (spec §6.7) and progress to the next level.
function Model.reputation(sim)
	local rev, levels = sim.lifetimeRevenue or 0, Balance.reputationLevels
	local level = 0
	for i, need in ipairs(levels) do if rev >= need then level = i end end
	local from = level == 0 and 0 or levels[level]
	local to = levels[level + 1]
	return { level = level, revenue = rev, next = to, fraction = to and math.min(1, (rev - from) / (to - from)) or 1 }
end

-- Credits, Compute gauge, Reputation, Tier.
function Model.topBar(sim)
  local c = ComputeView.topBar(sim)
  local rep = Model.reputation(sim)
  return {
    credits = round(sim.resources.credits),
    creditsText = Model.thousands(round(sim.resources.credits)) .. " cr",
    compute = c.compute, computeLevel = c.level, computeText = ("%.1f"):format(c.compute),
    computeCreditsText = ("%d cr"):format(math.floor(c.computeCredits + 0.5)),
    computeFraction = c.budget.fraction, budgetReached = c.budget.reached, budgetMessage = c.budget.message,
    budgetPercent = round(c.budget.fraction * 100), teamPerHour = c.teamPerHour,
    buy = ComputeView.buyOptions(sim, 1)[1],
    reputation = rep, reputationText = ("Rep %d"):format(rep.level),
    tier = sim.tier, tierText = ("T%d"):format(sim.tier),
    speed = Clock.controls(sim),
  }
end

-- Nav entries visible at `tier` (spec §6.6), in order. `active` marks the current screen.
function Model.nav(tier: number, active: string?)
  local out = {}
  for _, e in ipairs(Screens.nav) do
    if tier >= e.unlockTier then out[#out + 1] = { id = e.id, label = e.label, active = e.id == active } end
  end
  return out
end

function Model.screenVisible(tier: number, id: string)
  for _, e in ipairs(Screens.nav) do if e.id == id then return tier >= e.unlockTier end end
  return false
end

-- Why a harvest planet is greyed: the engine (and range) it needs, from world data.
function Model.unlockCondition(planetId: string)
  local p = World.planets[planetId]
  local text = ("Engine Mk%d"):format(p.engineMark)
  if p.needsDeepNav then text = text .. " + Deep-range nav (T4)" end
  return text
end

local function reachable(sim, planetId)
  for _, id in ipairs(sim.shipOrder) do
    if sim:inRange(sim.ships[id], planetId) then return true end
  end
  return false
end

-- Ores a planet's veins hold, in World.oreOrder, for the map label.
local function oresOf(planetId)
  local seen, list = {}, {}
  for _, v in ipairs(World.veins) do
    if v.planet == planetId then seen[v.ore] = true end
  end
  for _, ore in ipairs(World.oreOrder) do if seen[ore] then list[#list + 1] = World.ores[ore].name end end
  return list
end

-- The system map: the 4 harvest planets (greyed + condition while out of reach), the markets unlocked so far, their
-- routes, and one dot per freighter on the move. Positions are fractions of the main panel (config/screens.luau).
function Model.map(sim)
  local cfg = Screens.map
  local planets = {}
  for _, id in ipairs(World.planetOrder) do
    local p = World.planets[id]
    local lit = reachable(sim, id)
    planets[#planets + 1] = { id = id, name = p.name, x = cfg.planets[id].x, y = cfg.planets[id].y, lit = lit,
      condition = (not lit) and Model.unlockCondition(id) or nil, ores = oresOf(id) }
  end
  local markets, shown = {}, {}
  for _, id in ipairs(World.marketOrder) do
    local m = World.markets[id]
    if sim.tier >= m.unlockTier then
      shown[id] = true
      markets[#markets + 1] = { id = id, name = m.name, tier = m.unlockTier, x = cfg.markets[id].x, y = cfg.markets[id].y }
    end
  end
  local routes = {}
  for _, r in ipairs(cfg.routes) do
    if shown[r.to] then
      routes[#routes + 1] = { from = r.from, to = r.to, risk = r.risk, color = r.risk == "low" and "safe" or "risky",
        seconds = World.freighterRoutes[r.from][r.to] }
    end
  end
  -- An outpost adds its own routes (spec D21); the colour follows the trip length.
  for _, sid in ipairs(sim.stationOrder) do
    if sid ~= sim.home then
      for _, mid in ipairs(World.marketOrder) do
        if shown[mid] then
          local seconds = World.freighterRoutes[sid][mid]
          local low = seconds <= cfg.safeRouteSeconds
          routes[#routes + 1] = { from = sid, to = mid, risk = low and "low" or "medium", color = low and "safe" or "risky", seconds = seconds }
        end
      end
    end
  end
  local convoys = {}
  for _, f in ipairs(sim.freighters) do
    local l = f.load
    if f.state == "out" and l and shown[l.destination] then
      local total = sim:ticks(World.freighterRoutes[f.station][l.destination])
      convoys[#convoys + 1] = { id = f.id, from = f.station, to = l.destination, t = math.max(0, math.min(1, 1 - f.timer / total)) }
    end
  end
  local rivals = {}
  for _, c in ipairs(Raiding.mapConvoys(sim)) do
    if shown[c.to] then rivals[#rivals + 1] = c end
  end
  return { planets = planets, markets = markets, routes = routes, convoys = convoys, rivals = rivals, sites = Salvage.mapSites(sim) }
end

-- What the main panel says when a screen has nothing yet; nil for the screens that always have content (map).
function Model.emptyState(screenId: string) return Screens.empty[screenId] end

-- The latest feed lines (newest last), each { text, status, agent }.
function Model.feed(sim)
  local out, list = {}, sim.feed or {}
  for i = math.max(1, #list - Screens.feedLines + 1), #list do
    local e = list[i]
    out[#out + 1] = { text = e.text, status = e.status or "ok", agent = e.agent, kind = e.kind, source = e.source }
  end
  return out
end

-- One string that changes when anything the shell draws changes: the shell redraws only then.
function Model.signature(sim, screenId: string, extra: string?)
  local top, parts = Model.topBar(sim), {}
  parts[#parts + 1] = screenId
  parts[#parts + 1] = extra or ""
  for _, c in ipairs(top.speed) do parts[#parts + 1] = c.action .. (c.active and "+" or "-") end
  parts[#parts + 1] = ("%s|%s|%s|%s|%d|%s|%s|%s"):format(top.creditsText, top.computeText, top.reputationText, top.tierText,
    round(top.computeFraction * 100), top.computeLevel, tostring(top.budgetReached), tostring(top.buy.affordable))
  for _, p in ipairs(Model.map(sim).planets) do parts[#parts + 1] = p.id .. (p.lit and "+" or "-") end
  for _, m in ipairs(Model.map(sim).markets) do parts[#parts + 1] = m.id end
  for _, l in ipairs(Model.feed(sim)) do parts[#parts + 1] = l.text .. l.status end
  return table.concat(parts, ";")
end

return Model
