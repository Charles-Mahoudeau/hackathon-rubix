-- Salvage (spec §15b.3, B-a): abandoned-planet sites that spawn and expire, salvage ships, hazards and hull, loot and blueprints,
-- the Scavenger's tools and stub, mission V2. Pure sim logic, headless: no UI calls; the UI reads `sim.salvage`,
-- `sim.salvageShips` and events. Numbers: config/branches.luau `salvage`. Streams: `rng.site` (spawns), `rng.loot` (surveys,
-- hazards, loot, blueprints).
-- State: sim.salvage = { sites, siteSeq, nextSpawn, mission = { status }, bonuses = { refinerySpeed, hold, compute = { [type] = n } },
--   blueprints = { name, ... } }. site = { id, planet, type, danger, layers = { { quality, takenBy, done } }, spawned, expires, survey, ... }.
local World = require("@scripts/config/world")
local BranchesCfg = require("@scripts/config/branches")
local Cfg = BranchesCfg.salvage
local Feed = require("./feed")
local Market = require("./market")
local Rng = require("./rng")
local Logistics = require("./logistics")
local Raiding = require("./raiding")

local Salvage = {}

-- Streams are created on first use, so a save from before this branch still loads.
local function draw(sim, key)
  if sim.rng[key] == nil then sim.rng[key] = Rng.seedFor(sim.seed, Cfg.streams[key]) end
  return Rng.next(sim.rng, key)
end

