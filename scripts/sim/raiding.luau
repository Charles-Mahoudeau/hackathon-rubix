-- Raiding (spec §15b.4, B-c): rival convoys as real entities, interceptors, combat, Notoriety, standing, retaliation and the
-- Privateer's tools and stub. Pure sim logic, headless: no UI calls; the UI reads `sim.raid`, `sim.interceptors` and events.
-- Numbers: config/branches.luau `raiding`. Streams: `rng.convoy` (spawns), `rng.combat` (fights and retaliation).
-- State: sim.raid = { convoys, convoySeq, notoriety, notorietyTick, standing, fights, attacks, wins, lastAttackTick, highRaised, mission }.
local World = require("@scripts/config/world")
local Cfg = require("@scripts/config/branches").raiding
local Feed = require("./feed")
local Market = require("./market")
local Rng = require("./rng")
local Alerts = require("./alerts")
local Logistics = require("./logistics")

local Raiding = {}

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end

-- Streams are created on first use, so a save from before this branch still loads.
local function draw(sim, key)
  if sim.rng[key] == nil then sim.rng[key] = Rng.seedFor(sim.seed, Cfg.streams[key]) end
  return Rng.next(sim.rng, key)
end

local function isOrange(dest)
  for _, r in ipairs(Cfg.orangeRoutes) do if r == dest then return true end end
  return false
end

function Raiding.isOrange(dest) return isOrange(dest) end
function Raiding.orangeRoutes() return Cfg.orangeRoutes end

function Raiding.init(sim)
  sim.interceptors, sim.interceptorOrder = {}, {}
  local standing = {}
  for _, c in ipairs(Cfg.convoy.corporations) do standing[c] = 0 end
  sim.raid = { convoys = {}, convoySeq = 0, notoriety = 0, notorietyTick = 0, standing = standing, fights = {}, attacks = 0, wins = 0,
    lastAttackTick = nil, highRaised = false, mission = { status = "locked", wins = 0, failed = false } }
end

local function open(sim) return sim.branchesOpen.raiding == true end
function Raiding.isOpen(sim) return open(sim) end

-- Interceptors -----------------------------------------------------------------------------------------------------

