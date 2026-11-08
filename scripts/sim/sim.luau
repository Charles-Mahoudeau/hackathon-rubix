-- Server-side simulation core. Pure Luau, no engine deps, headless-runnable.
local Balance = require("@scripts/config/balance")
local World = require("@scripts/config/world")
local AiConfig = require("@scripts/config/ai")
local AiQueue = require("@scripts/sim/ai_queue")
local ToolsConfig = require("@scripts/config/tools")
local Compute = require("@scripts/sim/compute")
local Prompt = require("@scripts/sim/prompt")
local ContextSettings = require("@scripts/sim/context_settings")
local Feed = require("@scripts/sim/feed")
local Json = require("@scripts/sim/json")

local Sim = {}
Sim.__index = Sim

function Sim.deepCopy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = Sim.deepCopy(x) end
  return out
end

function Sim.new(opts)
  opts = opts or {}
  local b = opts.balance or Balance
  local seed = opts.seed or b.seed
  local self = setmetatable({ b = b, tick = 0, logs = {}, seed = seed, rng = { main = seed, stub = seed * 7 + 1 }, tier = 1,
    debug = { creditBoosts = 0 } }, Sim)
  -- Linear congruential stream; its whole state is rng.main, so a save can resume it exactly.
  self.rand = function()
    local s = (self.rng.main * 1103515245 + 12345) % 2147483648
    self.rng.main = s
    return s / 2147483648
  end
  -- Own stream for the stub's random picks (spec §10.5), so changing a directive never shifts the world's randomness.
  self.randStub = function()
    local s = (self.rng.stub * 1103515245 + 12345) % 2147483648
    self.rng.stub = s
    return s / 2147483648
  end
  Feed.init(self)
  self.resources = { credits = b.startCredits, compute = b.startCompute, reputation = b.startReputation }
  self.warehouse = {}
  for _, ore in ipairs(b.ores) do self.resources[ore] = 0; self.warehouse[ore] = 0 end
  self.lifetimeRevenue = 0
  self.deepNav = false
  self.planets, self.veins = {}, {}
  for _, id in ipairs(World.planetOrder) do
    local p = World.planets[id]
    self.planets[id] = { id = id, name = p.name, depotRate = p.depotRate, engineMark = p.engineMark,
      needsDeepNav = p.needsDeepNav, veins = {} }
  end
  for _, v in ipairs(World.veins) do
    local vein = { id = v.id, planet = v.planet, ore = v.ore, richness = v.richness, jumps = v.jumps,
      max = v.reserve, reserve = v.reserve, hidden = v.hidden or false, scanned = false }
    self.veins[v.id] = vein
    local list = self.planets[v.planet].veins
    list[#list + 1] = vein
  end
  self.home = World.homePlanet
  self.agents, self.agentOrder, self.ships, self.shipOrder, self.freighters = {}, {}, {}, {}, {}
  self.events, self.offer, self.lastAdvanceTick, self.reqs = {}, nil, nil, {}
  local kinds = {}
  for kind in pairs(b.agents) do kinds[#kinds + 1] = kind end
  table.sort(kinds)
  for _, kind in ipairs(kinds) do self:addAgent(kind, kind) end
  self:addShip("s1", "miner")
  self.skills = {}
  -- One AI budget authority: the queue (concurrency cap + hourly tokens). Its clock is game time here; the real
  -- provider injects real seconds (GR5-15). The Compute ledger bills in Compute and delegates the budget to it.
  local aiCfg = AiConfig
  if opts.aiConfig then -- overrides (tests) laid over the defaults
    aiCfg = {}
    for k, v in pairs(AiConfig) do aiCfg[k] = v end
    for k, v in pairs(opts.aiConfig) do aiCfg[k] = v end
  end
  self.aiQueue = AiQueue.new(aiCfg, opts.aiClock or function() return self.tick * b.tickSeconds end)
  self.aiConfig = aiCfg
  self.compute = Compute.new(self.resources, aiCfg, function() return self.tick * b.tickSeconds end, self.aiQueue)
  return self
end

-- A new agent of `kind` (a key of balance.agents) under `id`. `opts.tier` / `opts.station` override the defaults.
function Sim:addAgent(id, kind, opts)
  opts = opts or {}
  local def = self.b.agents[kind]
  local agent = { id = id, type = kind, tier = opts.tier or def.startTier, tools = {}, pending = nil, mode = "default",
    state = "idle", station = opts.station or self.home, decisions = {}, throttled = false,
    directive = "", order = "", history = {}, inbox = {}, contextSettings = ContextSettings.defaults() }
  for _, t in ipairs(def.tools) do agent.tools[t] = true end
  self.agents[id] = agent
  self.agentOrder[#self.agentOrder + 1] = id
  return agent
end

-- A docked mining ship at the home planet, owned by `owner` (an agent id).
function Sim:addShip(id, owner)
  local b = self.b
  local ship = { id = id, owner = owner, state = "idle", at = World.homePlanet, cargo = 0, cargoF = 0,
    ore = nil, timer = 0, vein = nil, engineMark = b.ship.engineMark, engineMult = b.ship.engineMult, crowdedBy = {} }
  self.ships[id] = ship
  self.shipOrder[#self.shipOrder + 1] = id
  return ship
end

-- A freighter belonging to `station`, idle there (spec §5.2).
function Sim:addFreighter(station)
  local f = { id = "F" .. (#self.freighters + 1), station = station, state = "idle", timer = 0 }
  self.freighters[#self.freighters + 1] = f
  return f
end

function Sim:emit(name, data)
  local e = self.events
  e[#e + 1] = { tick = self.tick, name = name, data = data }
  if #e > 500 then table.remove(e, 1) end
end

function Sim:drainEvents()
  local out = self.events
  self.events = {}
  return out
end

-- Convert game seconds to whole ticks (balance is expressed in seconds).
function Sim:ticks(seconds) return math.max(1, math.ceil(seconds / self.b.tickSeconds - 1e-9)) end

function Sim:log(level, msg)
  local l = self.logs
  l[#l + 1] = { tick = self.tick, level = level, msg = msg }
  if #l > self.b.logMax then table.remove(l, 1) end
end

local function tierHasTool(self, agent, tool)
  for t, list in pairs(self.b.tiers) do
    if t <= agent.tier then for _, n in ipairs(list) do if n == tool then return true end end end
  end
  return false
end

local function inRange(self, ship, planetId)
  local p = self.planets[planetId]
  return p ~= nil and p.engineMark <= ship.engineMark and (not p.needsDeepNav or self.deepNav)
end

function Sim:inRange(ship, planetId) return inRange(self, ship, planetId) end

function Sim:marketUnlocked(id) return self.tier >= World.markets[id].unlockTier end

-- Equipped tools of an agent in the schema order of config/tools.luau (what its prompt lists).
function Sim:equippedTools(agentId)
  local agent = self.agents[agentId]
  local out = {}
  for _, name in ipairs(ToolsConfig.order) do
    if agent.tools[name] and tierHasTool(self, agent, name) then out[#out + 1] = name end
  end
  return out
end

-- Player changes a context setting (§9.3); takes effect from the agent's next decision.
function Sim:setContextSetting(agentId, key, value)
  local agent = self.agents[agentId]
  if not agent then return false, "unknown agent" end
  local updated, err = ContextSettings.with(agent.contextSettings, key, value)
  if not updated then return false, err end
  agent.contextSettings = updated
  return true
end

function Sim:buyCompute(packs)
  local ok, err = self.compute:buy(packs)
  if ok then self:log("INFO", ("bought %d Compute for %d cr"):format(packs * self.compute.cfg.compute.packSize, Compute.packPrice(self.compute.cfg, packs))) end
  return ok, err
end

local function veinKnown(vein) return (not vein.hidden) or vein.scanned end

local function ownedShip(self, agentId)
  for _, id in ipairs(self.shipOrder) do
    if self.ships[id].owner == agentId then return self.ships[id] end
  end
  return self.ships.s1
end

-- Logistician sell/ship quantity: an integer >= 1, or "all" (everything in stock).
local function stockQty(self, args)
  local have = self.warehouse[args.resource or ""]
  if have == nil then return nil, "bad resource" end
  local q = args.qty
  if q == "all" then q = math.floor(have) end
  if type(q) ~= "number" or q ~= math.floor(q) or q < 1 then
    if q == 0 and args.qty == "all" then return nil, "not_enough_stock" end
    return nil, "bad qty"
  end
  return q
end

local function freeFreighter(self, station)
  for _, f in ipairs(self.freighters) do
    if f.station == station and f.state == "idle" then return f end
  end
  return nil
end

-- Validate a tool call against the CURRENT state. Returns ok, err. Never throws.
function Sim:validate(agentId, call)
  local agent = self.agents[agentId]
  if not agent then return false, "unknown agent" end
  if type(call) ~= "table" or type(call.name) ~= "string" then return false, "malformed call" end
  local args = call.args or {}
  if type(args) ~= "table" then return false, "args must be table" end
  if not agent.tools[call.name] then return false, "unknown or disallowed tool: " .. call.name end
  if not tierHasTool(self, agent, call.name) then return false, "tool not equipped: " .. call.name end
  local n = call.name
  local ship = self.ships[args.ship or ownedShip(self, agent.id).id]
  local shipTool = n == "mine" or n == "return" or n == "sell" or n == "scan"
  if agent.type == "miner" and (shipTool or n == "wait") and not ship then return false, "unknown ship" end
  if agent.type == "logistician" and n == "sell" then
    if args.buyer ~= nil and args.buyer ~= "hmc" then return false, "buyer_locked" end
    local q, qerr = stockQty(self, args)
    if not q then return false, qerr end
    if self.warehouse[args.resource] < q then return false, "not_enough_stock" end
    return true
  elseif agent.type == "logistician" and n == "ship" then
    local market = World.markets[args.destination or ""]
    if not market then return false, "bad destination" end
    if not market.demand[args.resource or ""] then return false, "not_bought_here" end
    local q, qerr = stockQty(self, args)
    if not q then return false, qerr end
    if q > self.b.freighter.cargo then return false, "bad qty" end
    if not freeFreighter(self, agent.station) then return false, "no_free_freighter" end
    if self.warehouse[args.resource] < q then return false, "not_enough_stock" end
    return true
  end
  if n == "mine" then
    local vein = self.veins[args.vein]
    if not vein or not veinKnown(vein) then return false, "unknown vein" end
    if not inRange(self, ship, vein.planet) then return false, "out_of_range" end
    if vein.reserve < 1 then return false, "vein_depleted" end
    if ship.state ~= "idle" then return false, "ship busy" end
    if ship.cargo > 0 and ship.ore ~= vein.ore then return false, "hold holds another ore" end
    if ship.cargo >= self.b.ship.cargoCap then return false, "hold_full" end
    local pct = args.stop_at_hold_pct
    if pct ~= nil and (type(pct) ~= "number" or pct < 10 or pct > 100) then return false, "bad stop_at_hold_pct" end
  elseif n == "return" then
    if ship.state == "idle" then return false, "already_docked" end
    if ship.state ~= "mining" then return false, "ship busy" end
    if args.to ~= nil and args.to ~= "home" and args.to ~= "local_depot" then return false, "bad dock" end
  elseif n == "scan" then
    if not self.planets[args.planet or ""] then return false, "bad planet" end
    if not inRange(self, ship, args.planet) then return false, "out_of_range" end
    if ship.state ~= "idle" then return false, "ship busy" end
  elseif n == "sell" then
    if args.buyer ~= nil and args.buyer ~= "hmc" then return false, "buyer_locked" end
    if args.planet ~= nil and (not self.planets[args.planet] or not inRange(self, ship, args.planet)) then
      return false, "bad depot"
    end
    if ship.state ~= "idle" then return false, "not_docked" end
    if ship.cargo <= 0 or not ship.ore then return false, "not_enough_stock" end
  elseif n == "wait" then
    local s = args.seconds
    if type(s) ~= "number" or s < self.b.waitMinSeconds or s > self.b.waitMaxSeconds then return false, "bad seconds" end
    if ship and ship.state ~= "idle" then return false, "ship busy" end
  elseif n == "store" then
    if not self.warehouse[args.resource or ""] or type(args.amount) ~= "number" or args.amount <= 0 then
      return false, "bad store args"
    end
  elseif n == "run_skill" then
    if not self.skills[args.name or ""] then return false, "unknown skill" end
  end
  return true
end

-- Ticks to go from dock/vein planet `from` to a vein of `jumps` on planet `to`.
local function travelTicks(self, ship, from, to, jumps)
  local seconds = (World.travel[from][to] + World.jumpSeconds * jumps) * ship.engineMult
  return self:ticks(seconds)
end

-- Apply a validated call. Invalid => logged ERROR, ignored.
local function remember(agent, call, ok, err)
  if not agent or type(call) ~= "table" or type(call.name) ~= "string" then return end
  local h = agent.history
  h[#h + 1] = { tool = call.name, args = type(call.args) == "table" and call.args or {}, ok = ok,
    result = ok and {} or { error = err } }
  if #h > 20 then table.remove(h, 1) end
end

-- opts.auto: the sim itself issues the call (a full hold sends the ship home); it gets no feed line of its own.
function Sim:apply(agentId, call, opts)
  local ok, err = self:validate(agentId, call)
  remember(self.agents[agentId], call, ok, err)
  if not ok then
    self:log("ERROR", agentId .. ": rejected " .. tostring(type(call) == "table" and call.name) .. " (" .. err .. ")")
    Feed.refused(self, agentId, call, err)
    return false, err
  end
  local args, n = call.args or {}, call.name
  local agent = self.agents[agentId]
  local ship = self.ships[args.ship or ownedShip(self, agentId).id]
  if agent.type == "logistician" and n == "sell" then
    local q = stockQty(self, args)
    local price = self.planets[agent.station].depotRate * World.ores[args.resource].basePrice
    local gain = math.floor(q * price)
    self.warehouse[args.resource] = self.warehouse[args.resource] - q
    self.resources.credits = self.resources.credits + gain
    self.lifetimeRevenue = self.lifetimeRevenue + gain
    self:log("INFO", ("%s sold %d %s for %d"):format(agentId, q, args.resource, gain))
    Feed.finish(self, Feed.begin(self, agentId, call, self:takeReasoning()), ("+%d cr"):format(gain))
    return true, { sold = q, total = gain }
  elseif agent.type == "logistician" and n == "ship" then
    -- stock is taken at call time, so a second Logistician on the same stock or freighter gets the error (spec §8.6)
    local q = stockQty(self, args)
    local f = freeFreighter(self, agent.station)
    self.warehouse[args.resource] = self.warehouse[args.resource] - q
    local oneWay = World.freighterRoutes[agent.station][args.destination]
    f.state, f.timer, f.load = "out", self:ticks(oneWay), { resource = args.resource, qty = q, destination = args.destination }
    f.owner = agentId
    self:log("INFO", ("%s shipped %d %s to %s on %s"):format(agentId, q, args.resource, args.destination, f.id))
    Feed.finish(self, Feed.begin(self, agentId, call, self:takeReasoning()), ("%s on its way (%d s)"):format(f.id, oneWay))
    return true, { freighter_id = f.id, eta_s = oneWay }
  end
  local shipCall = agent.type == "miner" and (n == "mine" or n == "return" or n == "sell" or n == "scan" or n == "wait")
  if shipCall and n == "return" then self:finishMine(ship) end
  local entry = not (opts and opts.auto) and Feed.begin(self, agentId, call, self:takeReasoning()) or nil
  if shipCall and entry then ship.feedEntry = entry end
  if n == "mine" then
    local vein = self.veins[args.vein]
    ship.stopPct, ship.mineStartTick, ship.mineStartCargo = args.stop_at_hold_pct or 100, self.tick, ship.cargo
    ship.state, ship.vein, ship.dest = "travel_out", vein, vein.planet
    ship.timer = travelTicks(self, ship, ship.at, vein.planet, vein.jumps)
  elseif n == "return" then
    local dest = args.to == "local_depot" and ship.at or self.home
    ship.state, ship.dest = "travel_back", dest
    ship.timer = travelTicks(self, ship, ship.at, dest, ship.vein and ship.vein.jumps or 0)
  elseif n == "sell" then
    local dest = args.planet or ship.at
    if ship.at ~= dest then
      ship.state, ship.dest, ship.timer = "travel_back", dest, travelTicks(self, ship, ship.at, dest, 0)
    else self:sell(ship, dest) end
  elseif n == "scan" then
    ship.state, ship.scanPlanet, ship.timer = "scanning", args.planet, self:ticks(self.b.ship.scanSeconds)
  elseif n == "wait" then
    if ship then ship.state, ship.timer = "waiting", self:ticks(args.seconds) end
  elseif n == "store" then
    local have = self.resources[args.resource]
    local amt = math.min(args.amount, have, self.b.warehouse.capacity - self.warehouse[args.resource])
    self.resources[args.resource] = have - amt
    self.warehouse[args.resource] = self.warehouse[args.resource] + amt
    Feed.finish(self, entry, ("%d %s stored"):format(amt, args.resource))
  elseif n == "report" then
    self:log("INFO", agentId .. " report: " .. tostring(args.message))
    Feed.finish(self, entry, "sent")
    Feed.info(self, agentId, tostring(args.message))
  elseif n == "run_skill" then
    self:log("INFO", "run_skill " .. args.name)
    Feed.finish(self, entry, "running skill")
    return self:apply(agentId, self.skills[args.name])
  end
  return true
end

-- Feed results for the ship's open call (a mine ends when the ship leaves the vein, a trip when it docks).
function Sim:finishMine(ship)
  local e = ship.feedEntry
  if e and e.tool == "mine" and e.status == "running" then
    local gained = math.max(0, ship.cargo - (ship.mineStartCargo or 0))
    Feed.finish(self, e, ("+%d %s (%d s)"):format(gained, ship.ore or ship.vein and ship.vein.ore or "ore",
      math.floor((self.tick - (ship.mineStartTick or self.tick)) * self.b.tickSeconds + 0.5)))
    ship.feedEntry = nil
  end
end

function Sim:finishDock(ship, text)
  local e = ship.feedEntry
  if e and e.status == "running" then Feed.finish(self, e, text) ship.feedEntry = nil end
end

-- The reasoning the provider gave for the decision being applied (feed line detail); read once.
function Sim:takeReasoning()
  local r = self.nextReasoning
  self.nextReasoning = nil
  return r
end

-- Sell the hold at the depot (HMC) of planet `planetId`. Empties the hold and its accumulator.
function Sim:sell(ship, planetId)
  if ship.cargo > 0 and ship.ore then
    local price = self.planets[planetId].depotRate * World.ores[ship.ore].basePrice
    local gain = math.floor(ship.cargo * price)
    self.resources.credits = self.resources.credits + gain
    self.lifetimeRevenue = self.lifetimeRevenue + gain
    self:log("INFO", ("sold %d %s for %d"):format(ship.cargo, ship.ore, gain))
    self:finishMine(ship)
    local text = ("sold %d %s, +%d cr"):format(ship.cargo, ship.ore, gain)
    if ship.feedEntry then self:finishDock(ship, text) else Feed.info(self, ship.owner, text) end
    ship.cargo, ship.cargoF, ship.ore = 0, 0, nil
  else self:finishDock(ship, "docked, hold empty") end
  ship.state = "idle"
end

-- Crowding (spec §5.1): n ships mining one vein each get 1 / (1 + perExtraShip x (n - 1)).
function Sim:crowdingFor(n) return 1 / (1 + self.b.crowding.perExtraShip * (n - 1)) end

-- Ships currently mining each vein, in stable ship order: vein id -> { ship, ... }.
function Sim:minersByVein()
  local byVein = {}
  for _, id in ipairs(self.shipOrder) do
    local ship = self.ships[id]
    if ship.state == "mining" and ship.vein then
      local list = byVein[ship.vein.id]
      if not list then list = {}; byVein[ship.vein.id] = list end
      list[#list + 1] = ship
    end
  end
  return byVein
end

local function setCrowdedBy(self, ship, others)
  local changed = #others ~= #ship.crowdedBy
  if not changed then for i, o in ipairs(others) do if ship.crowdedBy[i] ~= o then changed = true end end end
  ship.crowdedBy = others
  if changed and #others > 0 then
    self:log("WARN", ("%s: crowded by %s on %s (%.2fx)"):format(ship.owner, table.concat(others, ", "), ship.vein.id,
      self:crowdingFor(#others + 1)))
  end
end

function Sim:stepShip(ship, sharing)
  local b = self.b
  if ship.state == "travel_out" or ship.state == "travel_back" then
    ship.timer = ship.timer - 1
    if ship.timer <= 0 then
      ship.at = ship.dest
      if ship.state == "travel_out" then
        ship.state = "mining"
        ship.ore = ship.vein.ore
        if ship.vein.reserve < 1 then self:apply(ship.owner, { name = "return", args = { ship = ship.id } }, { auto = true }) end
      else
        ship.vein = nil
        ship.crowdedBy = {}
        if ship.cargo > 0 then self:sell(ship, ship.at)
        else self:finishDock(ship, ("docked at %s, hold empty"):format(ship.at)); ship.state = "idle" end
      end
    end
  elseif ship.state == "scanning" or ship.state == "waiting" then
    ship.timer = ship.timer - 1
    if ship.timer <= 0 then
      if ship.state == "scanning" then
        for _, v in ipairs(self.planets[ship.scanPlanet].veins) do v.scanned = true end
        self:log("INFO", "scan " .. ship.scanPlanet)
        self:finishDock(ship, ("%d veins revealed"):format(#self.planets[ship.scanPlanet].veins))
      else self:finishDock(ship, "done waiting") end
      ship.state = "idle"
    end
  elseif ship.state == "mining" then
    local v = ship.vein
    local others = {}
    for _, o in ipairs(sharing or {}) do if o ~= ship then others[#others + 1] = o.owner end end
    table.sort(others)
    setCrowdedBy(self, ship, others)
    local rate = b.ship.drillRate * v.richness * World.ores[v.ore].hardness * self:crowdingFor(#others + 1)
    local want = math.min(rate * b.tickSeconds, v.reserve, b.ship.cargoCap - ship.cargoF)
    ship.cargoF = ship.cargoF + want
    v.reserve = v.reserve - want
    ship.cargo = math.floor(ship.cargoF + 1e-9)
    local stopAt = math.ceil(b.ship.cargoCap * (ship.stopPct or 100) / 100 - 1e-9)
    if ship.cargo >= stopAt or v.reserve < 1 then
      if ship.cargo >= b.ship.cargoCap then ship.cargo, ship.cargoF = b.ship.cargoCap, b.ship.cargoCap end
      self:apply(ship.owner, { name = "return", args = { ship = ship.id } }, { auto = true })
    end
  end
end

function Sim:stepVeins()
  local regen = World.reserveRegenPerMinute * self.b.tickSeconds / 60
  for _, v in pairs(self.veins) do
    if v.reserve < v.max then v.reserve = math.min(v.max, v.reserve + v.max * regen) end
  end
end

-- AI hook: decide(sim, agentId, context) -> toolCall. Swap in ai module's decide.
function Sim:setDecider(fn) self.decide = fn end

-- Error accounting (spec §8.4): 2 invalid responses, 3 provider errors, or the same failing call twice in a row
-- stop the agent in `paused_error` until the player resumes it. A good decision from the agent's own decider resets it.
local function errs(agent)
  agent.errs = agent.errs or { invalid = 0, provider = 0, same = 0, lastKey = "" }
  return agent.errs
end

function Sim:pauseAgent(agentId, why)
  local agent = self.agents[agentId]
  if agent.state == "paused_error" then return end
  agent.state, agent.blockReason = "paused_error", why
  self:log("ERROR", ("%s: paused (%s)"):format(agentId, why))
  Feed.error(self, agentId, "paused: " .. why .. ". Fix the directive, then resume.")
  self:emit("agent_paused_error", { agent = agentId, reason = why })
end

-- kind: "invalid" (reply or call refused) | "provider" (network/provider failure). key identifies a refused call.
function Sim:noteFailure(agentId, kind, key)
  local e, rules = errs(self.agents[agentId]), self.aiConfig.errorRules
  e[kind] = e[kind] + 1
  if key then
    e.same = (key == e.lastKey) and e.same + 1 or 1
    e.lastKey = key
  end
  if e.provider >= rules.providerErrors then
    self:pauseAgent(agentId, ("%d provider errors in a row"):format(e.provider))
  elseif e.invalid >= rules.invalidResponses then
    self:pauseAgent(agentId, ("%d invalid responses in a row"):format(e.invalid))
  elseif key and e.same >= rules.sameFailingCall then
    self:pauseAgent(agentId, "the same call failed twice")
  end
end

function Sim:noteSuccess(agentId)
  self.agents[agentId].errs = nil
end

function Sim:resumeAgent(agentId)
  local agent = self.agents[agentId]
  if not agent or agent.state ~= "paused_error" then return false, "not_paused" end
  agent.state, agent.blockReason, agent.errs = "idle", nil, nil
  Feed.info(self, agentId, "resumed")
  self:emit("agent_resumed", { agent = agentId })
  return true
end

-- The player's permanent directive and one-off order (spec §9.4). Over the token limit the text is refused and nothing
-- changes; both are read by the prompt builder at the agent's next decision. An empty order clears it.
local function setText(self, agentId, field, text, maxTokens)
  local agent = self.agents[agentId]
  if not agent or type(text) ~= "string" then return false, "bad_args" end
  if Compute.estimateTokens(self.compute.cfg, text) > maxTokens then return false, "too_long" end
  agent[field] = text
  return true
end

function Sim:setDirective(agentId, text) return setText(self, agentId, "directive", text, self.compute.cfg.editor.directiveMaxTokens) end

function Sim:setOrder(agentId, text) return setText(self, agentId, "order", text, self.compute.cfg.editor.orderMaxTokens) end

-- Skill slots of an agent at its tier (spec D1: 1 slot from T1). Assigning skills is GR5-10.
function Sim:skillSlots(agentId)
  local slots = self.b.skillSlots
  local agent = self.agents[agentId]
  local n = 0
  for tier, count in pairs(slots) do if tier <= agent.tier and count > n then n = count end end
  return n
end

-- A decision made against `ctx` arrives later (async provider). Reject it if the world moved under it,
-- otherwise apply() re-validates every precondition against the live state.
-- opts.fallback: the stub stands in for a failed provider, so its success must not clear that provider's error streak.
function Sim:resolveDecision(agentId, call, ctx, opts)
  local ship = ownedShip(self, agentId)
  if self.agents[agentId].type == "miner" and ctx and ctx.ship and ctx.ship.state ~= ship.state then
    self:log("WARN", ("%s: stale decision dropped (ship was %s, now %s)"):format(agentId, ctx.ship.state, ship.state))
    return false, "stale"
  end
  local ok, err = self:apply(agentId, call)
  if ok then
    if not (opts and opts.fallback) then self:noteSuccess(agentId) end
  else
    self:noteFailure(agentId, "invalid", Json.encode(Json.map({ { "n", type(call) == "table" and call.name or "?" },
      { "a", type(call) == "table" and call.args or {} } })))
  end
  return ok, err
end

function Sim:stepFreighters()
  for _, f in ipairs(self.freighters) do
    if f.state ~= "idle" then
      f.timer = f.timer - 1
      if f.timer <= 0 then
        if f.state == "out" then
          local l = f.load
          local gain = math.floor(l.qty * World.ores[l.resource].basePrice * World.markets[l.destination].demand[l.resource])
          self.resources.credits = self.resources.credits + gain
          self.lifetimeRevenue = self.lifetimeRevenue + gain
          self:log("INFO", ("Delivery %s: %d %s sold on %s -> %d cr"):format(f.id, l.qty, l.resource, l.destination, gain))
          f.state, f.load = "back", nil
          f.timer = self:ticks(World.freighterRoutes[f.station][l.destination])
        else
          f.state = "idle"
        end
      end
    end
  end
end

-- Anti-softlock (spec §8.5): offer an emergency advance when the player cannot afford to keep any agent thinking.
function Sim:bailoutConditions()
  local c = self.b.bailout
  if self.resources.compute >= c.computeBelow or self.resources.credits >= c.creditsBelow then return false end
  for _, agent in pairs(self.agents) do if agent.mode == "skill" then return false end end
  for _, ship in pairs(self.ships) do if ship.cargo > 0 then return false end end
  return true
end

function Sim:bailoutReady()
  return self.lastAdvanceTick == nil or self.tick - self.lastAdvanceTick >= self:ticks(self.b.bailout.cooldownSeconds)
end

function Sim:updateBailout()
  local active = self:bailoutConditions() and self:bailoutReady()
  if active and not self.offer then
    self.offer = { kind = "emergency_advance", compute = self.b.bailout.grantCompute, tick = self.tick }
    self:log("INFO", "HMC offers an emergency advance")
    self:emit("emergency_advance_offered", { compute = self.b.bailout.grantCompute })
  elseif not active and self.offer then
    self.offer = nil
    self:emit("emergency_advance_withdrawn", {})
  end
end

-- Player pressed the notification button. Conditions are re-checked against the live state.
function Sim:acceptEmergencyAdvance()
  if not (self:bailoutConditions() and self:bailoutReady()) then return false, "not_available" end
  local grant = self.b.bailout.grantCompute
  self.resources.compute = self.resources.compute + grant
  self.lastAdvanceTick, self.offer = self.tick, nil
  self:log("INFO", ("emergency advance: +%d Compute"):format(grant))
  self:emit("emergency_advance_accepted", { compute = grant })
  return true
end

-- Thrashing guard (spec §8.3): at most thrashMaxDecisions decisions per thrashWindowSeconds of game time per agent.
function Sim:thrashAllowed(agent)
  local h, win = agent.decisions, self:ticks(self.b.ai.thrashWindowSeconds)
  while #h > 0 and self.tick - h[1] >= win do table.remove(h, 1) end
  return #h < self.b.ai.thrashMaxDecisions
end

local function setAgentState(self, agent, state, why)
  if agent.state == state then return end
  if agent.state == "paused_error" then return end -- only resumeAgent leaves it
  agent.state = state
  if state == "no_compute" then
    agent.blockReason = why
    self:log("WARN", ("%s: no_compute (%s)"):format(agent.id, why))
    Feed.error(self, agent.id, "no_compute: " .. why)
    self:emit("agent_no_compute", { agent = agent.id, reason = why })
  else
    agent.blockReason = nil
  end
end

local function finishRequest(self, reqId, tokens)
  for _, startedId in ipairs(self.aiQueue:complete(reqId, tokens)) do
    local r = self.reqs[startedId]
    if r then r.started = true end
  end
  self.reqs[reqId] = nil
end

-- Async AI provider (ai/provider.luau): the decision goes out as a request once the AiQueue lets it start, and comes back
-- through onAiResponse. nil = the sync decider only. A decision still in flight when the provider changes is refunded
-- and re-decided on the next tick.
function Sim:setProvider(provider)
  if provider == self.provider then return end
  for id, agent in pairs(self.agents) do
    local pend = agent.pending
    if pend then
      agent.pending = nil
      self.compute:settle(pend.charge, pend.input, 0)
      finishRequest(self, pend.reqId, 0)
      setAgentState(self, agent, "idle")
      self:log("WARN", id .. ": AI provider switched, pending decision dropped")
    end
  end
  self.provider = provider
end

-- A provider answer for the decision `resp.id`. Failures (error, timeout, invalid) are logged and the sync decider (the
-- stub) takes the decision instead, so the game never stalls on the network. Compute was charged on the estimate at
-- send and is corrected to the real token count when the provider reports one (a failed request stays charged).
function Sim:onAiResponse(resp)
  local agentId, agent
  for id, a in pairs(self.agents) do
    if a.pending and a.pending.provider and a.pending.pid == resp.id then agentId, agent = id, a break end
  end
  if not agent then return end
  local pend = agent.pending
  agent.pending = nil
  local realIn, realOut = resp.input_tokens or 0, resp.output_tokens or 0
  if resp.ok and realIn + realOut > 0 then
    local est = resp.estimated_tokens or 0
    local real = realIn + realOut
    local pct = est > 0 and math.floor((real - est) / est * 100 + 0.5) or 0
    self:log("INFO", ("ai %s: tokens est %d real %d (%+d%%) in %.1fs"):format(agentId, est, real, pct, resp.seconds or 0))
    self.compute:settle(pend.charge, realIn, realOut)
    finishRequest(self, pend.reqId, real)
  else
    self.compute:settle(pend.charge, pend.input, self.aiConfig.estimatedOutputTokens)
    finishRequest(self, pend.reqId, pend.input + self.aiConfig.estimatedOutputTokens)
  end
  setAgentState(self, agent, "idle")
  if resp.ok then
    if resp.tool_call.reasoning ~= "" then self:log("INFO", agentId .. " reasoning: " .. resp.tool_call.reasoning) end
    self.nextReasoning = resp.tool_call.reasoning ~= "" and resp.tool_call.reasoning or nil
    self:resolveDecision(agentId, { name = resp.tool_call.tool, args = resp.tool_call.args }, pend.ctx)
    self.nextReasoning = nil
    return
  end
  self:log("ERROR", ("ai %s: %s (%s)"):format(agentId, resp.kind or "error", tostring(resp.error)))
  Feed.error(self, agentId, ("%s: %s"):format(resp.kind == "invalid" and "invalid response" or "provider error", tostring(resp.error)))
  self:noteFailure(agentId, resp.kind == "invalid" and "invalid" or "provider")
  if agent.state == "paused_error" then return end
  if self.decide then
    local ok, call = pcall(self.decide, self, agentId, pend.ctx)
    if ok then
      self:log("WARN", agentId .. ": fell back to stub")
      self:resolveDecision(agentId, call, pend.ctx, { fallback = true })
    else self:log("ERROR", "decide failed: " .. tostring(call)) end
  end
end

-- Step 6 of the tick (spec §3): decide for every agent that is allowed to.
function Sim:stepAgent(id, agent)
  if agent.state == "paused_error" then return end
  local pend = agent.pending
  if pend and pend.provider then
    if pend.started and not pend.pid then
      pend.pid = self.provider:request({ agent_id = id, prompt = pend.prompt, max_output_tokens = self.aiConfig.maxOutputTokens })
    end
    return
  end
  if pend then
    if pend.started then pend.delay = pend.delay - 1 end
    if pend.started and pend.delay <= 0 then
      agent.pending = nil
      local outTokens = Prompt.outputTokens(pend.call)
      self.compute:settle(pend.charge, pend.input, outTokens)
      finishRequest(self, pend.reqId, pend.input + outTokens)
      setAgentState(self, agent, "idle")
      self:resolveDecision(id, pend.call, pend.ctx)
    end
    return
  end
  if not self.decide then return end
  if not self:needsDecision(id) then
    if agent.type == "miner" and agent.state ~= "no_compute" then setAgentState(self, agent, "acting") end
    return
  end
  local prompt = Prompt.build(self, id)
  local canSend, reason = self.compute:canSend(prompt.input)
  if not canSend then
    setAgentState(self, agent, "no_compute", reason == "budget" and self.aiConfig.budgetMessage or "not enough Compute")
    return
  end
  setAgentState(self, agent, "idle")
  if not self:thrashAllowed(agent) then
    if not agent.throttled then
      agent.throttled = true
      agent.throttleCount = (agent.throttleCount or 0) + 1
      if agent.throttleCount == 1 then self:log("WARN", ("%s: thrashing guard, waiting"):format(id)) end
    end
    return
  end
  agent.throttled = false
  local ctx = self:context(id)
  local call
  if not self.provider then
    local ok, res = pcall(self.decide, self, id, ctx)
    if not ok then self:log("ERROR", "decide failed: " .. tostring(res)); return end
    call = res
  end
  local reqId, status = self.aiQueue:submit({ agentId = id, monitor = agent.type == "monitor" })
  if not reqId then
    setAgentState(self, agent, "no_compute", self.aiConfig.budgetMessage)
    return
  end
  local charge = self.compute:charge(id, prompt.input)
  agent.decisions[#agent.decisions + 1] = self.tick
  if self.provider then
    agent.pending = { provider = true, ctx = ctx, reqId = reqId, charge = charge, input = prompt.input,
      started = status == "running", prompt = Prompt.forProvider(self, id, prompt) }
    self.reqs[reqId] = agent.pending
    setAgentState(self, agent, "thinking")
    return
  end
  self.lastDecision = { agent = id, tick = self.tick, ctx = ctx, call = call }
  local d = self.b.ai
  agent.pending = { call = call, ctx = ctx, reqId = reqId, charge = charge, input = prompt.input, started = status == "running",
    delay = self:ticks(d.delaySecondsMin + self.rand() * (d.delaySecondsMax - d.delaySecondsMin)) }
  self.reqs[reqId] = agent.pending
  setAgentState(self, agent, "thinking")
end

function Sim:step()
  self.tick = self.tick + 1
  if self.provider then
    for _, resp in ipairs(self.provider:drain()) do self:onAiResponse(resp) end
  end
  self:stepVeins()
  local byVein = self:minersByVein()
  for _, sid in ipairs(self.shipOrder) do
    local ship = self.ships[sid]
    self:stepShip(ship, ship.vein and byVein[ship.vein.id] or nil)
  end
  self:stepFreighters()
  for _, id in ipairs(self.agentOrder) do self:stepAgent(id, self.agents[id]) end
  self:updateBailout()
end

function Sim:needsDecision(agentId)
  local agent = self.agents[agentId]
  if agent.type == "miner" then return ownedShip(self, agentId).state == "idle" end
  return false
end

local function band(richness)
  local bands = World.richnessBands
  if richness >= bands.highFrom then return "high" end
  if richness >= bands.mediumFrom then return "medium" end
  return "low"
end

function Sim:richnessBand(richness) return band(richness) end

-- Detached snapshot: shares no table with live sim state, so holders cannot mutate it through it.
-- Hidden veins are omitted and unscanned veins expose only a richness band (spec §4.3).
function Sim:context(agentId)
  local ship = ownedShip(self, agentId)
  local planets = {}
  for id, p in pairs(self.planets) do
    local veins = {}
    for _, v in ipairs(p.veins) do
      if veinKnown(v) then
        local e = { id = v.id, ore = v.ore, jumps = v.jumps, band = band(v.richness), scanned = v.scanned }
        if v.scanned then e.richness, e.reserve, e.max = v.richness, math.floor(v.reserve), v.max end
        veins[#veins + 1] = e
      end
    end
    planets[id] = { id = id, name = p.name, depotRate = p.depotRate, reachable = inRange(self, ship, id), veins = veins }
  end
  return {
    tick = self.tick,
    resources = Sim.deepCopy(self.resources),
    ship = { id = ship.id, state = ship.state, at = ship.at, cargo = ship.cargo, ore = ship.ore,
      hold = self.b.ship.cargoCap, vein = ship.vein and ship.vein.id or nil, crowded_by = { table.unpack(ship.crowdedBy) } },
    planets = planets,
    home = self.home,
  }
end

function Sim:run(ticks) for _ = 1, ticks do self:step() end end

return Sim