local function pickWeighted(list, r)
  local total = 0
  for _, e in ipairs(list) do total += e[2] end
  local acc, roll = 0, r * total
  for _, e in ipairs(list) do
    acc += e[2]
    if roll < acc then return e[1] end
  end
  return list[#list][1]
end

function Salvage.init(sim)
  sim.salvageShips, sim.salvageOrder = {}, {}
  sim.salvage = { sites = {}, siteSeq = 0, nextSpawn = nil, mission = { status = "locked" },
    bonuses = { refinerySpeed = 0, hold = 0, compute = {} }, blueprints = {} }
end

local function open(sim) return sim.branchesOpen.salvage == true end
function Salvage.isOpen(sim) return open(sim) end

function Salvage.isGood(item) return Cfg.loot.goods[item or ""] ~= nil end

-- Bonuses ------------------------------------------------------------------------------------------------------------

-- Hold multiplier of the "hold +10% for all ships" blueprints.
function Salvage.holdMult(sim)
  local b = sim.salvage and sim.salvage.bonuses
  return 1 + (b and b.hold or 0) * Cfg.blueprint.hold
end

-- Speed multiplier of the refineries from the blueprints.
function Salvage.refinerySpeed(sim)
  local b = sim.salvage and sim.salvage.bonuses
  return 1 + (b and b.refinerySpeed or 0) * Cfg.blueprint.refinerySpeed
end

-- Share of the Compute cost an agent type saves (0 = none).
function Salvage.computeDiscount(sim, agentId)
  local agent = agentId and sim.agents[agentId]
  local b = sim.salvage and sim.salvage.bonuses
  if not agent or not b then return 0 end
  return math.min(0.9, (b.compute[agent.type] or 0) * Cfg.blueprint.compute)
end

-- Hold of the salvage ships and the interceptors; the mining ships follow in Upgrades.applyToShip.
function Salvage.applyHold(sim)
  local mult = Salvage.holdMult(sim)
  for _, id in ipairs(sim.salvageOrder) do
    local ship = sim.salvageShips[id]
    ship.cap = math.floor(Cfg.ship.hold * mult + 0.5)
  end
  for _, id in ipairs(sim.interceptorOrder or {}) do
    sim.interceptors[id].cap = math.floor(BranchesCfg.raiding.interceptor.hold * mult + 0.5)
  end
end

-- One permanent bonus, picked at random (a blueprint found or the reward of mission V2). -> its name
function Salvage.grantBlueprint(sim)
  local c = Cfg.blueprint
  local kind = c.bonuses[1 + math.floor(draw(sim, "loot") * #c.bonuses)]
  local typ = c.computeTypes[1 + math.floor(draw(sim, "loot") * #c.computeTypes)]
  local b = sim.salvage.bonuses
  local name = c.names[kind]
  if kind == "refinery_speed" then b.refinerySpeed += 1
  elseif kind == "hold" then
    b.hold += 1
    Salvage.applyHold(sim)
    sim:refreshFleet()
  elseif kind == "compute" then
    b.compute[typ] = (b.compute[typ] or 0) + 1
    name = ("-%d%% Compute for %s agents"):format(c.compute * 100, typ)
  elseif kind == "archive" then sim.upgrades.archiveBonus = (sim.upgrades.archiveBonus or 0) + c.archive end
  local list = sim.salvage.blueprints
  list[#list + 1] = name
  sim:log("INFO", "blueprint: " .. name)
  sim:emit("blueprint_found", { bonus = kind, name = name })
  return name
end

-- Ships --------------------------------------------------------------------------------------------------------------

function Salvage.addShip(sim, id, owner)
  local c = Cfg.ship
  local ship = { id = id, owner = owner, state = "idle", at = sim.home, hold = {}, hull = c.hull, hullMax = c.hull, cap = c.hold, timer = 0,
    job = nil, damagedRaised = false }
  sim.salvageShips[id] = ship
  sim.salvageOrder[#sim.salvageOrder + 1] = id
  Salvage.applyHold(sim)
  return ship
end

function Salvage.shipFor(sim, agentId)
  for _, id in ipairs(sim.salvageOrder) do
    if sim.salvageShips[id].owner == agentId then return sim.salvageShips[id] end
  end
  return nil
end

local function holdTotal(ship)
  local n = 0
  for _, q in pairs(ship.hold) do n += q end
  return n
end

function Salvage.holdTotal(ship) return holdTotal(ship) end

local function docked(sim, ship) return ship.state == "idle" and ship.at == sim.home end

local function repairCost(ship) return (ship.hullMax - ship.hull) * Cfg.ship.repairCreditsPerHull end

-- A Scavenger for a ship nobody commands, once the command capacity has room (spec §5.3).
function Salvage.claim(sim)
  for _, id in ipairs(sim.salvageOrder) do
    local ship = sim.salvageShips[id]
    if not ship.owner and #sim.agentOrder < sim:commandCapacity() then
      local n = 1
      while sim.agents["scavenger" .. (n + 1)] do n += 1 end
      local aid = "scavenger" .. (n + 1)
      sim:addAgent(aid, "scavenger", { tier = sim.tier })
      ship.owner = aid
      sim:log("INFO", ("%s: new Scavenger agent for %s (empty directive)"):format(aid, id))
      sim:emit("agent_added", { agent = aid, ship = id })
    end
  end
end

-- Shop: salvage ships #2 and #3 (ladder in config), listed only once the branch is open -----------------------------------

local SHOP_IDS = { "salvage_ship2", "salvage_ship3" }

local function shopIndex(id)
  for i, v in ipairs(SHOP_IDS) do if v == id then return i + 1 end end
  return nil
end

function Salvage.shopIndex(id) return shopIndex(id) end

function Salvage.shopBlocker(sim, id)
  local k = shopIndex(id)
  if not k or not open(sim) then return "unknown_item" end
  if #sim.salvageOrder >= k then return "already_owned" end
  if #sim.salvageOrder < k - 1 then return "needs_" .. SHOP_IDS[k - 2] end
  if sim.resources.credits < Cfg.ladder[k] then return "not_enough_credits" end
  return nil
end

function Salvage.shopRows(sim)
  local rows = {}
  if not open(sim) then return rows end
  for i, id in ipairs(SHOP_IDS) do
    local k = i + 1
    local why = Salvage.shopBlocker(sim, id)
    local state = "available"
    if why == "already_owned" then state = "owned"
    elseif why == "not_enough_credits" then state = "unaffordable"
    elseif why then state = "locked" end
    rows[#rows + 1] = { id = id, name = ("Salvage ship #%d"):format(k), desc = "+1 salvage ship and an empty Scavenger agent",
      cost = Cfg.ladder[k], state = state, blocker = why, tier = sim.tier }
  end
  return rows
end

function Salvage.shopBuy(sim, id)
  local why = Salvage.shopBlocker(sim, id)
  if why then
    sim:log("ERROR", ("shop: cannot buy %s (%s)"):format(tostring(id), why))
    return false, why
  end
  local k = shopIndex(id)
  sim.resources.credits = sim.resources.credits - Cfg.ladder[k]
  Salvage.addShip(sim, "w" .. k, nil)
  Salvage.claim(sim)
  sim:log("INFO", ("shop: bought salvage ship #%d for %d cr"):format(k, Cfg.ladder[k]))
  sim:emit("upgrade_bought", { id = id })
  return true
end

-- Branch opening: the first salvage ship, its Scavenger, and the first spawn timer.
function Salvage.onOpen(sim)
  sim:addAgent(Cfg.agentType, Cfg.agentType, { tier = sim.tier })
  Salvage.addShip(sim, Cfg.startShip, Cfg.agentType)
  sim.salvage.mission.status = "active"
  sim.salvage.nextSpawn = sim.tick + sim:ticks(Cfg.sites.intervalMinutes * 60)
end

-- Sites ----------------------------------------------------------------------------------------------------------------

local function findSite(sim, id)
  for _, s in ipairs(sim.salvage.sites) do if s.id == id then return s end end
  return nil
end

function Salvage.site(sim, id) return findSite(sim, id) end

local function inRange(sim, planet)
  local p = World.abandoned[planet]
  return p ~= nil and sim.upgrades.engine >= p.engineMark
end

local function engineMult(sim)
  local it = sim.b.shop.items["engine_mk" .. sim.upgrades.engine]
  return it and it.value or 1
end

-- Seconds to fly from planet `from` to planet `to` (through the home dock when they differ), at the fleet's engine.
local function legSeconds(sim, from, to)
  if from == to then return 0 end
  local function leg(p) return p == sim.home and 0 or World.abandoned[p].travel * engineMult(sim) end
  return (leg(from) + leg(to))
end

local function secondsLeft(sim, site) return math.floor((site.expires - sim.tick) * sim.b.tickSeconds) end

-- The next layer of a site nobody has taken, or nil: the lowest layer neither done nor taken.
local function nextFreeLayer(site)
  for i, l in ipairs(site.layers) do
    if not l.done and not l.takenBy then return i end
    if not l.done then return nil end -- a layer in progress locks the ones below it
  end
  return nil
end

-- Spawns a site. `o` (tests, scripted events) can fix planet / type / danger / qualities; the draws are made anyway so the
-- stream stays in step.
function Salvage.spawnSite(sim, o)
  o = o or {}
  local st, c = sim.salvage, Cfg.sites
  local planets = {}
  for _, pid in ipairs(World.abandonedOrder) do
    if inRange(sim, pid) then planets[#planets + 1] = pid end
  end
  local pRoll, tRoll, dRoll = draw(sim, "site"), draw(sim, "site"), draw(sim, "site")
  local planet = o.planet or planets[1 + math.floor(pRoll * #planets)]
  if not planet then return nil end
  local def = World.abandoned[planet]
  local typ = o.type or def.siteTypes[1 + math.floor(tRoll * #def.siteTypes)]
  local danger, acc = #c.dangerWeights, 0
  for d = 0, #c.dangerWeights do
    acc += c.dangerWeights[d]
    if dRoll < acc then danger = d break end
  end
  danger = o.danger or danger
  local weights = {}
  for i, q in ipairs(c.qualities) do weights[i] = { q, c.qualityWeights[i] } end
  local layers = {}
  for i = 1, c.layers do
    local q = pickWeighted(weights, draw(sim, "site"))
    layers[i] = { quality = (o.qualities and o.qualities[i]) or q, done = false }
  end
  st.siteSeq += 1
  local site = { id = "S" .. st.siteSeq, planet = planet, type = typ, danger = danger, layers = layers, spawned = sim.tick,
    expires = sim.tick + sim:ticks(c.lifeMinutes * 60), spawnRaised = false, expiringRaised = false }
  st.sites[#st.sites + 1] = site
  sim:log("INFO", ("salvage site %s spawned at %s (%s, danger %d)"):format(site.id, planet, typ, danger))
  sim:emit("site_spawned", { site = site.id, planet = planet })
  return site
end

local function removeSite(sim, site)
  for i, s in ipairs(sim.salvage.sites) do
    if s == site then table.remove(sim.salvage.sites, i) break end
  end
  sim:log("INFO", ("salvage site %s expired"):format(site.id))
  sim:emit("site_expired", { site = site.id })
end

-- Rows of the active sites for the context and the UI: only what the company knows. A surveyed site shows its type, danger and
-- the estimated loot band of each layer.
function Salvage.siteRows(sim, ship)
  local rows = {}
  for _, s in ipairs(sim.salvage.sites) do
    local layers, done, claimed = {}, 0, 0
    for i, l in ipairs(s.layers) do
      layers[i] = l.done and "done" or (l.takenBy and "taken" or "free")
      if l.done then done += 1 elseif l.takenBy then claimed += 1 end
    end
    local row = { id = s.id, planet = s.planet, left_s = secondsLeft(sim, s), surveyed = s.survey ~= nil, layers = layers,
      done = done, claimed = claimed, reach = inRange(sim, s.planet) }
    if s.survey then
      row.type, row.danger = s.survey.type, s.survey.danger
      row.bands = {}
      for i, b in ipairs(s.survey.bands) do row.bands[i] = b end
    end
    if ship then
      row.survey_s = math.floor(legSeconds(sim, ship.at, s.planet) + Cfg.ship.surveySeconds + 0.5)
      local nl = nextFreeLayer(s)
      row.next_layer = nl
      row.next_s = nl and math.floor(legSeconds(sim, ship.at, s.planet) + Cfg.ship.salvageSecondsPerLayer * nl + 0.5) or nil
    end
    rows[#rows + 1] = row
  end
  return rows
end

-- Sites on the map: { id, planet, left_s, surveyed }.
function Salvage.mapSites(sim)
  local out = {}
  if not sim.salvage or not open(sim) then return out end
  for _, s in ipairs(sim.salvage.sites) do
    out[#out + 1] = { id = s.id, planet = s.planet, left_s = secondsLeft(sim, s), surveyed = s.survey ~= nil }
  end
  return out
end

-- Mission V2 ---------------------------------------------------------------------------------------------------------

-- -> { id, name, brief, hint, status = locked|active|complete|claimed, reward }
function Salvage.mission(sim)
  local d = Cfg.mission
  return { id = d.id, name = d.name, brief = d.brief, hint = d.hint, status = sim.salvage.mission.status, reward = "1 blueprint" }
end

function Salvage.claimMission(sim)
  local e = sim.salvage and sim.salvage.mission
  if not e or e.status == "claimed" then return false, "already_claimed" end
  if e.status ~= "complete" then return false, "not_complete" end
  local name = Salvage.grantBlueprint(sim)
  e.status = "claimed"
  sim:log("INFO", ("mission %s claimed: %s"):format(Cfg.mission.id, name))
  sim:emit("mission_claimed", { id = Cfg.mission.id, reward = { blueprint = name } })
  return true, { blueprint = name }
end

-- Validation -----------------------------------------------------------------------------------------------------------

local function goodQty(q) return q == nil or q == "all" or (type(q) == "number" and q == math.floor(q) and q >= 1) end

-- Which buyer takes which good: hmc = ores, scrap and refined parts at the depot rate; a market = what its price table lists;
-- scrap at Orbis and the data cores at Meridian are fixed prices.
local function buys(sim, buyer, good)
  local g = Cfg.loot.goods[good]
  if buyer == "hmc" then return good ~= "data_core" end
  if g then
    if good == "scrap" then return buyer == "orbis" end
    return buyer == g.buyer
  end
  return Market.has(sim.market, buyer, good)
end

local function sellable(sim, ship, buyer, resource)
  local n = 0
  for good, q in pairs(ship.hold) do
    if q > 0 and (resource == nil or resource == good) and buys(sim, buyer, good) then n += q end
  end
  return n
end

function Salvage.validate(sim, agent, n, args)
  local ship = Salvage.shipFor(sim, agent.id)
  if not ship then return false, "no_ship" end
  if n == "report" then
    if args.to ~= nil and args.to ~= "player" then
      if args.to == agent.id or type(args.to) ~= "string" or not sim.agents[args.to] then return false, "unknown_recipient" end
    end
    return true
  end
  if ship.state == "disabled" then return false, "disabled" end
  if n == "survey" or n == "salvage" then
    if ship.state ~= "idle" then return false, "ship busy" end
    local site = findSite(sim, args.site or "")
    if not site or sim.tick >= site.expires then return false, "site_expired" end
    if not inRange(sim, site.planet) then return false, "out_of_range" end
    local seconds
    if n == "survey" then
      if site.survey then return false, "already_surveyed" end
      seconds = Cfg.ship.surveySeconds
    else
      local layer = args.layer
      if type(layer) ~= "number" or layer ~= math.floor(layer) or layer < 1 or layer > Cfg.sites.layers then return false, "bad layer" end
      local l = site.layers[layer]
      if l.done or l.takenBy then return false, "layer_taken" end
      if layer > 1 and not site.layers[layer - 1].done then return false, "layer_locked" end
      if holdTotal(ship) >= ship.cap then return false, "hold_full" end
      seconds = Cfg.ship.salvageSecondsPerLayer * layer
    end
    if sim.tick + sim:ticks(legSeconds(sim, ship.at, site.planet) + seconds) >= site.expires then return false, "site_expired" end
  elseif n == "return" then
    if docked(sim, ship) then return false, "already_docked" end
    if ship.state ~= "idle" then return false, "ship busy" end
    if args.to ~= nil and args.to ~= "home" and args.to ~= "local_depot" then return false, "bad dock" end
  elseif n == "repair" then
    if not docked(sim, ship) then return false, "not_docked" end
    if ship.hull >= ship.hullMax then return false, "nothing_to_repair" end
    if sim.resources.credits < repairCost(ship) then return false, "not_enough_credits" end
  elseif n == "sell" then
    local buyer = args.buyer or "hmc"
    if buyer ~= "hmc" and not World.markets[buyer] then return false, "buyer_locked" end
    if buyer ~= "hmc" and not sim:marketUnlocked(buyer) then return false, "buyer_locked" end
    if not docked(sim, ship) then return false, "not_docked" end
    if buyer ~= "hmc" and not sim:hasWarehouse() then return false, "not_docked" end
    if holdTotal(ship) <= 0 then return false, "not_enough_stock" end
    if not goodQty(args.qty) then return false, "bad qty" end
    local have = sellable(sim, ship, buyer, args.resource)
    if have <= 0 then return false, "not_enough_stock" end
    if type(args.qty) == "number" and args.resource ~= nil and args.qty > (ship.hold[args.resource] or 0) then return false, "not_enough_stock" end
  elseif n == "store" then
    local st = sim:storingStation(sim.home)
    local res = args.resource
    if type(res) ~= "string" or Cfg.loot.goods[res] or not (sim.warehouse[res] ~= nil or (st and st.stock[res] ~= nil)) then return false, "bad resource" end
    if not goodQty(args.qty) then return false, "bad qty" end
    if not sim:hasWarehouse() then return false, "no_warehouse" end
    if not docked(sim, ship) or not st then return false, "not_docked" end
    if (ship.hold[res] or 0) <= 0 then return false, "not_enough_stock" end
    if type(args.qty) == "number" and args.qty > ship.hold[res] then return false, "not_enough_stock" end
    if Logistics.room(sim, st) <= 0 then return false, "warehouse_full" end
  elseif n == "wait" then
    local s = args.seconds
    if type(s) ~= "number" or s < sim.b.waitMinSeconds or s > sim.b.waitMaxSeconds then return false, "bad seconds" end
    if ship.state ~= "idle" then return false, "ship busy" end
  end
  return true
end

-- Tool effects -----------------------------------------------------------------------------------------------------------

local function finishEntry(sim, ship, text, ok)
  local e = ship.feedEntry
  if e and e.status == "running" then Feed.finish(sim, e, text, ok) end
  ship.feedEntry = nil
end

local function unitValue(sim, buyer, good, qty)
  local g = Cfg.loot.goods[good]
  local factor = Raiding.priceFactor(sim, buyer)
  if buyer == "hmc" then
    local depot = sim.planets[sim.home].depotRate
    local base = g and g.price * (g.depotRate or 0) / depot or (World.ores[good] and World.ores[good].basePrice or BranchesCfg.refining.recipes[good].price)
    return math.floor(qty * depot * base * factor)
  end
  if g then
    local rate = good == "scrap" and g.orbisRate or 1
    return math.floor(qty * g.price * rate * factor)
  end
  local _, total = Market.sell(sim.market, buyer, good, qty)
  return math.floor(total * factor)
end

local function sellHold(sim, ship, agentId, args, rid)
  local buyer = args.buyer or "hmc"
  local want = type(args.qty) == "number" and args.qty or nil
  local goods = {}
  for good, q in pairs(ship.hold) do
    if q > 0 and (args.resource == nil or args.resource == good) and buys(sim, buyer, good) then goods[#goods + 1] = good end
  end
  table.sort(goods)
  local total, sold = 0, {}
  for _, good in ipairs(goods) do
    local qty = math.min(ship.hold[good], want or ship.hold[good])
    local gain = unitValue(sim, buyer, good, qty)
    ship.hold[good] = ship.hold[good] - qty
    if ship.hold[good] <= 0 then ship.hold[good] = nil end
    total += gain
    sold[#sold + 1] = ("%d %s"):format(qty, good)
    sim:log("INFO", ("%s sold %d %s for %d"):format(agentId, qty, good, gain))
    sim:credit(agentId, rid, gain)
  end
  return total, table.concat(sold, ", ")
end

function Salvage.apply(sim, agentId, call, opts)
  local ship = Salvage.shipFor(sim, agentId)
  local n, args = call.name, call.args or {}
  local rid = opts and opts.record
  local cfg = Cfg.ship

  if n == "wait" then
    sim.agents[agentId].waitUntil = sim.tick + sim:ticks(args.seconds)
    Feed.finish(sim, Feed.begin(sim, agentId, call, sim:takeReasoning(), rid), "waiting")
    return true
  elseif n == "report" then
    local entry = Feed.begin(sim, agentId, call, sim:takeReasoning(), rid)
    sim:log("INFO", agentId .. " report: " .. tostring(args.message))
    Feed.finish(sim, entry, "sent")
    if args.to ~= nil and args.to ~= "player" then sim:deliver(args.to, ("from %s: %s"):format(agentId, tostring(args.message)))
    else Feed.info(sim, agentId, tostring(args.message)) end
    return true
  end

  local entry = Feed.begin(sim, agentId, call, sim:takeReasoning(), rid)
  ship.feedEntry, ship.recordId = entry, rid
  if n == "survey" then
    local site = findSite(sim, args.site)
    ship.state, ship.job = "surveying", { site = site.id }
    ship.timer = sim:ticks(legSeconds(sim, ship.at, site.planet) + cfg.surveySeconds)
  elseif n == "salvage" then
    local site = findSite(sim, args.site)
    site.layers[args.layer].takenBy = ship.id
    ship.state, ship.job = "salvaging", { site = site.id, layer = args.layer }
    ship.timer = sim:ticks(legSeconds(sim, ship.at, site.planet) + cfg.salvageSecondsPerLayer * args.layer)
  elseif n == "return" then
    ship.state, ship.job = "returning", nil
    ship.timer = sim:ticks(legSeconds(sim, ship.at, sim.home))
  elseif n == "repair" then
    local missing, cost = ship.hullMax - ship.hull, repairCost(ship)
    sim.resources.credits -= cost
    ship.state, ship.timer = "repairing", sim:ticks(math.ceil(missing / 10) * cfg.repairSecondsPer10)
    sim:log("INFO", ("%s repairs %d hull for %d cr"):format(agentId, missing, cost))
  elseif n == "sell" then
    local total, what = sellHold(sim, ship, agentId, args, rid)
    finishEntry(sim, ship, ("sold %s, +%d cr"):format(what, total))
  elseif n == "store" then
    local res = args.resource
    local want = (args.qty == nil or args.qty == "all") and ship.hold[res] or args.qty
    local st = sim:storingStation(sim.home)
    local amt = math.min(want, ship.hold[res], Logistics.room(sim, st))
    st.stock[res] = (st.stock[res] or 0) + amt
    ship.hold[res] = ship.hold[res] - amt
    if ship.hold[res] <= 0 then ship.hold[res] = nil end
    sim:log("INFO", ("%s stored %d %s"):format(agentId, amt, res))
    finishEntry(sim, ship, ("%d %s stored"):format(amt, res))
  end
  return true
end

-- Per tick ---------------------------------------------------------------------------------------------------------------

local STEP_OF = { poor = 1, fair = 2, rich = 3 }

local function surveyResult(sim, site)
  local c = Cfg.sites
  local bands = {}
  for i, l in ipairs(site.layers) do
    local errRoll, dirRoll = draw(sim, "loot"), draw(sim, "loot")
    local idx = STEP_OF[l.quality]
    if errRoll < c.bandError then
      if idx == 1 then idx = 2 elseif idx == #c.qualities then idx = #c.qualities - 1 else idx = idx + (dirRoll < 0.5 and -1 or 1) end
    end
    bands[i] = c.qualities[idx]
  end
  site.survey = { type = site.type, danger = site.danger, bands = bands }
end

local function lootKind(good)
  if good == "scrap" then return "scrap" end
  if good == "data_core" then return "data_core" end
  if World.ores[good] then return "ore" end
  return "refined"
end

-- One salvage call's loot: `layer` rolls from the site type's table. -> { good = qty }, blueprints found
local function rollLoot(sim, site, layer)
  local c = Cfg.loot
  local list = c.tableFor[site.type][layer]
  local mult = c.qualityMult[site.layers[layer].quality]
  local loot, blueprints = {}, 0
  for _ = 1, c.rolls[layer] do
    local iRoll, qRoll, bRoll = draw(sim, "loot"), draw(sim, "loot"), draw(sim, "loot")
    local good = pickWeighted(list, iRoll)
    local range = c.qty[lootKind(good)]
    local qty = math.max(1, math.floor((range[1] + math.floor(qRoll * (range[2] - range[1] + 1))) * mult + 0.5))
    loot[good] = (loot[good] or 0) + qty
    if layer == Cfg.sites.layers and bRoll < c.blueprintChance then blueprints += 1 end
  end
  return loot, blueprints
end

local function sortedKeys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end

local function disable(sim, ship)
  ship.hold, ship.state, ship.at, ship.hull, ship.job = {}, "disabled", sim.home, Cfg.ship.towedHull, nil
  ship.timer = sim:ticks(Cfg.ship.disabledSeconds)
end

local function finishSalvage(sim, ship)
  local site = findSite(sim, ship.job.site)
  local layer = ship.job.layer
  ship.job = nil
  if not site then
    ship.state = "idle"
    finishEntry(sim, ship, "site gone before the work was done", false)
    return
  end
  local c = Cfg.sites
  local l = site.layers[layer]
  l.done = true
  ship.at = site.planet
  local hazRoll, dmgRoll = draw(sim, "loot"), draw(sim, "loot")
  local hazard = hazRoll < site.danger * c.hazardPerDangerLayer * layer
  local damage = hazard and (Cfg.ship.hazardDamageMin + math.floor(dmgRoll * (Cfg.ship.hazardDamageMax - Cfg.ship.hazardDamageMin + 1))) or 0
  local note = ""
  if hazard then
    ship.hull -= damage
    sim:log("WARN", ("%s: hazard at %s layer %d, hull -%d"):format(ship.id, site.id, layer, damage))
    sim:emit("hazard", { ship = ship.id, site = site.id, layer = layer, damage = damage })
    note = (", hazard: hull -%d (%d/%d)"):format(damage, math.max(ship.hull, 0), ship.hullMax)
  end
  if ship.hull <= 0 then
    disable(sim, ship)
    local text = ("%s layer %d: hazard, hull -%d, ship disabled: cargo lost, towed home (%d s)"):format(site.id, layer, damage, Cfg.ship.disabledSeconds)
    finishEntry(sim, ship, text, false)
    if ship.owner then sim:deliver(ship.owner, ("%s was disabled by a hazard at %s (danger %d, layer %d)"):format(ship.id, site.id, site.danger, layer)) end
    sim:log("WARN", ("%s disabled"):format(ship.id))
    return
  end
  ship.state = "idle"
  local loot, blueprints = rollLoot(sim, site, layer)
  local room, parts = ship.cap - holdTotal(ship), {}
  for _, good in ipairs(sortedKeys(loot)) do
    local got = math.min(loot[good], room)
    if got > 0 then
      ship.hold[good] = (ship.hold[good] or 0) + got
      room -= got
      parts[#parts + 1] = ("%d %s"):format(got, good)
    end
  end
  for _ = 1, blueprints do parts[#parts + 1] = "blueprint: " .. Salvage.grantBlueprint(sim) end
  local m = sim.salvage.mission
  if layer == Cfg.mission.layer and m.status == "active" then
    m.status = "complete"
    sim:log("INFO", ("mission %s complete: %s"):format(Cfg.mission.id, Cfg.mission.name))
    sim:emit("mission_complete", { id = Cfg.mission.id })
  end
  sim:emit("salvaged", { ship = ship.id, site = site.id, layer = layer })
  finishEntry(sim, ship, ("%s layer %d: %s%s"):format(site.id, layer, #parts > 0 and table.concat(parts, ", ") or "nothing", note), true)
end

function Salvage.step(sim)
  if not open(sim) then return end
  local st = sim.salvage
  if st.nextSpawn and sim.tick >= st.nextSpawn then
    local c = Cfg.sites
    local minutes = c.intervalMinutes + (draw(sim, "site") * 2 - 1) * c.jitterMinutes
    st.nextSpawn = sim.tick + sim:ticks(minutes * 60)
    if #st.sites < c.max then Salvage.spawnSite(sim) end
  end
  local i = 1
  while i <= #st.sites do
    if sim.tick >= st.sites[i].expires then removeSite(sim, st.sites[i]) else i += 1 end
  end
  for _, id in ipairs(sim.salvageOrder) do
    local ship = sim.salvageShips[id]
    local state = ship.state
    if state == "surveying" or state == "salvaging" or state == "returning" or state == "repairing" or state == "disabled" then
      ship.timer -= 1
      if ship.timer <= 0 then
        if state == "surveying" then
          local site = findSite(sim, ship.job.site)
          ship.job, ship.state = nil, "idle"
          if site then
            ship.at = site.planet
            surveyResult(sim, site)
            local rows = {}
            for k, b in ipairs(site.survey.bands) do rows[k] = ("L%d %s"):format(k, b) end
            finishEntry(sim, ship, ("%s at %s: %s, danger %d, %s"):format(site.id, site.planet, Cfg.types[site.type] or site.type, site.danger, table.concat(rows, ", ")))
          else
            finishEntry(sim, ship, "site gone before the survey finished", false)
          end
        elseif state == "salvaging" then
          finishSalvage(sim, ship)
        elseif state == "returning" then
          ship.state, ship.at = "idle", sim.home
          finishEntry(sim, ship, "docked")
        elseif state == "repairing" then
          ship.hull, ship.state = ship.hullMax, "idle"
          finishEntry(sim, ship, ("hull %d/%d"):format(ship.hull, ship.hullMax))
        else
          ship.state = "idle"
        end
      end
    end
  end
  Salvage.claim(sim)
end

-- Alerts -----------------------------------------------------------------------------------------------------------------

function Salvage.detect(sim, _, raise)
  local expiring = Cfg.sites.expiringMinutes * 60
  for _, s in ipairs(sim.salvage.sites) do
    if not s.spawnRaised then
      s.spawnRaised = true
      raise(sim, "site_spawned", nil, ("site %s at %s"):format(s.id, World.abandoned[s.planet].name))
    end
    if not s.expiringRaised and secondsLeft(sim, s) <= expiring then
      s.expiringRaised = true
      raise(sim, "site_expiring", nil, ("site %s at %s has %d min left"):format(s.id, World.abandoned[s.planet].name, Cfg.sites.expiringMinutes))
    end
  end
  for _, id in ipairs(sim.salvageOrder) do
    local ship = sim.salvageShips[id]
    if ship.hull < Cfg.ship.damagedBelow and ship.state ~= "disabled" then
      if not ship.damagedRaised then
        ship.damagedRaised = true
        raise(sim, "ship_damaged", ship.owner, ("%s hull %d/%d"):format(ship.id, ship.hull, ship.hullMax))
      end
    elseif ship.hull >= Cfg.ship.damagedBelow then
      ship.damagedRaised = false
    end
  end
end

-- Agent hooks (skill runner, decisions) ------------------------------------------------------------------------------------

function Salvage.busy(sim, agent)
  local ship = Salvage.shipFor(sim, agent.id)
  return ship ~= nil and ship.state ~= "idle"
end

-- A skill step with nothing to do is skipped instead of aborting the skill. -> reason | nil
function Salvage.skip(sim, agent, call)
  local ship = Salvage.shipFor(sim, agent.id)
  if not ship then return nil end
  local n = call.name
  if n == "return" and docked(sim, ship) then return "already docked" end
  if n == "repair" and docked(sim, ship) and ship.hull >= ship.hullMax then return "hull is full" end
  if n == "sell" and docked(sim, ship) and sellable(sim, ship, call.args.buyer or "hmc", call.args.resource) <= 0 then return "nothing to sell" end
  if n == "survey" then
    local site = findSite(sim, call.args.site or "")
    if site and site.survey then return "already surveyed" end
  end
  return nil
end

function Salvage.needsDecision(sim, agent)
  local ship = Salvage.shipFor(sim, agent.id)
  if not ship then return false end
  return ship.state == "idle" and sim.tick >= (agent.waitUntil or 0)
end

-- Detached snapshot for the decider and the context builder.
function Salvage.context(sim, agent)
  local ship = Salvage.shipFor(sim, agent.id)
  local hold = {}
  for good, q in pairs(ship.hold) do hold[good] = q end
  return {
    tick = sim.tick,
    resources = { credits = sim.resources.credits, compute = sim.resources.compute },
    home = sim.home,
    ship = { id = ship.id, state = ship.state, at = ship.at, hull = ship.hull, hull_max = ship.hullMax, cap = ship.cap,
      hold = hold, hold_total = holdTotal(ship), repair_cost = repairCost(ship) },
    sites = Salvage.siteRows(sim, ship),
    can_meridian = sim:marketUnlocked("meridian") and sim:hasWarehouse(),
  }
end

-- Stub Scavenger (spec §15b.6) -------------------------------------------------------------------------------------------

local function firstNumber(texts, patterns)
  for _, t in ipairs(texts) do
    for _, p in ipairs(patterns) do
      local v = t:match(p)
      if v then return tonumber(v) end
    end
  end
  return nil
end

-- What the directive and the order say (nil = not said).
local function policyOf(agent)
  local texts = { (agent.order or ""):lower(), (agent.directive or ""):lower() }
  local p = {}
  for _, t in ipairs(texts) do
    if t:find("survey first", 1, true) or t:find("survey before", 1, true) or t:find("always survey", 1, true) then p.surveyFirst = true end
  end
  p.maxLayer = firstNumber(texts, { "stop at layer[%s]*(%d)", "max[%a]*[%s]+layer[%s]*(%d)", "up to layer[%s]*(%d)", "no deeper than layer[%s]*(%d)" })
  local avoid = firstNumber(texts, { "avoid danger[%s]*(%d)", "skip danger[%s]*(%d)" })
  local above = firstNumber(texts, { "danger above[%s]*(%d)", "danger over[%s]*(%d)" })
  p.maxDanger = above or (avoid and avoid - 1) or nil
  p.repairBelow = firstNumber(texts, { "repair below[%s]*(%d+)", "return below[%s]*(%d+)", "repair under[%s]*(%d+)", "hull below[%s]*(%d+)", "hull under[%s]*(%d+)" })
  return p
end

local OPTIMAL = { surveyFirst = true, maxDanger = 2, repairBelow = 50 }

local function decide(sim, ctx, p)
  local c = Cfg.stub
  local sh = ctx.ship
  local function wait(s) return { name = "wait", args = { seconds = math.max(sim.b.waitMinSeconds, math.min(sim.b.waitMaxSeconds, math.floor(s))) } } end
  if sh.state == "disabled" then return wait(c.waitSeconds) end
  local isDocked = sh.at == ctx.home
  local function goHome()
    if not isDocked then return { name = "return", args = {} } end
    return nil
  end
  local function repair()
    if not isDocked then return { name = "return", args = {} } end
    if sh.hull < sh.hull_max and ctx.resources.credits >= sh.repair_cost then return { name = "repair", args = {} } end
    return nil
  end
  local repairAt = p.repairBelow or c.repairAt
  if sh.hull < repairAt then
    local a = repair()
    if a then return a end
  end
  if isDocked and sh.hold_total > 0 then
    local other = false
    for good, q in pairs(sh.hold) do if q > 0 and good ~= "data_core" then other = true end end
    if other then return { name = "sell", args = {} } end
    if (sh.hold.data_core or 0) > 0 and ctx.can_meridian then return { name = "sell", args = { buyer = "meridian" } } end
  end
  if not isDocked and sh.hold_total >= sh.cap then return goHome() end
  local cap = Cfg.ship.hazardDamageMax
  local needsRepair = false
  for _, row in ipairs(ctx.sites) do
    if row.reach then
      local nl = row.next_layer
      local fits = row.survey_s < row.left_s
      if p.surveyFirst and not row.surveyed then
        if fits then return { name = "survey", args = { site = row.id } } end
      elseif nl and not (p.maxLayer and nl > p.maxLayer) and row.next_s < row.left_s
        and not (row.danger and p.maxDanger and row.danger > p.maxDanger) then
        local depth = p.maxLayer
        if not depth and not row.surveyed then depth = 1 + (tonumber(row.id:match("%d+")) * 7 + sim.seed) % Cfg.sites.layers end
        if not depth or nl <= depth then
          if row.danger and row.danger > 0 and sh.hull <= cap then
            needsRepair = true
          else
            return { name = "salvage", args = { site = row.id, layer = nl } }
          end
        end
      end
    end
  end
  if needsRepair then
    local a = repair()
    if a then return a end
  end
  if not isDocked and sh.hold_total > 0 then return goHome() end
  return wait(c.waitSeconds)
end

function Salvage.stubDirective(sim, agentId, ctx) return decide(sim, ctx, policyOf(sim.agents[agentId])) end
function Salvage.stubOptimal(sim, _, ctx) return decide(sim, ctx, OPTIMAL) end

return Salvage