function Raiding.addInterceptor(sim, id, owner)
  local c = Cfg.interceptor
  local it = { id = id, owner = owner, state = "idle", at = sim.home, hold = {}, hull = c.hull, hullMax = c.hull, attack = c.attack,
    cap = c.hold, timer = 0, target = nil, scans = {} }
  sim.interceptors[id] = it
  sim.interceptorOrder[#sim.interceptorOrder + 1] = id
  return it
end

function Raiding.interceptorFor(sim, agentId)
  for _, id in ipairs(sim.interceptorOrder) do
    if sim.interceptors[id].owner == agentId then return sim.interceptors[id] end
  end
  return nil
end

local function holdTotal(it)
  local n = 0
  for _, q in pairs(it.hold) do n += q end
  return n
end

function Raiding.holdTotal(it) return holdTotal(it) end

local function docked(sim, it) return it.state == "idle" and it.at == sim.home end

-- A Privateer for an interceptor nobody commands, once the command capacity has room (spec §5.3).
function Raiding.claim(sim)
  for _, id in ipairs(sim.interceptorOrder) do
    local it = sim.interceptors[id]
    if not it.owner and #sim.agentOrder < sim:commandCapacity() then
      local n = 1
      while sim.agents["privateer" .. (n + 1)] do n += 1 end
      local aid = "privateer" .. (n + 1)
      sim:addAgent(aid, "privateer", { tier = sim.tier })
      it.owner = aid
      sim:log("INFO", ("%s: new Privateer agent for %s (empty directive)"):format(aid, id))
      sim:emit("agent_added", { agent = aid, ship = id })
    end
  end
end

-- Shop: interceptors #2 and #3 (ladder in config), listed only once the branch is open --------------------------------------

local SHOP_IDS = { "interceptor2", "interceptor3" }

local function shopIndex(id)
  for i, v in ipairs(SHOP_IDS) do if v == id then return i + 1 end end
  return nil
end

function Raiding.shopIndex(id) return shopIndex(id) end

-- Why interceptor #k cannot be bought now, or nil.
function Raiding.shopBlocker(sim, id)
  local k = shopIndex(id)
  if not k or not open(sim) then return "unknown_item" end
  if #sim.interceptorOrder >= k then return "already_owned" end
  if #sim.interceptorOrder < k - 1 then return "needs_" .. SHOP_IDS[k - 2] end
  if sim.resources.credits < Cfg.ladder[k] then return "not_enough_credits" end
  return nil
end

function Raiding.shopRows(sim)
  local rows = {}
  if not open(sim) then return rows end
  for i, id in ipairs(SHOP_IDS) do
    local k = i + 1
    local why = Raiding.shopBlocker(sim, id)
    local state = "available"
    if why == "already_owned" then state = "owned"
    elseif why == "not_enough_credits" then state = "unaffordable"
    elseif why then state = "locked" end
    rows[#rows + 1] = { id = id, name = ("Interceptor #%d"):format(k), desc = "+1 interceptor and an empty Privateer agent",
      cost = Cfg.ladder[k], state = state, blocker = why, tier = sim.tier }
  end
  return rows
end

function Raiding.shopBuy(sim, id)
  local why = Raiding.shopBlocker(sim, id)
  if why then
    sim:log("ERROR", ("shop: cannot buy %s (%s)"):format(tostring(id), why))
    return false, why
  end
  local k = shopIndex(id)
  sim.resources.credits = sim.resources.credits - Cfg.ladder[k]
  Raiding.addInterceptor(sim, "i" .. k, nil)
  Raiding.claim(sim)
  sim:log("INFO", ("shop: bought interceptor #%d for %d cr"):format(k, Cfg.ladder[k]))
  sim:emit("upgrade_bought", { id = id })
  return true
end

-- Convoys ----------------------------------------------------------------------------------------------------------

local function findConvoy(sim, id)
  for _, c in ipairs(sim.raid.convoys) do if c.id == id then return c end end
  return nil
end

local function removeConvoy(sim, c)
  for i, x in ipairs(sim.raid.convoys) do
    if x == c then table.remove(sim.raid.convoys, i) return end
  end
end

-- Escort level 0-2 by weight; a corporation hostile to the player adds one (spec §15b.4).
local function escortLevel(sim, corp)
  local w, roll = Cfg.convoy.escortWeights, draw(sim, "convoy")
  local level, acc = #w - 1, 0
  for i, share in ipairs(w) do
    acc += share
    if roll < acc then level = i - 1 break end
  end
  if sim.raid.standing[corp] <= Cfg.standing.hostileAt then level = math.min(#w - 1 + Cfg.standing.escortBonus, level + Cfg.standing.escortBonus) end
  return level
end

-- The market's rival-sale hook: with this branch open the sale becomes a convoy that travels to its market first
-- (market.luau then skips the scripted sale and the market sees it on arrival). -> true when handled.
function Raiding.spawnConvoy(sim, m)
  if not open(sim) then return false end
  local cc = Cfg.convoy
  local orange = draw(sim, "convoy") < cc.orangeShare
  local routes = orange and Cfg.orangeRoutes or Cfg.blueRoutes
  local dest = routes[1 + math.floor(draw(sim, "convoy") * #routes)]
  local mk = m.markets[dest]
  local ore = mk.order[1 + math.floor(draw(sim, "convoy") * #mk.order)]
  local qty = cc.qtyMin + math.floor(draw(sim, "convoy") * (cc.qtyMax - cc.qtyMin + 1))
  local corp = cc.corporations[1 + math.floor(draw(sim, "convoy") * #cc.corporations)]
  local raid = sim.raid
  raid.convoySeq += 1
  local c = { id = "C" .. raid.convoySeq, corp = corp, resource = ore, qty = qty, escort = escortLevel(sim, corp), dest = dest,
    from = sim.home, total = sim:ticks(World.freighterRoutes[sim.home][dest]), elapsed = 0, state = "travel" }
  raid.convoys[#raid.convoys + 1] = c
  sim:emit("convoy_spawned", { convoy = c.id, corp = corp, dest = dest, orange = orange })
  return true
end

local function qtyBand(qty)
  for _, b in ipairs(Cfg.convoy.qtyBands) do if qty <= b.upTo then return b.name end end
  return "large"
end

local function bandLevel(band)
  for lvl = 0, 2 do if Cfg.convoy.escortBands[lvl] == band then return lvl end end
  return 2
end

local function etaSeconds(sim, c) return math.floor((c.total - c.elapsed) * sim.b.tickSeconds + 0.5) end

-- Convoys on the map, as dots: { id, from, to, t, corp, orange }. Nothing about the cargo.
function Raiding.mapConvoys(sim)
  local out = {}
  if not sim.raid or not open(sim) then return out end
  for _, c in ipairs(sim.raid.convoys) do
    out[#out + 1] = { id = c.id, from = c.from, to = c.dest, t = clamp(c.elapsed / c.total, 0, 1), corp = c.corp, orange = isOrange(c.dest) }
  end
  return out
end

-- Notoriety and standing -------------------------------------------------------------------------------------------

function Raiding.notoriety(sim) return sim.raid and sim.raid.notoriety or 0 end

function Raiding.blacklisted(sim) return open(sim) and sim.raid.notoriety >= Cfg.notoriety.blacklistAt end

-- What HMC depots and Orbis pay, relative to normal (spec §15b.4). Other buyers are not affected.
function Raiding.priceFactor(sim, buyer)
  if (buyer == "hmc" or buyer == "orbis") and Raiding.blacklisted(sim) then return 1 - Cfg.notoriety.blacklistPenalty end
  return 1
end

local function addNotoriety(sim)
  local raid = sim.raid
  raid.notoriety = math.min(Cfg.notoriety.max, raid.notoriety + 1)
  raid.notorietyTick = sim.tick
  local e = raid.mission
  if raid.notoriety >= Cfg.notoriety.blacklistAt and e.status == "active" and not e.failed then
    e.failed = true
    sim:log("WARN", ("mission %s: Notoriety reached %d, restart needed"):format(Cfg.mission.id, raid.notoriety))
  end
  sim:emit("notoriety_changed", { notoriety = raid.notoriety })
end

local function decayNotoriety(sim)
  local raid = sim.raid
  if raid.notoriety > 0 and sim.tick - raid.notorietyTick >= sim:ticks(Cfg.notoriety.decayMinutes * 60) then
    raid.notoriety -= 1
    raid.notorietyTick = sim.tick
    for corp, s in pairs(raid.standing) do if s < 0 then raid.standing[corp] = s + 1 end end
    sim:log("INFO", ("Notoriety fell to %d"):format(raid.notoriety))
    sim:emit("notoriety_changed", { notoriety = raid.notoriety })
  end
  if raid.notoriety < Cfg.notoriety.blacklistAt then raid.highRaised = false end
end

-- A player freighter reaches an orange market while Notoriety >= 3: it may lose part of its cargo (retaliation).
-- Mutates the load. -> units lost
function Raiding.retaliation(sim, f)
  if not open(sim) then return 0 end
  local n, l = sim.raid.notoriety, f.load
  if n < Cfg.notoriety.retaliationAt or not isOrange(l.destination) then return 0 end
  if draw(sim, "combat") >= Cfg.notoriety.retaliationChancePerLevel * n then return 0 end
  local lost = math.floor(l.qty * Cfg.notoriety.retaliationLoss)
  if lost < 1 then return 0 end
  l.qty -= lost
  local text = ("%s was raided on the way to %s: %d %s lost"):format(f.id, l.destination, lost, l.resource)
  sim:log("WARN", "retaliation: " .. text)
  if f.owner then sim:deliver(f.owner, text) end
  Alerts.raise(sim, "retaliation", f.owner, text)
  sim:emit("retaliation", { freighter = f.id, destination = l.destination, resource = l.resource, lost = lost })
  return lost
end

-- Mission V3 -------------------------------------------------------------------------------------------------------

-- -> { id, name, goal, hint, reward, status = locked|active|complete|claimed, wins, target, failed }
function Raiding.mission(sim)
  local e, d = sim.raid.mission, Cfg.mission
  return { id = d.id, name = d.name, goal = d.goal, hint = d.hint, reward = d.reward, status = e.status, wins = e.wins,
    target = d.wins, failed = e.failed == true }
end

function Raiding.claimMission(sim)
  local e = sim.raid and sim.raid.mission
  if not e or e.status == "claimed" then return false, "already_claimed" end
  if e.status ~= "complete" then return false, "not_complete" end
  sim.resources.credits += Cfg.mission.reward
  e.status = "claimed"
  sim:log("INFO", ("mission %s claimed: +%d cr"):format(Cfg.mission.id, Cfg.mission.reward))
  sim:emit("mission_claimed", { id = Cfg.mission.id, reward = { credits = Cfg.mission.reward } })
  return true, { credits = Cfg.mission.reward }
end

function Raiding.retryMission(sim)
  local e = sim.raid and sim.raid.mission
  if not e or e.status ~= "active" then return false, "not_active" end
  e.wins, e.failed = 0, false
  sim:log("INFO", ("mission %s restarted"):format(Cfg.mission.id))
  return true
end

-- Scans and chase ----------------------------------------------------------------------------------------------------

local function repairCost(it) return (it.hullMax - it.hull) * Cfg.interceptor.repairCreditsPerHull end

-- Ticks the interceptor needs to reach convoy `c` from the dock (it flies faster, the convoy keeps moving); nil: out of reach.
local function chaseTicks(sim, c)
  local cfg = Cfg.interceptor
  local t = math.max(sim:ticks(cfg.minChaseSeconds), math.ceil(c.elapsed / (cfg.chaseSpeed - 1)))
  if c.elapsed + t >= c.total - 1 then return nil end
  return t
end

-- The fresh scan results of an interceptor: { id, route, owner, resource, cargo, escort, eta_s }.
local function scanRows(sim, it)
  local rows, keep = {}, sim:ticks(Cfg.convoy.scanKeepSeconds)
  local routes = {}
  for r in pairs(it.scans) do routes[#routes + 1] = r end
  table.sort(routes)
  for _, r in ipairs(routes) do
    local s = it.scans[r]
    if sim.tick - s.tick <= keep then
      for _, e in ipairs(s.convoys) do
        local c = findConvoy(sim, e.id)
        if c and c.state == "travel" then
          rows[#rows + 1] = { id = e.id, route = r, owner = e.owner, resource = e.resource, cargo = e.cargo, escort = e.escort, eta_s = etaSeconds(sim, c),
            reach = chaseTicks(sim, c) ~= nil }
        end
      end
    end
  end
  return rows
end

-- A skill's `convoy` parameter: { max_escort = 0..2, resources = { "iridium", ... } } -> the first fresh scanned convoy that fits.
local function matchConvoy(sim, it, filter)
  for _, row in ipairs(scanRows(sim, it)) do
    local c = findConvoy(sim, row.id)
    local ok = c ~= nil and chaseTicks(sim, c) ~= nil
    if ok and filter.max_escort and bandLevel(row.escort) > filter.max_escort then ok = false end
    if ok and filter.resources then
      local has = false
      for _, r in ipairs(filter.resources) do if r == row.resource then has = true end end
      ok = has
    end
    if ok then return c end
  end
  return nil
end

local function goodQty(q) return q == nil or q == "all" or (type(q) == "number" and q == math.floor(q) and q >= 1) end

function Raiding.validate(sim, agent, n, args)
  local it = Raiding.interceptorFor(sim, agent.id)
  if not it then return false, "no_interceptor" end
  if n == "report" then
    if args.to ~= nil and args.to ~= "player" then
      if args.to == agent.id or type(args.to) ~= "string" or not sim.agents[args.to] then return false, "unknown_recipient" end
    end
    return true
  end
  if it.state == "disabled" then return false, "disabled" end
  if n == "scan_route" then
    if not isOrange(args.route or "") then return false, "bad route" end
    if it.state ~= "idle" then return false, "ship busy" end
  elseif n == "intercept" then
    if it.state ~= "idle" then return false, "ship busy" end
    if holdTotal(it) >= it.cap then return false, "hold_full" end
    if type(args.convoy) == "table" then
      if not matchConvoy(sim, it, args.convoy) then return false, "no_match" end
    else
      local c = findConvoy(sim, args.convoy or "")
      if not c or c.state ~= "travel" then return false, "convoy_gone" end
      if not isOrange(c.dest) then return false, "not_raidable" end
      if not chaseTicks(sim, c) then return false, "out_of_reach" end
    end
  elseif n == "attack" or n == "retreat" then
    if it.state ~= "alongside" then return false, "not_intercepting" end
    if n == "attack" then
      local c = findConvoy(sim, it.target or "")
      if not c or c.state ~= "travel" then return false, "convoy_gone" end
    end
  elseif n == "return" then
    if docked(sim, it) then return false, "already_docked" end
    if it.state ~= "idle" and it.state ~= "alongside" then return false, "ship busy" end
    if args.to ~= nil and args.to ~= "home" and args.to ~= "local_depot" then return false, "bad dock" end
  elseif n == "repair" then
    if not docked(sim, it) then return false, "not_docked" end
    if it.hull >= it.hullMax then return false, "nothing_to_repair" end
    if sim.resources.credits < repairCost(it) then return false, "not_enough_credits" end
  elseif n == "sell" then
    local buyer = args.buyer or "hmc"
    if buyer ~= "hmc" and buyer ~= "orbis" then return false, "buyer_locked" end
    if buyer == "orbis" and not sim:marketUnlocked("orbis") then return false, "buyer_locked" end
    if not docked(sim, it) then return false, "not_docked" end
    if buyer == "orbis" and not sim:hasWarehouse() then return false, "not_docked" end
    if holdTotal(it) <= 0 then return false, "not_enough_stock" end
    if args.resource ~= nil and (it.hold[args.resource] or 0) <= 0 then return false, "not_enough_stock" end
    if not goodQty(args.qty) then return false, "bad qty" end
    if type(args.qty) == "number" and args.resource ~= nil and args.qty > it.hold[args.resource] then return false, "not_enough_stock" end
  elseif n == "store" then
    if sim.warehouse[args.resource or ""] == nil then return false, "bad resource" end
    if not goodQty(args.qty) then return false, "bad qty" end
    if not sim:hasWarehouse() then return false, "no_warehouse" end
    local st = sim:storingStation(sim.home)
    if not docked(sim, it) or not st then return false, "not_docked" end
    if (it.hold[args.resource] or 0) <= 0 then return false, "not_enough_stock" end
    if type(args.qty) == "number" and args.qty > it.hold[args.resource] then return false, "not_enough_stock" end
    if Logistics.room(sim, st) <= 0 then return false, "warehouse_full" end
  elseif n == "wait" then
    local s = args.seconds
    if type(s) ~= "number" or s < sim.b.waitMinSeconds or s > sim.b.waitMaxSeconds then return false, "bad seconds" end
    if it.state ~= "idle" then return false, "ship busy" end
  end
  return true
end

-- Tool effects -----------------------------------------------------------------------------------------------------

local function finishEntry(sim, it, text, ok)
  local e = it.feedEntry
  if e and e.status == "running" then Feed.finish(sim, e, text, ok) end
  it.feedEntry = nil
end

local function sellHold(sim, it, agentId, args, rid)
  local buyer = args.buyer or "hmc"
  local want = type(args.qty) == "number" and args.qty or nil
  local ores = {}
  for ore, q in pairs(it.hold) do
    if q > 0 and (args.resource == nil or args.resource == ore) then ores[#ores + 1] = ore end
  end
  table.sort(ores)
  local total, sold = 0, {}
  local depot = sim.planets[sim.home].depotRate
  for _, ore in ipairs(ores) do
    local qty = math.min(it.hold[ore], want or it.hold[ore])
    local gain
    if buyer == "orbis" then
      local _, t = Market.sell(sim.market, "orbis", ore, qty)
      gain = math.floor(t * Raiding.priceFactor(sim, "orbis"))
    else
      gain = math.floor(qty * depot * World.ores[ore].basePrice * Raiding.priceFactor(sim, "hmc"))
    end
    it.hold[ore] = it.hold[ore] - qty
    if it.hold[ore] <= 0 then it.hold[ore] = nil end
    total += gain
    sold[#sold + 1] = ("%d %s"):format(qty, ore)
    sim:log("INFO", ("%s sold %d %s for %d"):format(agentId, qty, ore, gain))
    sim:credit(agentId, rid, gain)
  end
  return total, table.concat(sold, ", ")
end

-- opts.record: the decision-log record id; opts.auto: no feed line.
function Raiding.apply(sim, agentId, call, opts)
  local it = Raiding.interceptorFor(sim, agentId)
  local n, args = call.name, call.args or {}
  local rid = opts and opts.record
  local cfg = Cfg.interceptor

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
  it.feedEntry, it.recordId = entry, rid
  if n == "scan_route" then
    it.state, it.timer, it.scanRoute = "scanning", sim:ticks(cfg.scanSeconds), args.route
  elseif n == "intercept" then
    local c = type(args.convoy) == "table" and matchConvoy(sim, it, args.convoy) or findConvoy(sim, args.convoy)
    it.state, it.target, it.timer, it.at = "chasing", c.id, chaseTicks(sim, c), "space"
  elseif n == "retreat" then
    local id = it.target
    it.target, it.revealed = nil, nil
    it.state, it.at = "idle", "space"
    finishEntry(sim, it, ("left convoy %s, no fight"):format(tostring(id)))
  elseif n == "return" then
    it.target, it.revealed = nil, nil
    it.state, it.timer = "returning", sim:ticks(cfg.returnSeconds)
  elseif n == "repair" then
    local missing, cost = it.hullMax - it.hull, repairCost(it)
    sim.resources.credits -= cost
    it.state, it.timer = "repairing", sim:ticks(math.ceil(missing / 10) * cfg.repairSecondsPer10)
    sim:log("INFO", ("%s repairs %d hull for %d cr"):format(agentId, missing, cost))
  elseif n == "sell" then
    local total, what = sellHold(sim, it, agentId, args, rid)
    finishEntry(sim, it, ("sold %s, +%d cr"):format(what, total))
  elseif n == "store" then
    local ore = args.resource
    local want = (args.qty == nil or args.qty == "all") and it.hold[ore] or args.qty
    local st = sim:storingStation(sim.home)
    local amt = math.min(want, it.hold[ore], Logistics.room(sim, st))
    st.stock[ore] = st.stock[ore] + amt
    it.hold[ore] = it.hold[ore] - amt
    if it.hold[ore] <= 0 then it.hold[ore] = nil end
    sim:log("INFO", ("%s stored %d %s"):format(agentId, amt, ore))
    finishEntry(sim, it, ("%d %s stored"):format(amt, ore))
  elseif n == "attack" then
    local c = findConvoy(sim, it.target)
    local raid = sim.raid
    local fight = { convoy = c.id, timer = sim:ticks(cfg.attackSeconds), pack = {} }
    for _, id in ipairs(sim.interceptorOrder) do
      local o = sim.interceptors[id]
      if o.state == "alongside" and o.target == c.id then
        o.state = "fighting"
        fight.pack[#fight.pack + 1] = o.id
      end
    end
    c.state = "fought"
    raid.fights[c.id] = fight
    raid.attacks += 1
    raid.lastAttackTick = sim.tick
    raid.standing[c.corp] += Cfg.standing.perAttack
    addNotoriety(sim)
    sim:log("INFO", ("%s attacks convoy %s (%s) with %d interceptor(s)"):format(agentId, c.id, c.corp, #fight.pack))
    sim:emit("raid_attack", { convoy = c.id, corp = c.corp, pack = #fight.pack })
  end
  return true
end

-- Per tick ---------------------------------------------------------------------------------------------------------

local function dismiss(sim, it, why)
  local id = it.target
  it.target, it.revealed = nil, nil
  it.state, it.at = "idle", "space"
  finishEntry(sim, it, why, false)
  if it.owner then sim:deliver(it.owner, ("convoy %s: %s"):format(tostring(id), why)) end
end

local function resolveFight(sim, fight)
  local raid, cc = sim.raid, Cfg.combat
  local c = findConvoy(sim, fight.convoy)
  local pack = {}
  for _, id in ipairs(fight.pack) do pack[#pack + 1] = sim.interceptors[id] end
  local attack, free = 0, 0
  for _, it in ipairs(pack) do
    attack += it.attack
    free += it.cap - holdTotal(it)
  end
  local power = Cfg.convoy.escortPower[c.escort] or 0
  local chance = clamp(cc.winBase + (attack - power) / cc.scale, cc.minChance, cc.maxChance)
  local won = draw(sim, "combat") < chance
  local frac = cc.lootMin + draw(sim, "combat") * (cc.lootMax - cc.lootMin)
  local dmgRoll = draw(sim, "combat")
  local damage
  if won then damage = cc.winDamageMin + math.floor(dmgRoll * (cc.winDamageMax - cc.winDamageMin + 1))
  else damage = cc.lossDamageMin + math.floor(dmgRoll * (cc.lossDamageMax - cc.lossDamageMin + 1)) end
  local each = math.ceil(damage / #pack)
  local loot = won and math.min(math.floor(c.qty * frac), free) or 0
  local share, extra = math.floor(loot / #pack), loot % #pack
  for i, it in ipairs(pack) do
    local got = math.min(share + (i <= extra and 1 or 0), it.cap - holdTotal(it))
    it.hull -= each
    it.target, it.revealed = nil, nil
    if it.hull <= 0 then
      it.hold, it.state, it.at, it.hull = {}, "disabled", sim.home, Cfg.interceptor.towedHull
      it.timer = sim:ticks(Cfg.interceptor.disabledSeconds)
      finishEntry(sim, it, ("%s, ship disabled: cargo lost, towed home (%d s)"):format(won and "won" or "lost", Cfg.interceptor.disabledSeconds), false)
      if it.owner then sim:deliver(it.owner, ("%s was disabled in the fight against %s"):format(it.id, fight.convoy)) end
      sim:log("WARN", ("%s disabled"):format(it.id))
    else
      it.state, it.at = "idle", "space"
      if got > 0 then it.hold[c.resource] = (it.hold[c.resource] or 0) + got end
      local text = won and ("won: +%d %s, hull -%d (%d/%d)"):format(got, c.resource, each, it.hull, it.hullMax)
        or ("lost: hull -%d (%d/%d)"):format(each, it.hull, it.hullMax)
      finishEntry(sim, it, text, true)
      if it.owner then sim:deliver(it.owner, ("attack on %s: %s"):format(fight.convoy, text)) end
    end
  end
  if won then
    raid.wins += 1
    local e = raid.mission
    if e.status == "active" and not e.failed and raid.notoriety < Cfg.notoriety.blacklistAt then
      e.wins += 1
      if e.wins >= Cfg.mission.wins then
        e.status = "complete"
        sim:log("INFO", ("mission %s complete: %s"):format(Cfg.mission.id, Cfg.mission.name))
        sim:emit("mission_complete", { id = Cfg.mission.id })
      end
    end
  end
  sim:log("INFO", ("attack on %s (%s, escort %d): %s, chance %d%%, %d damage, %d loot"):format(fight.convoy, c.corp, c.escort,
    won and "won" or "lost", math.floor(chance * 100 + 0.5), damage, loot))
  sim:emit("raid_result", { convoy = fight.convoy, won = won, chance = chance, loot = loot, damage = damage, pack = #pack, resource = c.resource })
  removeConvoy(sim, c)
  raid.fights[fight.convoy] = nil
end

function Raiding.step(sim)
  if not open(sim) then return end
  local raid = sim.raid
  local i = 1
  while i <= #raid.convoys do
    local c = raid.convoys[i]
    if c.state == "travel" then
      c.elapsed += 1
      if c.elapsed >= c.total then
        table.remove(raid.convoys, i)
        Market.rivalArrives(sim.market, c.dest, c.resource, c.qty)
        i -= 1
      end
    end
    i += 1
  end
  local ids = {}
  for cid in pairs(raid.fights) do ids[#ids + 1] = cid end
  table.sort(ids)
  for _, cid in ipairs(ids) do
    local f = raid.fights[cid]
    f.timer -= 1
    if f.timer <= 0 then resolveFight(sim, f) end
  end
  for _, id in ipairs(sim.interceptorOrder) do
    local it = sim.interceptors[id]
    local st = it.state
    if st == "scanning" then
      it.timer -= 1
      if it.timer <= 0 then
        local rows = {}
        for _, c in ipairs(raid.convoys) do
          if c.dest == it.scanRoute and c.state == "travel" then
            rows[#rows + 1] = { id = c.id, owner = c.corp, resource = c.resource, cargo = qtyBand(c.qty), escort = Cfg.convoy.escortBands[c.escort] }
          end
        end
        it.scans[it.scanRoute] = { tick = sim.tick, convoys = rows }
        it.state = "idle"
        finishEntry(sim, it, ("%d convoy%s on %s"):format(#rows, #rows == 1 and "" or "s", it.scanRoute))
      end
    elseif st == "chasing" then
      local c = findConvoy(sim, it.target)
      if not c or c.state ~= "travel" then
        dismiss(sim, it, "convoy_gone")
      else
        it.timer -= 1
        if it.timer <= 0 then
          it.state = "alongside"
          it.revealed = { id = c.id, owner = c.corp, resource = c.resource, qty = c.qty, escort = c.escort,
            escort_power = Cfg.convoy.escortPower[c.escort] or 0 }
          finishEntry(sim, it, ("alongside %s: %d %s, escort %d (%s)"):format(c.id, c.qty, c.resource, c.escort, c.corp))
        end
      end
    elseif st == "alongside" then
      local c = findConvoy(sim, it.target)
      if not c or c.state ~= "travel" then dismiss(sim, it, "convoy_gone") end
    elseif st == "returning" then
      it.timer -= 1
      if it.timer <= 0 then
        it.state, it.at = "idle", sim.home
        finishEntry(sim, it, "docked")
      end
    elseif st == "repairing" then
      it.timer -= 1
      if it.timer <= 0 then
        it.hull, it.state = it.hullMax, "idle"
        finishEntry(sim, it, ("hull %d/%d"):format(it.hull, it.hullMax))
      end
    elseif st == "disabled" then
      it.timer -= 1
      if it.timer <= 0 then it.state = "idle" end
    end
  end
  decayNotoriety(sim)
  Raiding.claim(sim)
end

-- Alerts -----------------------------------------------------------------------------------------------------------

function Raiding.detect(sim, _, raise)
  local raid = sim.raid
  if raid.notoriety >= Cfg.notoriety.blacklistAt and not raid.highRaised then
    raid.highRaised = true
    raise(sim, "notoriety_high", nil, ("Notoriety %d: HMC and Orbis pay %d%% less, freighters on orange routes are at risk"):format(
      raid.notoriety, Cfg.notoriety.blacklistPenalty * 100))
  end
end

-- Agent hooks (skill runner, decisions) ----------------------------------------------------------------------------

function Raiding.busy(sim, agent)
  local it = Raiding.interceptorFor(sim, agent.id)
  return it ~= nil and it.state ~= "idle" and it.state ~= "alongside"
end

-- A skill step with nothing to do is skipped instead of aborting the skill. -> reason | nil
function Raiding.skip(sim, agent, call)
  local it = Raiding.interceptorFor(sim, agent.id)
  if not it then return nil end
  if call.name == "return" and docked(sim, it) then return "already docked" end
  if call.name == "repair" and docked(sim, it) and it.hull >= it.hullMax then return "hull is full" end
  if call.name == "sell" and docked(sim, it) and holdTotal(it) <= 0 then return "hold is empty" end
  if call.name == "intercept" and type(call.args.convoy) == "table" and it.state == "idle" and not matchConvoy(sim, it, call.args.convoy) then
    return "no convoy matches"
  end
  if (call.name == "attack" or call.name == "retreat") and it.state ~= "alongside" and it.state ~= "fighting" then return "no convoy alongside" end
  return nil
end

function Raiding.needsDecision(sim, agent)
  local it = Raiding.interceptorFor(sim, agent.id)
  if not it then return false end
  return (it.state == "idle" or it.state == "alongside") and sim.tick >= (agent.waitUntil or 0)
end

-- Detached snapshot for the decider and the context builder.
function Raiding.context(sim, agent)
  local it = Raiding.interceptorFor(sim, agent.id)
  local raid = sim.raid
  local hold, standing = {}, {}
  for ore, q in pairs(it.hold) do hold[ore] = q end
  for corp, s in pairs(raid.standing) do standing[corp] = s end
  local last = raid.lastAttackTick and math.floor((sim.tick - raid.lastAttackTick) * sim.b.tickSeconds) or nil
  local alongside
  if it.revealed then
    alongside = {}
    for k, v in pairs(it.revealed) do alongside[k] = v end
  end
  return {
    tick = sim.tick,
    resources = { credits = sim.resources.credits, compute = sim.resources.compute },
    home = sim.home,
    interceptor = { id = it.id, state = it.state, at = it.at, hull = it.hull, hull_max = it.hullMax, attack = it.attack, cap = it.cap,
      hold = hold, hold_total = holdTotal(it), target = it.target },
    notoriety = raid.notoriety, blacklisted = raid.notoriety >= Cfg.notoriety.blacklistAt,
    standing = standing, last_attack_s = last,
    scan = scanRows(sim, it), routes = Cfg.orangeRoutes,
    alongside = alongside,
  }
end

-- Stub Privateer (spec §15b.6) ---------------------------------------------------------------------------------------

local function firstNumber(texts, patterns)
  for _, t in ipairs(texts) do
    for _, p in ipairs(patterns) do
      local v = t:match(p)
      if v then return tonumber(v) end
    end
  end
  return nil
end

-- What the directive and the order say (nil = not said). "Maximize profit" says nothing: the stub attacks everything.
local function policyOf(agent)
  local texts = { (agent.order or ""):lower(), (agent.directive or ""):lower() }
  local p = {}
  p.maxEscort = firstNumber(texts, { "only escort[%s%-]*(%d)", "escort[%s%-]*level[%s%-]*(%d)", "escort[%s%-]*(%d)%s+only", "escort[%s]*<=[%s]*(%d)" })
  if p.maxEscort == nil then
    for _, t in ipairs(texts) do
      if t:find("no escort", 1, true) or t:find("unescorted", 1, true) or t:find("without escort", 1, true) or t:find("no%-escort") then
        p.maxEscort = 0
        break
      end
    end
  end
  p.retreatHull = firstNumber(texts, { "retreat if hull below (%d+)", "retreat below (%d+) hull", "hull below (%d+)", "hull under (%d+)" })
  local gapMin = firstNumber(texts, { "wait (%d+) minutes? between attacks", "(%d+) minutes? between attacks", "one attack every (%d+) minutes?" })
  p.gapSeconds = gapMin and gapMin * 60 or nil
  p.notorietyBelow = firstNumber(texts, { "notoriety below (%d+)", "notoriety under (%d+)", "notoriety less than (%d+)", "notoriety under (%d+)" })
  local only, never, anyOnly = {}, {}, false
  for _, ore in ipairs(World.oreOrder) do
    for _, t in ipairs(texts) do
      if t:find("%f[%a]" .. ore) then
        local neg = t:find("never[%a%s]*%f[%a]" .. ore) or t:find("avoid[%a%s]*%f[%a]" .. ore) or t:find("not[%a%s]*%f[%a]" .. ore)
          or t:find("except[%a%s]*%f[%a]" .. ore) or t:find("no%s+" .. ore)
        if neg then never[ore] = true else only[ore], anyOnly = true, true end
      end
    end
  end
  p.only = anyOnly and only or nil
  p.never = next(never) and never or nil
  return p
end

local OPTIMAL = { maxEscort = 0, retreatHull = 40, notorietyBelow = 3, only = { iridium = true, crystal = true } }

local function decide(sim, ctx, p)
  local c = Cfg.stub
  local it = ctx.interceptor
  local function wait(s) return { name = "wait", args = { seconds = math.max(sim.b.waitMinSeconds, math.min(sim.b.waitMaxSeconds, math.floor(s))) } } end
  local function wanted(resource, escort)
    if p.maxEscort ~= nil and escort > p.maxEscort then return false end
    if p.only and not p.only[resource] then return false end
    if p.never and p.never[resource] then return false end
    return true
  end
  if it.state == "alongside" then
    local rev = ctx.alongside
    if p.retreatHull and it.hull < p.retreatHull then return { name = "retreat", args = {} } end
    if rev and not wanted(rev.resource, rev.escort) then return { name = "retreat", args = {} } end
    return { name = "attack", args = {} }
  end
  if it.at ~= ctx.home then return { name = "return", args = {} } end
  if it.hold_total > 0 then return { name = "sell", args = {} } end
  local repairBelow = c.repairBelow
  if p.retreatHull then repairBelow = math.max(repairBelow, p.retreatHull) end
  if it.hull < repairBelow then return { name = "repair", args = {} } end
  if p.notorietyBelow and ctx.notoriety + 1 >= p.notorietyBelow then return wait(c.waitSeconds) end
  if p.gapSeconds and ctx.last_attack_s and ctx.last_attack_s < p.gapSeconds then
    return wait(math.min(c.waitSeconds * 4, p.gapSeconds - ctx.last_attack_s))
  end
  local scanned = {}
  for _, row in ipairs(ctx.scan) do
    scanned[row.route] = true
    local level = row.escort == "none" and 0 or (row.escort == "light" and 1 or 2)
    if row.reach and wanted(row.resource, level) then return { name = "intercept", args = { convoy = row.id } } end
  end
  local rest = {}
  for _, r in ipairs(ctx.routes) do if not scanned[r] then rest[#rest + 1] = r end end
  if #rest == 0 then return wait(c.waitSeconds) end
  return { name = "scan_route", args = { route = rest[1 + math.floor(sim.randStub() * #rest)] } }
end

function Raiding.stubDirective(sim, agentId, ctx) return decide(sim, ctx, policyOf(sim.agents[agentId])) end
function Raiding.stubOptimal(sim, _, ctx) return decide(sim, ctx, OPTIMAL) end

return Raiding
