-- Server-side simulation core. Pure Luau, no engine deps, headless-runnable.
local Balance = require("@scripts/config/balance")
local Host = require("@scripts/sim/host")
local World = require("@scripts/config/world")
local AiConfig = require("@scripts/config/ai")
local AiQueue = require("@scripts/sim/ai_queue")
local Compute = require("@scripts/sim/compute")
local Prompt = require("@scripts/sim/prompt")
local ContextSettings = require("@scripts/sim/context_settings")
local Feed = require("@scripts/sim/feed")
local DecisionLog = require("@scripts/sim/decision_log")
local Versions = require("@scripts/sim/versions")
local Upgrades = require("@scripts/sim/upgrades")
local Missions = require("@scripts/sim/missions")
local Market = require("@scripts/sim/market")
local Rng = require("@scripts/sim/rng")
local Skills = require("@scripts/sim/skills")
local Logistics = require("@scripts/sim/logistics")
local Alerts = require("@scripts/sim/alerts")
local Monitor = require("@scripts/sim/monitor")
local Clock = require("@scripts/sim/clock")
local Raiding = require("@scripts/sim/raiding")
local Refining = require("@scripts/sim/refining")
local Salvage = require("@scripts/sim/salvage")
local Registry = require("@scripts/sim/branches/registry")
local Words = require("@scripts/config/copy")
local Branches = require("@scripts/sim/branches/index")
local MarketConfig = require("@scripts/config/market")

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
  local self = setmetatable({ b = b, tick = 0, logs = {}, seed = seed, rng = { main = seed, stub = seed * 7 + 1, market = Rng.seedFor(seed, MarketConfig.streams.market),
    events = Rng.seedFor(seed, MarketConfig.streams.events) }, tier = 1,
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
  Clock.init(self)
  Feed.init(self)
  DecisionLog.init(self)
  self.resources = { credits = b.startCredits, compute = b.startCompute }
  self.warehouse = {}
  for _, ore in ipairs(b.ores) do self.resources[ore] = 0; self.warehouse[ore] = 0 end
  self.lifetimeRevenue = 0
  self.upgrades = Upgrades.new()
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
  self.registry = Registry.new(opts.branches or Branches.all, b)
  self.branchesOpen = {}
  Raiding.init(self)
  Refining.init(self)
  Salvage.init(self)
  Logistics.init(self)
  Alerts.init(self)
  Monitor.init(self)
  for _, def in ipairs(self.registry.list) do
    if def.unlock and def.unlock.startsOpen then Registry.open(self, def.id, true) end
  end
  Feed.info(self, nil, Words.unlocks.tier[1])
  self.skills = {}
  self.market = Market.new(self.rng, b.tickSeconds, function(kind, text)
    self:emit("market_notice", { kind = kind, text = text })
    self:log("INFO", "market: " .. text)
  end)
  -- With the raiding branch open, the rival sales are real convoys (sim/raiding.luau); until then the scripted sale runs.
  self.market.convoyHook = function(m) return Raiding.spawnConvoy(self, m) end
  -- One AI budget authority: the queue (concurrency cap + hourly tokens). Its clock is game time here; the real
  -- provider injects real seconds (GR5-15). The Compute ledger bills in Compute and delegates the budget to it.
  local aiCfg = AiConfig
  if opts.aiConfig then -- overrides (tests) laid over the defaults
    aiCfg = {}
    for k, v in pairs(AiConfig) do aiCfg[k] = v end
    for k, v in pairs(opts.aiConfig) do aiCfg[k] = v end
  end
  -- The hourly token budget is a REAL hour (spec §10.4): the default clock is real seconds (game time / speed).
  self.aiQueue = AiQueue.new(aiCfg, opts.aiClock or function() return self.realTicks * b.tickSeconds end)
  self.aiConfig = aiCfg
  self.compute = Compute.new(self.resources, aiCfg, function() return self.tick * b.tickSeconds end, self.aiQueue)
  self.compute.discountOf = function(agentId) return Salvage.computeDiscount(self, agentId) end
  self.missions = Missions.new()
  Missions.update(self)
  return self
end

-- A new agent of `kind` (a key of balance.agents) under `id`. `opts.tier` / `opts.station` override the defaults.
function Sim:addAgent(id, kind, opts)
  opts = opts or {}
  local def = self.registry.agentTypes[kind]
  local agent = { id = id, type = kind, tier = opts.tier or def.startTier, tools = {}, pending = nil, mode = "ai", wakeAiOnSkillAbort = true,
    state = "idle", station = opts.station or self.home, decisions = {}, throttled = false,
    directive = "", order = "", history = {}, inbox = {}, contextSettings = ContextSettings.defaults() }
  for _, t in ipairs(def.tools) do agent.tools[t] = true end
  self.agents[id] = agent
  self.agentOrder[#self.agentOrder + 1] = id
  return agent
end

-- A docked mining ship at the home planet, owned by `owner` (an agent id).
function Sim:addShip(id, owner)
  local ship = { id = id, owner = owner, state = "idle", at = World.homePlanet, cargo = 0, cargoF = 0,
    ore = nil, timer = 0, vein = nil, crowdedBy = {} }
  Upgrades.applyToShip(self, ship)
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
  if #e > self.b.eventQueueMax then table.remove(e, 1) end
end

-- Real seconds, for the t_real_* stamps of the decision log. The sim never reads a clock itself: the host injects one
-- (the server passes the engine's real time); without it the stamps are game seconds.
function Sim:setRealClock(fn) self.realClock = fn end

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
  if tool == "scan" and not self.upgrades.scanner then return false end -- the Scanner is bought in the shop (T2)
  local tier = self.registry.toolTier[tool]
  return tier ~= nil and tier <= agent.tier
end

local function inRange(self, ship, planetId)
  local p = self.planets[planetId]
  return p ~= nil and p.engineMark <= ship.engineMark and (not p.needsDeepNav or self.deepNav)
end

function Sim:inRange(ship, planetId) return inRange(self, ship, planetId) end

-- Orbis opens with the trading post (spec §6.5); the other markets follow the tier.
function Sim:marketUnlocked(id)
  if id == "orbis" then return self.upgrades.tradingPost == true end
  return self.tier >= World.markets[id].unlockTier
end

function Sim:hasWarehouse() return self.upgrades.warehouse == true end

-- Units stored in the warehouse, all ores together (spec §6.5: storage 2,000).
function Sim:warehouseUsed()
  local n = 0
  for _, ore in ipairs(self.b.ores) do n += self.warehouse[ore] end
  return n
end

-- Where a docked ship is: the warehouse dock (home, once the warehouse stands) or a plain HMC depot.
function Sim:dockKind(ship)
  if ship.state == "idle" and ship.at == self.home and self:hasWarehouse() then return "warehouse" end
  return "depot"
end

-- Money in: credits, lifetime revenue, decision-log earnings, and the offline tally.
-- Re-derives the stats of every ship from the marks and bonuses owned (after a hold blueprint).
function Sim:refreshFleet() Upgrades.applyToFleet(self) end

function Sim:credit(agentId, recordId, gain)
  self.resources.credits = self.resources.credits + gain
  self.lifetimeRevenue = self.lifetimeRevenue + gain
  if agentId then DecisionLog.earned(self, agentId, recordId, gain) end
  Missions.onCredit(self, recordId, gain, agentId)
  local t = self.tally
  if t and agentId then t.credits[agentId] = (t.credits[agentId] or 0) + gain end
end

-- Equipped tools of an agent in the schema order of config/tools.luau, then the branch tools (what its prompt lists).
function Sim:equippedTools(agentId)
  local agent = self.agents[agentId]
  local out = {}
  for _, name in ipairs(self.registry.toolOrder) do
    if agent.tools[name] and tierHasTool(self, agent, name) then out[#out + 1] = name end
  end
  return out
end

function Sim:hasTool(agentId, tool)
  local agent = self.agents[agentId]
  return agent ~= nil and agent.tools[tool] == true and tierHasTool(self, agent, tool)
end

-- Tool slots of an agent (spec §8.1): slots taken by its equipped tools (wait and run_skill are free), and the maximum.
function Sim:toolSlots(agentId)
  local used = 0
  for _, name in ipairs(self:equippedTools(agentId)) do
    if not self.b.freeTools[name] then used += 1 end
  end
  return used, self.registry.agentTypes[self.agents[agentId].type].toolSlots or 0
end

-- Reputation level from lifetime revenue (spec §6.7).
function Sim:reputationLevel()
  local level = 0
  for i, need in ipairs(self.b.reputationLevels) do if self.lifetimeRevenue >= need then level = i end end
  return level
end

function Sim:buyUpgrade(id) return Upgrades.buy(self, id) end
function Sim:ownsItem(id) return Upgrades.owns(self, id) end

-- Branches (spec §15b.0): open one (pays its cost) or ask why it cannot open.
function Sim:openBranch(id) return Registry.open(self, id) end
function Sim:branchBlocker(id) return Registry.blocker(self, id) end

-- Agents the company can run at once, from its Reputation level (spec §6.5, D17).
function Sim:commandCapacity() return Upgrades.commandCapacity(self) end

function Sim:buyFreighter(station) return Logistics.buyFreighter(self, station) end
function Sim:buyHangar(station) return Logistics.buyHangar(self, station) end
function Sim:buildOutpost(planet) return Logistics.buildOutpost(self, planet) end
function Sim:hireLogistician(station) return Logistics.hire(self, station) end

-- The station an agent works at (Logisticians), nil for the others.
function Sim:stationOf(agentId)
  local agent = self.agents[agentId]
  return agent and agent.type == "logistician" and self.stations[agent.station] or nil
end

-- A docked Miner keeps its hold at a station that stores it: the home warehouse or an outpost.
function Sim:storingStation(planetId)
  local st = self.stations[planetId]
  if not st then return nil end
  if st.kind == "main" and not self:hasWarehouse() then return nil end
  return st
end

-- Tier 2 starts at the revenue threshold; every agent follows the tier (spec §6.6).
function Sim:updateTier()
  local need = self.b.tierRevenue[self.tier + 1]
  if need and self.lifetimeRevenue >= need then self:enterTier(self.tier + 1) end
end

-- Moves the company to tier `t` (never down); every agent follows (spec §6.6).
function Sim:enterTier(t)
  if t <= self.tier then return end
  self.tier = t
  for _, agent in pairs(self.agents) do agent.tier = t end
  self:log("INFO", ("tier %d reached"):format(t))
  Feed.info(self, nil, Words.unlocks.tier[t])
  self:emit("tier_up", { tier = t })
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

function Sim:ownedShip(agentId) return ownedShip(self, agentId) end

-- Logistician sell/ship quantity: an integer >= 1, or "all" (everything in stock).
local function stockQty(stock, args)
  local have = stock[args.resource or ""]
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
  if agent.type == "privateer" and n ~= "run_skill" then return Raiding.validate(self, agent, n, args) end
  if agent.type == "refiner" and n ~= "run_skill" then return Refining.validate(self, agent, n, args) end
  if agent.type == "scavenger" and n ~= "run_skill" then return Salvage.validate(self, agent, n, args) end
  local branchTool = self.registry:toolDef(n)
  if branchTool and branchTool.validate then return branchTool.validate(self, agent, args) end
  local isMiner = agent.type == "miner"
  local ship = isMiner and self.ships[args.ship or ownedShip(self, agent.id).id] or nil
  local shipTool = n == "mine" or n == "return" or n == "sell" or n == "scan"
  if isMiner and (shipTool or n == "wait") and not ship then return false, "unknown ship" end
  if n == "report" and args.to ~= nil and args.to ~= "player" then
    if args.to == agentId or type(args.to) ~= "string" or not self.agents[args.to] then return false, "unknown_recipient" end
  end
  if agent.type == "monitor" then return Monitor.validate(self, agent, n, args) end
  if agent.type == "logistician" and n == "sell" then
    local st = self.stations[agent.station]
    if args.buyer ~= nil and args.buyer ~= "hmc" and not (args.buyer == "orbis" and st.kind == "main" and self:marketUnlocked("orbis")) then
      return false, "buyer_locked"
    end
    -- refined goods are not bought by the HMC depot: Orbis only, from the main station
    if Refining.isGood(args.resource) and (args.buyer ~= "orbis" or not Market.has(self.market, "orbis", args.resource)) then
      return false, "not_bought_here"
    end
    local q, qerr = stockQty(st.stock, args)
    if not q then return false, qerr end
    if st.stock[args.resource] < q then return false, "not_enough_stock" end
    return true
  elseif agent.type == "logistician" and n == "ship" then
    local st = self.stations[agent.station]
    if not World.markets[args.destination or ""] then return false, "bad destination" end
    if not self:marketUnlocked(args.destination) then return false, "market_locked" end
    if not Market.has(self.market, args.destination, args.resource or "") then return false, "not_bought_here" end
    local q, qerr = stockQty(st.stock, args)
    if not q then return false, qerr end
    if q > self.b.freighter.cargo then return false, "bad qty" end
    if not freeFreighter(self, agent.station) then return false, "no_free_freighter" end
    if st.stock[args.resource] < q then return false, "not_enough_stock" end
    return true
  end
  if n == "mine" then
    local vein = self.veins[args.vein]
    if not vein or not veinKnown(vein) then return false, "unknown vein" end
    if not inRange(self, ship, vein.planet) then return false, "out_of_range" end
    if vein.reserve < 1 then return false, "vein_depleted" end
    if ship.state ~= "idle" and not (ship.state == "mining" and ship.vein.planet == vein.planet) then return false, "ship busy" end
    if ship.cargo > 0 and ship.ore ~= vein.ore then return false, "hold holds another ore" end
    if ship.cargo >= ship.cargoCap then return false, "hold_full" end
    local pct = args.stop_at_hold_pct
    if pct ~= nil and (type(pct) ~= "number" or pct < self.b.holdPct.min or pct > self.b.holdPct.max) then return false, "bad stop_at_hold_pct" end
    if args.to ~= nil and args.to ~= "home" and args.to ~= "local_depot" then return false, "bad dock" end
  elseif n == "return" then
    if ship.state == "idle" then return false, "already_docked" end
    if ship.state ~= "mining" then return false, "ship busy" end
    if args.to ~= nil and args.to ~= "home" and args.to ~= "local_depot" then return false, "bad dock" end
  elseif n == "scan" then
    if not self.planets[args.planet or ""] then return false, "bad planet" end
    if not inRange(self, ship, args.planet) then return false, "out_of_range" end
    if ship.state ~= "idle" then return false, "ship busy" end
    local fresh = false
    for _, v in ipairs(self.planets[args.planet].veins) do if not v.scanned then fresh = true end end
    if not fresh then return false, "already_scanned" end
  elseif n == "sell" then
    local buyer = args.buyer or "hmc"
    if buyer ~= "hmc" and buyer ~= "orbis" then return false, "buyer_locked" end
    if buyer == "orbis" and not self:marketUnlocked("orbis") then return false, "buyer_locked" end
    if args.planet ~= nil and (not self.planets[args.planet] or not inRange(self, ship, args.planet)) then
      return false, "out_of_range"
    end
    if ship.state ~= "idle" then return false, "not_docked" end
    if buyer == "orbis" and (ship.at ~= self.home or not self:hasWarehouse()) then return false, "not_docked" end
    if ship.cargo <= 0 or not ship.ore then return false, "not_enough_stock" end
    if args.resource ~= nil and args.resource ~= ship.ore then return false, "not_enough_stock" end
    if args.qty ~= nil and args.qty ~= "all" and (type(args.qty) ~= "number" or args.qty ~= math.floor(args.qty) or args.qty < 1) then
      return false, "bad qty"
    end
    if type(args.qty) == "number" and args.qty > ship.cargo then return false, "not_enough_stock" end
  elseif n == "wait" then
    local s = args.seconds
    if type(s) ~= "number" or s < self.b.waitMinSeconds or s > self.b.waitMaxSeconds then return false, "bad seconds" end
    if ship and ship.state ~= "idle" then return false, "ship busy" end
  elseif n == "store" then
    if self.warehouse[args.resource or ""] == nil then return false, "bad resource" end
    local q = args.qty
    if q ~= nil and q ~= "all" and (type(q) ~= "number" or q ~= math.floor(q) or q < 1) then return false, "bad qty" end
    if not self:hasWarehouse() then return false, "no_warehouse" end
    local st = self:storingStation(ship.at)
    if ship.state ~= "idle" or not st then return false, "not_docked" end
    if ship.cargo <= 0 or ship.ore ~= args.resource then return false, "not_enough_stock" end
    if type(q) == "number" and q > ship.cargo then return false, "not_enough_stock" end
    if Logistics.room(self, st) <= 0 then return false, "warehouse_full" end
  elseif n == "run_skill" then
    local ok, err = Skills.canStart(self, agentId, args.name, args.params)
    if not ok then
      if err == "unknown_skill" and self.skills[args.name or ""] then err = "wrong_agent_type" end
      return false, err
    end
  end
  return true
end

-- Ticks to go from dock/vein planet `from` to a vein of `jumps` on planet `to`.
local function travelTicks(self, ship, from, to, jumps)
  local seconds = (World.travel[from][to] + World.jumpSeconds * jumps) * ship.engineMult
  return self:ticks(seconds)
end

-- Apply a validated call. Invalid => logged ERROR, ignored.
-- A call enters the agent's history; an accepted one gets its §11 result table when the action ends (Sim:setResult).
local function remember(agent, call, ok, err, keep)
  if not agent or type(call) ~= "table" or type(call.name) ~= "string" then return nil end
  local h = agent.history
  agent.histSeq = (agent.histSeq or 0) + 1
  local args = {}
  if type(call.args) == "table" then for k, v in pairs(call.args) do if k ~= "ship" then args[k] = v end end end -- `ship` is the sim's own routing key
  h[#h + 1] = { id = agent.histSeq, tool = call.name, args = args, ok = ok, result = ok and {} or { error = err } }
  if #h > keep then table.remove(h, 1) end
  return agent.histSeq
end

function Sim:setResult(agentId, histId, result, ok)
  local agent = self.agents[agentId]
  if not agent or not histId then return end
  local h = agent.history
  for i = #h, 1, -1 do
    if h[i].id == histId then
      h[i].result = result
      if ok == false then h[i].ok = false end
      return
    end
  end
end

local function holdMap(ship)
  if ship.cargo > 0 and ship.ore then return { [ship.ore] = ship.cargo } end
  return {}
end

-- opts.auto: the sim itself issues the call (a full hold sends the ship home); it gets no feed line of its own.
-- opts.record: the decision-log record of the AI decision being applied; opts.skill: a skill step (its own record);
-- opts.fallback: the stub stands in for a failed provider.
function Sim:apply(agentId, call, opts)
  local who = self.agents[agentId]
  if who and who.type == "logistician" then who.waitUntil = self.tick + self:ticks(self.b.logistics.cooldownSeconds) end
  local ok, err = self:validate(agentId, call)
  local histId = remember(self.agents[agentId], call, ok, err, self.b.historyKeep)
  local rec = opts and opts.record
  if opts and opts.skill then rec = DecisionLog.skillStep(self, agentId, opts.skill) end
  if not ok then
    self:log("ERROR", agentId .. ": rejected " .. tostring(type(call) == "table" and call.name) .. " (" .. err .. ")")
    Feed.refused(self, agentId, call, err)
    DecisionLog.failed(self, rec, err, type(call) == "table" and call or nil)
    Missions.onError(self, agentId, err)
    return false, err
  end
  DecisionLog.accepted(self, rec, call, opts and opts.fallback)
  local rid = rec and rec.id
  local args, n = call.args or {}, call.name
  local agent = self.agents[agentId]
  if agent.type == "privateer" and n ~= "run_skill" then
    Raiding.apply(self, agentId, call, { record = rid, auto = opts and opts.auto })
    return true
  end
  if agent.type == "refiner" and n ~= "run_skill" then
    return Refining.apply(self, agentId, call, { record = rid, auto = opts and opts.auto })
  end
  if agent.type == "scavenger" and n ~= "run_skill" then
    return Salvage.apply(self, agentId, call, { record = rid, auto = opts and opts.auto })
  end
  local branchTool = self.registry:toolDef(n)
  if branchTool and branchTool.apply then
    local entry = Feed.begin(self, agentId, call, self:takeReasoning(), rid)
    local text, result = branchTool.apply(self, agentId, args, { record = rid, call = call })
    Feed.finish(self, entry, text or "done")
    return true, result
  end
  local ship = agent.type == "miner" and self.ships[args.ship or ownedShip(self, agentId).id] or nil
  if agent.type == "monitor" then return Monitor.apply(self, agentId, call, rid) end
  if agent.type == "logistician" and n == "sell" then
    local st = self.stations[agent.station]
    local q = stockQty(st.stock, args)
    local gain
    local orbisUnit
    if args.buyer == "orbis" then
      local total
      orbisUnit, total = Market.sell(self.market, "orbis", args.resource, q)
      gain = math.floor(total)
    else
      gain = math.floor(q * self.planets[agent.station].depotRate * World.ores[args.resource].basePrice)
    end
    gain = math.floor(gain * Raiding.priceFactor(self, args.buyer or "hmc"))
    st.stock[args.resource] = st.stock[args.resource] - q
    self:log("INFO", ("%s sold %d %s for %d"):format(agentId, q, args.resource, gain))
    local unit = q > 0 and math.floor(gain / q * 10 + 0.5) / 10 or 0
    Feed.finish(self, Feed.begin(self, agentId, call, self:takeReasoning(), rid), ("+%d cr"):format(gain), true,
      { sold = q, unit_price = unit, total = gain })
    self:credit(agentId, rid, gain)
    if orbisUnit then
      if Refining.isGood(args.resource) then Refining.onSale(self, args.resource, q, orbisUnit)
      else Missions.onOrbisSale(self, args.resource, q, orbisUnit) end
    end
    return true, { sold = q, total = gain }
  elseif agent.type == "logistician" and n == "ship" then
    -- stock is taken at call time, so a second Logistician on the same stock or freighter gets the error (spec §8.6)
    local st = self.stations[agent.station]
    local q = stockQty(st.stock, args)
    local f = freeFreighter(self, agent.station)
    st.stock[args.resource] = st.stock[args.resource] - q
    local oneWay = World.freighterRoutes[agent.station][args.destination]
    f.state, f.timer, f.load = "out", self:ticks(oneWay), { resource = args.resource, qty = q, destination = args.destination }
    f.owner, f.recordId = agentId, rid
    self:log("INFO", ("%s shipped %d %s to %s on %s"):format(agentId, q, args.resource, args.destination, f.id))
    Feed.finish(self, Feed.begin(self, agentId, call, self:takeReasoning(), rid), ("%s on its way (%d s)"):format(f.id, oneWay), true,
      { freighter_id = f.id, eta_s = oneWay })
    return true, { freighter_id = f.id, eta_s = oneWay }
  end
  if agent.type == "logistician" and n == "wait" then
    agent.waitUntil = self.tick + self:ticks(args.seconds)
    Feed.finish(self, Feed.begin(self, agentId, call, self:takeReasoning(), rid), "waiting", true, {})
    return true
  end
  local shipCall = agent.type == "miner" and (n == "mine" or n == "return" or n == "sell" or n == "scan" or n == "wait")
  if n == "run_skill" then
    local entry = not (opts and opts.auto) and Feed.begin(self, agentId, call, self:takeReasoning(), rid) or nil
    Skills.assign(self, agentId, args.name, args.params)
    agent.skillHistId = histId
    Feed.finish(self, entry, "running skill " .. args.name, true, {})
    return true
  end
  if shipCall and n == "return" then
    ship.stopBecause = opts and opts.because or "recalled"
    self:finishMine(ship)
  end
  local previousVein = n == "mine" and ship.state == "mining" and ship.vein or nil
  if previousVein then self:finishMine(ship) end
  local entry = not (opts and opts.auto) and Feed.begin(self, agentId, call, self:takeReasoning(), rid) or nil
  if shipCall and entry then ship.feedEntry, ship.recordId = entry, rid end
  -- an automatic call has no feed line: its history row is resolved straight from the ship's dock
  if shipCall and not entry then ship.autoHist = histId end
  if n == "mine" then
    local vein = self.veins[args.vein]
    -- Which vein the hold came from, for the missions: "mixed" once two veins feed one hold.
    if ship.cargo <= 0 then ship.cargoVein = vein.id elseif ship.cargoVein ~= vein.id then ship.cargoVein = "mixed" end
    ship.stopPct, ship.mineStartTick, ship.mineStartCargo = args.stop_at_hold_pct or 100, self.tick, ship.cargo
    -- the dock the full hold goes to: the sim issues that `return` itself, so the stub's choice rides on the mine call
    ship.returnTo = args.to
    ship.state, ship.vein, ship.dest = "travel_out", vein, vein.planet
    if previousVein then
      ship.timer = self:ticks(math.max(World.minVeinHopSeconds, World.jumpSeconds * math.abs(previousVein.jumps - vein.jumps)) * ship.engineMult)
    else
      ship.timer = travelTicks(self, ship, ship.at, vein.planet, vein.jumps)
    end
  elseif n == "return" then
    local dest = args.to == "local_depot" and ship.at or self.home
    ship.state, ship.dest = "travel_back", dest
    ship.timer = travelTicks(self, ship, ship.at, dest, ship.vein and ship.vein.jumps or 0)
  elseif n == "sell" then
    local dest = args.planet or ship.at
    if ship.at ~= dest then
      ship.state, ship.dest, ship.timer = "travel_back", dest, travelTicks(self, ship, ship.at, dest, 0)
      ship.sellOnArrival = true
    else self:sell(ship, dest, { buyer = args.buyer, qty = args.qty }) end
  elseif n == "scan" then
    ship.scanPlanet = args.planet
    if ship.at ~= args.planet then
      ship.state, ship.dest, ship.timer = "travel_scan", args.planet, travelTicks(self, ship, ship.at, args.planet, 0)
    else
      ship.state, ship.timer = "scanning", self:ticks(self.b.ship.scanSeconds)
    end
  elseif n == "wait" then
    if ship then ship.state, ship.timer = "waiting", self:ticks(args.seconds) end
  elseif n == "store" then
    local want = (args.qty == nil or args.qty == "all") and ship.cargo or args.qty
    local st = self:storingStation(ship.at)
    local amt = math.min(want, ship.cargo, Logistics.room(self, st))
    self:finishMine(ship)
    st.stock[args.resource] = st.stock[args.resource] + amt
    ship.cargo = ship.cargo - amt
    ship.cargoF = ship.cargo
    if ship.cargo <= 0 then ship.ore, ship.cargoVein = nil, nil end
    self:log("INFO", ("%s stored %d %s"):format(agentId, amt, args.resource))
    Feed.finish(self, entry, ("%d %s stored"):format(amt, args.resource), true,
      { stored = amt, partial = amt < want, warehouse_free = Logistics.room(self, st) })
    ship.feedEntry = nil
  elseif n == "report" then
    self:log("INFO", agentId .. " report: " .. tostring(args.message))
    local delivered = true
    if args.to ~= nil and args.to ~= "player" then
      delivered = self:deliver(args.to, ("from %s: %s"):format(agentId, tostring(args.message)))
    else
      Feed.info(self, agentId, tostring(args.message))
    end
    Feed.finish(self, entry, "sent", true, { delivered = delivered })
  end
  return true
end

-- A message into an agent's inbox, instantly (spec §8.6). The inbox keeps the last `inboxKeep`.
function Sim:deliver(agentId, text)
  local agent = self.agents[agentId]
  if not agent then return false end
  local inbox = agent.inbox
  inbox[#inbox + 1] = text
  while #inbox > self.b.inboxKeep do table.remove(inbox, 1) end
  self:emit("message_delivered", { agent = agentId, text = text })
  return true
end

-- Feed results for the ship's open call (a mine ends when the ship leaves the vein, a trip when it docks).
function Sim:finishMine(ship)
  local e = ship.feedEntry
  if e and e.tool == "mine" and e.status == "running" then
    local gained = math.max(0, ship.cargo - (ship.mineStartCargo or 0))
    local ore = ship.ore or ship.vein and ship.vein.ore or "ore"
    local seconds = math.floor((self.tick - (ship.mineStartTick or self.tick)) * self.b.tickSeconds + 0.5)
    local v = ship.vein
    local result = { mined = { [ore] = gained }, hold_pct = math.floor(ship.cargo * 100 / ship.cargoCap + 0.5),
      vein_reserve_pct = v and math.floor(v.reserve * 100 / v.max) or 0, duration_s = seconds,
      stopped_because = ship.stopBecause or "recalled", crowded_by = { table.unpack(ship.crowdedBy or {}) } }
    ship.stopBecause = nil
    Feed.finish(self, e, ("+%d %s (%d s)"):format(gained, ore, seconds), true, result)
    ship.feedEntry = nil
  end
end

-- A trip, scan or wait ended: the feed line (or, for an automatic call, the history row) gets its result.
function Sim:finishDock(ship, text, result)
  local e = ship.feedEntry
  if e and e.status == "running" then Feed.finish(self, e, text, true, result) ship.feedEntry = nil
  elseif ship.autoHist then self:setResult(ship.owner, ship.autoHist, result) end
  ship.autoHist = nil
end

-- The reasoning the provider gave for the decision being applied (feed line detail); read once.
function Sim:takeReasoning()
  local r = self.nextReasoning
  self.nextReasoning = nil
  return r
end

-- Sell the hold at the depot (HMC) of planet `planetId`. Empties the hold and its accumulator.
-- opts.buyer "orbis" (trading post, docked at the warehouse) sells at the Orbis price; opts.qty sells part of the hold.
function Sim:sell(ship, planetId, opts)
  opts = opts or {}
  ship.sellOnArrival = nil
  if ship.cargo > 0 and ship.ore then
    local qty = (type(opts.qty) == "number") and math.min(opts.qty, ship.cargo) or ship.cargo
    local gain, orbisUnit
    if opts.buyer == "orbis" then
      local total
      orbisUnit, total = Market.sell(self.market, "orbis", ship.ore, qty)
      gain = math.floor(total)
    else
      gain = math.floor(qty * self.planets[planetId].depotRate * World.ores[ship.ore].basePrice)
    end
    gain = math.floor(gain * Raiding.priceFactor(self, opts.buyer or "hmc"))
    self:log("INFO", ("sold %d %s for %d"):format(qty, ship.ore, gain))
    self:credit(ship.owner, ship.recordId, gain)
    if orbisUnit then Missions.onOrbisSale(self, ship.ore, qty, orbisUnit) end
    self:finishMine(ship)
    local text = ("sold %d %s, +%d cr"):format(qty, ship.ore, gain)
    local result = { sold = qty, unit_price = math.floor(gain / qty * 10 + 0.5) / 10, total = gain }
    if opts.dock then result.docked_at, result.hold = planetId, { [ship.ore] = ship.cargo } end
    if not ship.feedEntry then Feed.info(self, ship.owner, text) end
    self:finishDock(ship, text, result)
    Missions.onSale(self, ship)
    ship.cargo = ship.cargo - qty
    ship.cargoF = ship.cargo
    if ship.cargo <= 0 then ship.ore, ship.cargoVein = nil, nil end
  else self:finishDock(ship, "docked, hold empty", { docked_at = planetId, hold = {} }) end
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
  if ship.state == "travel_scan" then
    ship.timer = ship.timer - 1
    if ship.timer <= 0 then
      ship.at = ship.dest
      ship.state, ship.timer = "scanning", self:ticks(b.ship.scanSeconds)
    end
  elseif ship.state == "travel_out" or ship.state == "travel_back" then
    ship.timer = ship.timer - 1
    if ship.timer <= 0 then
      ship.at = ship.dest
      if ship.state == "travel_out" then
        ship.state = "mining"
        ship.ore = ship.vein.ore
        if ship.vein.reserve < 1 then
          self:apply(ship.owner, { name = "return", args = { ship = ship.id, to = ship.returnTo } }, { auto = true, because = "vein_depleted" })
        end
      else
        ship.vein = nil
        ship.crowdedBy = {}
        if ship.cargo > 0 and self:storingStation(ship.at) and not ship.sellOnArrival then
          -- a storing dock (warehouse, outpost) keeps the hold: the agent stores or sells it itself
          self:finishMine(ship)
          self:finishDock(ship, ("docked at %s, %d %s in the hold"):format(ship.at, ship.cargo, ship.ore),
            { docked_at = ship.at, hold = holdMap(ship) })
          ship.state = "idle"
        elseif ship.cargo > 0 then self:sell(ship, ship.at, { dock = not ship.sellOnArrival })
        else
          self:finishDock(ship, ("docked at %s, hold empty"):format(ship.at), { docked_at = ship.at, hold = {} })
          ship.state = "idle"
        end
      end
    end
  elseif ship.state == "scanning" or ship.state == "waiting" then
    ship.timer = ship.timer - 1
    if ship.timer <= 0 then
      if ship.state == "scanning" then
        for _, v in ipairs(self.planets[ship.scanPlanet].veins) do v.scanned = true end
        self.scanCalls = (self.scanCalls or 0) + 1
        self:log("INFO", "scan " .. ship.scanPlanet)
        local veins = {}
        for _, v in ipairs(self.planets[ship.scanPlanet].veins) do
          veins[v.id] = ("%s/%.1f/%d%%"):format(v.ore, v.richness, math.floor(v.reserve * 100 / v.max))
        end
        self:finishDock(ship, ("%d veins revealed"):format(#self.planets[ship.scanPlanet].veins), { veins = veins })
      else self:finishDock(ship, "done waiting", {}) end
      ship.state = "idle"
    end
  elseif ship.state == "mining" then
    local v = ship.vein
    local others = {}
    for _, o in ipairs(sharing or {}) do if o ~= ship then others[#others + 1] = o.owner end end
    table.sort(others)
    setCrowdedBy(self, ship, others)
    local rate = ship.drillRate * v.richness * World.ores[v.ore].hardness * self:crowdingFor(#others + 1)
    local want = math.min(rate * b.tickSeconds, v.reserve, ship.cargoCap - ship.cargoF)
    ship.cargoF = ship.cargoF + want
    v.reserve = v.reserve - want
    local tally = self.tally
    if tally then tally.units[ship.owner] = (tally.units[ship.owner] or 0) + want end
    ship.cargo = math.floor(ship.cargoF + 1e-9)
    local stopAt = math.ceil(ship.cargoCap * (ship.stopPct or 100) / 100 - 1e-9)
    if ship.cargo >= stopAt or v.reserve < 1 then
      local because = ship.cargo >= ship.cargoCap and "hold_full" or v.reserve < 1 and "vein_depleted" or "hold_target"
      if ship.cargo >= ship.cargoCap then ship.cargo, ship.cargoF = ship.cargoCap, ship.cargoCap end
      self:apply(ship.owner, { name = "return", args = { ship = ship.id, to = ship.returnTo } }, { auto = true, because = because })
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
  Feed.error(self, agentId, why)
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
    self:pauseAgent(agentId, Words.pause.provider)
  elseif e.invalid >= rules.invalidResponses then
    self:pauseAgent(agentId, Words.pause.invalid)
  elseif key and e.same >= rules.sameFailingCall then
    self:pauseAgent(agentId, Words.pause.same)
  end
end

function Sim:noteSuccess(agentId)
  self.agents[agentId].errs = nil
end

function Sim:resumeAgent(agentId)
  local agent = self.agents[agentId]
  if not agent or agent.state ~= "paused_error" then return false, "not_paused" end
  agent.state, agent.blockReason, agent.errs, agent.pausedBy = "idle", nil, nil, nil
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

function Sim:setOrder(agentId, text)
  local ok, err = setText(self, agentId, "order", text, self.compute.cfg.editor.orderMaxTokens)
  if ok then self.agents[agentId].orderSource = nil end
  return ok, err
end

function Sim:hireMonitor(scope) return Monitor.hire(self, scope) end
function Sim:setMonitorSettings(changes, agentId) return Monitor.setSettings(self, changes, agentId) end
function Sim:setMonitorLock(agentId, locked) return Monitor.setLock(self, agentId, locked) end

-- Skills the company Archive can hold (spec D1: 1 from T1, +1 per Archive upgrade, +2 with the warehouse). The Archive is
-- shared, so the agent only decides which type it may run.
function Sim:archiveCapacity()
  local n = 0
  for tier, count in pairs(self.b.skillSlots) do if tier <= self.tier and count > n then n = count end end
  return n + self.upgrades.archive + (self.upgrades.archiveBonus or 0) + (self:hasWarehouse() and self.b.warehouse.extraSkillSlots or 0)
end

function Sim:skillSlots(agentId) return self:archiveCapacity() end

-- A decision made against `ctx` arrives later (async provider). Reject it if the world moved under it,
-- otherwise apply() re-validates every precondition against the live state.
-- opts.fallback: the stub stands in for a failed provider, so its success must not clear that provider's error streak.
-- opts.record: the decision-log record of this decision.
function Sim:resolveDecision(agentId, call, ctx, opts)
  local ship = ownedShip(self, agentId)
  if self.agents[agentId].type == "miner" and ctx and ctx.ship and ctx.ship.state ~= ship.state then
    self:log("WARN", ("%s: stale decision dropped (ship was %s, now %s)"):format(agentId, ctx.ship.state, ship.state))
    DecisionLog.failed(self, opts and opts.record, "stale", type(call) == "table" and call or nil)
    return false, "stale"
  end
  -- the stub explains itself (spec §10.5); a provider's reasoning was set by the caller
  local own = type(call) == "table" and call.reasoning
  if own and own ~= "" and not self.nextReasoning then
    self.nextReasoning = own
    local rec = opts and opts.record
    if rec and not rec.reasoning then rec.reasoning = own end
  end
  local ok, err = self:apply(agentId, call, { record = opts and opts.record, fallback = opts and opts.fallback })
  self.nextReasoning = nil
  if ok then
    if not (opts and opts.fallback) then self:noteSuccess(agentId) end
  else
    self:noteFailure(agentId, "invalid", Host.json.encode(Host.json.map({ { "n", type(call) == "table" and call.name or "?" },
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
          Raiding.retaliation(self, f)
          local unit, total = Market.sell(self.market, l.destination, l.resource, l.qty)
          local gain = math.floor(total * Raiding.priceFactor(self, l.destination))
          self:log("INFO", ("Delivery %s: %d %s sold on %s -> %d cr"):format(f.id, l.qty, l.resource, l.destination, gain))
          self:credit(f.owner, f.recordId, gain)
          local text = ("%s delivered: %d %s sold at %s for %d cr (%.1f each)"):format(f.id, l.qty, l.resource, l.destination, gain, unit)
          if f.owner then self:deliver(f.owner, text) end
          Feed.info(self, f.owner, text)
          Missions.onDelivery(self, f.owner)
          if Refining.isGood(l.resource) then Refining.onSale(self, l.resource, l.qty, unit) end
          self:emit("freighter_delivered", { freighter = f.id, station = f.station, destination = l.destination, resource = l.resource, qty = l.qty, credits = gain })
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

-- Above x1 a real provider gets at most one request per agent per `speed.aiMinRealSeconds` of REAL time, so the world
-- running faster never raises the real request rate. The stub makes no request and is not paced. Game-time deterministic.
function Sim:paceAllowed(agent)
  if not self.provider or self.speed <= 1 or not agent.lastRequestTick then return true end
  return self.tick - agent.lastRequestTick >= self:ticks(self.b.speed.aiMinRealSeconds * self.speed)
end

local function setAgentState(self, agent, state, why)
  if agent.state == state then return end
  if agent.state == "paused_error" then return end -- only resumeAgent leaves it
  agent.state = state
  if state == "no_compute" then
    agent.blockReason = why
    self:log("WARN", ("%s: no_compute (%s)"):format(agent.id, why))
    Feed.error(self, agent.id, why)
    self:emit("agent_no_compute", { agent = agent.id, reason = why })
  else
    agent.blockReason = nil
  end
end

-- The hourly window closed on a request that was still queued: refund it and park the agent on the budget message.
local function refuseQueued(self, reqId)
  local r = self.reqs[reqId]
  self.reqs[reqId] = nil
  if not r then return end
  for _, agent in pairs(self.agents) do
    if agent.pending == r then
      agent.pending = nil
      local rec = DecisionLog.find(self, r.rec)
      DecisionLog.answered(self, rec, { cost = self.compute:settle(r.charge, 0, 0) })
      DecisionLog.failed(self, rec, "dropped: " .. self.aiConfig.budgetMessage)
      setAgentState(self, agent, "no_compute", self.aiConfig.budgetMessage)
      return
    end
  end
end

local function finishRequest(self, reqId, tokens)
  local started, refused = self.aiQueue:complete(reqId, tokens)
  for _, startedId in ipairs(started) do
    local r = self.reqs[startedId]
    if r then r.started = true end
  end
  for _, refusedId in ipairs(refused) do refuseQueued(self, refusedId) end
  self.reqs[reqId] = nil
end

local function validCount(n) return type(n) == "number" and n == n and n >= 0 and n < math.huge end

-- Async AI provider (ai/provider.luau): the decision goes out as a request once the AiQueue lets it start, and comes back
-- through onAiResponse. nil = the sync decider only. A decision still in flight when the provider changes is refunded
-- and re-decided on the next tick.
function Sim:setProvider(provider)
  if provider == self.provider then return end
  for id, agent in pairs(self.agents) do
    local pend = agent.pending
    if pend then
      agent.pending = nil
      local cost = self.compute:settle(pend.charge, pend.input, 0)
      local rec = DecisionLog.find(self, pend.rec)
      DecisionLog.answered(self, rec, { cost = cost })
      DecisionLog.failed(self, rec, "dropped: AI provider switched")
      finishRequest(self, pend.reqId, 0)
      setAgentState(self, agent, "idle")
      self:log("WARN", id .. ": AI provider switched, pending decision dropped")
    end
  end
  self.provider = provider
  if provider then provider.budget = self.aiQueue end
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
  local realIn, realOut = resp.input_tokens, resp.output_tokens
  local rec, info = DecisionLog.find(self, pend.rec), {}
  -- Billing follows the provider's counters whenever they are valid, even if the reply is refused as invalid.
  if validCount(realIn) and validCount(realOut) then
    local est = resp.estimated_tokens or 0
    local real = realIn + realOut
    local pct = est > 0 and math.floor((real - est) / est * 100 + 0.5) or 0
    self:log("INFO", ("ai %s: tokens est %d real %d (%+d%%) in %.1fs"):format(agentId, est, real, pct, resp.seconds or 0))
    info = { output = realOut, total = real, realTokens = true, cost = self.compute:settle(pend.charge, realIn, realOut) }
    finishRequest(self, pend.reqId, real)
  else
    info = { output = self.aiConfig.estimatedOutputTokens,
      cost = self.compute:settle(pend.charge, pend.input, self.aiConfig.estimatedOutputTokens) }
    finishRequest(self, pend.reqId, pend.input + self.aiConfig.estimatedOutputTokens)
  end
  if resp.ok then info.reasoning = resp.tool_call.reasoning end
  DecisionLog.answered(self, rec, info)
  setAgentState(self, agent, "idle")
  if resp.ok then
    if resp.tool_call.reasoning ~= "" then self:log("INFO", agentId .. " reasoning: " .. resp.tool_call.reasoning) end
    self.nextReasoning = resp.tool_call.reasoning ~= "" and resp.tool_call.reasoning or nil
    self:resolveDecision(agentId, { name = resp.tool_call.tool, args = resp.tool_call.args }, pend.ctx, { record = rec })
    self.nextReasoning = nil
    return
  end
  self:log("ERROR", ("ai %s: %s (%s)"):format(agentId, resp.kind or "error", tostring(resp.error)))
  local shown = resp.kind == "invalid" and Words.provider.invalid or (resp.error == "timeout" and Words.provider.timeout or Words.provider.failed)
  Feed.error(self, agentId, ("%s (%s)"):format(shown, tostring(resp.error)))
  DecisionLog.failed(self, rec, ("%s: %s"):format(resp.kind == "invalid" and "invalid response" or "provider error", tostring(resp.error)))
  self:noteFailure(agentId, resp.kind == "invalid" and "invalid" or "provider")
  if agent.state == "paused_error" then return end
  if self.decide then
    local ok, call = pcall(self.decide, self, agentId, pend.ctx)
    if ok then
      self:log("WARN", agentId .. ": fell back to stub")
      self:resolveDecision(agentId, call, pend.ctx, { fallback = true, record = rec })
    else self:log("ERROR", "decide failed: " .. tostring(call)) end
  end
end

-- Step 6 of the tick (spec §3): decide for every agent that is allowed to.
function Sim:stepAgent(id, agent)
  if agent.state == "paused_error" then return end
  local pend = agent.pending
  if pend and pend.provider then
    if pend.started and not pend.pid then
      pend.pid = self.provider:request({ agent_id = id, prompt = pend.prompt, max_output_tokens = self.aiConfig.maxOutputTokens, queue_id = pend.reqId })
    end
    return
  end
  if pend then
    if pend.started then pend.delay = pend.delay - 1 end
    if pend.started and pend.delay <= 0 then
      agent.pending = nil
      local outTokens = Prompt.outputTokens(pend.call)
      local rec = DecisionLog.find(self, pend.rec)
      DecisionLog.answered(self, rec, { output = outTokens, reasoning = pend.call.reasoning,
        cost = self.compute:settle(pend.charge, pend.input, outTokens) })
      finishRequest(self, pend.reqId, pend.input + outTokens)
      setAgentState(self, agent, "idle")
      self:resolveDecision(id, pend.call, pend.ctx, { record = rec })
    end
    return
  end
  if agent.mode == "skill" then
    Skills.step(self, id, agent)
    return
  end
  if not self.decide then return end
  if not self:needsDecision(id) then
    if (agent.type == "miner" or agent.type == "logistician" or agent.type == "privateer" or agent.type == "refiner" or agent.type == "scavenger") and agent.state ~= "no_compute" then setAgentState(self, agent, "acting") end
    return
  end
  if not self:paceAllowed(agent) then return end
  local prompt = Prompt.build(self, id)
  local canSend, reason = self.compute:canSend(prompt.input, id)
  if not canSend then
    setAgentState(self, agent, "no_compute", reason == "budget" and self.aiConfig.budgetMessage or Words.notEnoughCompute)
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
  local reqId, status = self.aiQueue:submit({ agentId = id, monitor = agent.type == "monitor", estimate = prompt.input + self.aiConfig.maxOutputTokens })
  if not reqId then
    setAgentState(self, agent, "no_compute", self.aiConfig.budgetMessage)
    return
  end
  local charge, cost = self.compute:charge(id, prompt.input)
  if agent.type == "monitor" then Monitor.onSend(self, agent) end
  local rec = DecisionLog.open(self, id, prompt, cost)
  agent.decisions[#agent.decisions + 1] = self.tick
  agent.lastRequestTick = self.tick
  if self.provider then
    agent.pending = { provider = true, ctx = ctx, reqId = reqId, charge = charge, input = prompt.input, rec = rec.id,
      started = status == "running", prompt = Prompt.forProvider(self, id, prompt) }
    self.reqs[reqId] = agent.pending
    setAgentState(self, agent, "thinking")
    return
  end
  self.lastDecision = { agent = id, tick = self.tick, ctx = ctx, call = call, prompt = prompt.text }
  local d = self.b.ai
  agent.pending = { call = call, ctx = ctx, reqId = reqId, charge = charge, input = prompt.input, rec = rec.id, started = status == "running",
    delay = self:ticks(d.delaySecondsMin + self.rand() * (d.delaySecondsMax - d.delaySecondsMin)) }
  self.reqs[reqId] = agent.pending
  setAgentState(self, agent, "thinking")
end

function Sim:step()
  self.tick = self.tick + 1
  self.realTicks = self.realTicks + 1 / self.speed
  if self.provider then
    for _, resp in ipairs(self.provider:drain()) do self:onAiResponse(resp) end
  end
  self:stepVeins()
  Market.step(self.market)
  local byVein = self:minersByVein()
  local offline = self.offline
  for _, sid in ipairs(self.shipOrder) do
    local ship = self.ships[sid]
    -- offline only the ships of skill-mode agents move (spec §14); the others stay where they were
    if not offline or (ship.owner and self.agents[ship.owner].mode == "skill") then
      self:stepShip(ship, ship.vein and byVein[ship.vein.id] or nil)
    end
  end
  self:stepFreighters()
  self:updateTier()
  Upgrades.claimShips(self)
  Raiding.step(self)
  Refining.step(self)
  Salvage.step(self)
  for _, id in ipairs(self.agentOrder) do
    local agent = self.agents[id]
    if not offline or agent.mode == "skill" then self:stepAgent(id, agent) end
  end
  if not offline then self:updateBailout() end
  Alerts.step(self)
  Versions.step(self)
  Missions.update(self)
end

function Sim:needsDecision(agentId)
  local agent = self.agents[agentId]
  if agent.type == "miner" then return ownedShip(self, agentId).state == "idle" end
  if agent.type == "logistician" then return self.tick >= (agent.waitUntil or 0) end
  if agent.type == "monitor" then return Monitor.needsDecision(self, agent) end
  if agent.type == "privateer" then return Raiding.needsDecision(self, agent) end
  if agent.type == "refiner" then return Refining.needsDecision(self, agent) end
  if agent.type == "scavenger" then return Salvage.needsDecision(self, agent) end
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
  local agent = self.agents[agentId]
  if agent.type == "monitor" then return Monitor.context(self, agent) end
  if agent.type == "privateer" then return Raiding.context(self, agent) end
  if agent.type == "refiner" then return Refining.context(self, agent) end
  if agent.type == "scavenger" then return Salvage.context(self, agent) end
  if agent.type == "logistician" then
    local st = self.stations[agent.station]
    local markets = {}
    for _, id in ipairs(World.marketOrder) do if self:marketUnlocked(id) then markets[#markets + 1] = id end end
    local others = {}
    for _, id in ipairs(Logistics.logisticiansAt(self, st.id)) do if id ~= agentId then others[#others + 1] = id end end
    return {
      tick = self.tick,
      resources = Sim.deepCopy(self.resources),
      station = { id = st.id, planet = st.planet, kind = st.kind, cap = Logistics.storageCap(self, st) },
      stock = Sim.deepCopy(st.stock),
      freighters = Logistics.freighterRows(self, st.id),
      others_here = others,
      markets = markets,
      home = self.home,
    }
  end
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
      hold = ship.cargoCap, vein = ship.vein and ship.vein.id or nil, crowded_by = { table.unpack(ship.crowdedBy) } },
    planets = planets,
    home = self.home,
  }
end

function Sim:run(ticks) for _ = 1, ticks do self:step() end end

return Sim
