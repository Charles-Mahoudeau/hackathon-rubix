-- Server-side simulation core. Pure Luau, no engine deps, headless-runnable.
local Balance = require("@scripts/config/balance")
local World = require("@scripts/config/world")
local AiConfig = require("@scripts/config/ai")
local AiQueue = require("@scripts/sim/ai_queue")

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
  local self = setmetatable({ b = b, tick = 0, logs = {}, seed = seed, rng = { main = seed }, tier = 1,
    debug = { creditBoosts = 0 } }, Sim)
  -- Linear congruential stream; its whole state is rng.main, so a save can resume it exactly.
  self.rand = function()
    local s = (self.rng.main * 1103515245 + 12345) % 2147483648
    self.rng.main = s
    return s / 2147483648
  end
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
  -- Clock for the hourly token budget: game time here; the real provider injects real time (GR5-15).
  local aiCfg = opts.aiConfig or AiConfig
  self.aiQueue = AiQueue.new(aiCfg, opts.aiClock or function() return self.tick * b.tickSeconds end)
  self.aiConfig = aiCfg
  return self
end

-- A new agent of `kind` (a key of balance.agents) under `id`. `opts.tier` / `opts.station` override the defaults.
function Sim:addAgent(id, kind, opts)
  opts = opts or {}
  local def = self.b.agents[kind]
  local agent = { id = id, type = kind, tier = opts.tier or def.startTier, tools = {}, pending = nil, mode = "default",
    state = "idle", station = opts.station or self.home, decisions = {}, throttled = false }
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
function Sim:apply(agentId, call)
  local ok, err = self:validate(agentId, call)
  if not ok then
    self:log("ERROR", agentId .. ": rejected " .. tostring(type(call) == "table" and call.name) .. " (" .. err .. ")")
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
    return true, { freighter_id = f.id, eta_s = oneWay }
  end
  if n == "mine" then
    local vein = self.veins[args.vein]
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
  elseif n == "report" then
    self:log("INFO", agentId .. " report: " .. tostring(args.message))
  elseif n == "run_skill" then
    self:log("INFO", "run_skill " .. args.name)
    return self:apply(agentId, self.skills[args.name])
  end
  return true
end

-- Sell the hold at the depot (HMC) of planet `planetId`. Empties the hold and its accumulator.
function Sim:sell(ship, planetId)
  if ship.cargo > 0 and ship.ore then
    local price = self.planets[planetId].depotRate * World.ores[ship.ore].basePrice
    local gain = math.floor(ship.cargo * price)
    self.resources.credits = self.resources.credits + gain
    self.lifetimeRevenue = self.lifetimeRevenue + gain
    self:log("INFO", ("sold %d %s for %d"):format(ship.cargo, ship.ore, gain))
    ship.cargo, ship.cargoF, ship.ore = 0, 0, nil
  end
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
        if ship.vein.reserve < 1 then self:apply(ship.owner, { name = "return", args = { ship = ship.id } }) end
      else
        ship.vein = nil
        ship.crowdedBy = {}
        if ship.cargo > 0 then self:sell(ship, ship.at) else ship.state = "idle" end
      end
    end
  elseif ship.state == "scanning" or ship.state == "waiting" then
    ship.timer = ship.timer - 1
    if ship.timer <= 0 then
      if ship.state == "scanning" then
        for _, v in ipairs(self.planets[ship.scanPlanet].veins) do v.scanned = true end
        self:log("INFO", "scan " .. ship.scanPlanet)
      end
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
    if ship.cargo >= b.ship.cargoCap or v.reserve < 1 then
      if ship.cargo >= b.ship.cargoCap then ship.cargo, ship.cargoF = b.ship.cargoCap, b.ship.cargoCap end
      self:apply(ship.owner, { name = "return", args = { ship = ship.id } })
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

-- A decision made against `ctx` arrives later (async provider). Reject it if the world moved under it,
-- otherwise apply() re-validates every precondition against the live state.
function Sim:resolveDecision(agentId, call, ctx)
  local ship = ownedShip(self, agentId)
  if self.agents[agentId].type == "miner" and ctx and ctx.ship and ctx.ship.state ~= ship.state then
    self:log("WARN", ("%s: stale decision dropped (ship was %s, now %s)"):format(agentId, ctx.ship.state, ship.state))
    return false, "stale"
  end
  return self:apply(agentId, call)
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
  agent.state = state
  if state == "no_compute" then
    agent.blockReason = why
    self:log("WARN", ("%s: no_compute (%s)"):format(agent.id, why))
    self:emit("agent_no_compute", { agent = agent.id, reason = why })
  else
    agent.blockReason = nil
  end
end

local function finishRequest(self, agent, reqId)
  for _, startedId in ipairs(self.aiQueue:complete(reqId, self.b.ai.stubTokensPerDecision)) do
    local r = self.reqs[startedId]
    if r then r.started = true end
  end
  self.reqs[reqId] = nil
end

-- Step 6 of the tick (spec §3): decide for every agent that is allowed to.
function Sim:stepAgent(id, agent)
  local pend = agent.pending
  if pend then
    if pend.started then pend.delay = pend.delay - 1 end
    if pend.started and pend.delay <= 0 then
      agent.pending = nil
      finishRequest(self, agent, pend.reqId)
      self:resolveDecision(id, pend.call, pend.ctx)
    end
    return
  end
  if not self.decide then return end
  if not self:needsDecision(id) then
    if agent.type == "miner" and agent.state ~= "no_compute" then setAgentState(self, agent, "acting") end
    return
  end
  if self.aiQueue:budgetReached() then
    setAgentState(self, agent, "no_compute", self.aiConfig.budgetMessage)
    return
  end
  if self.resources.compute < self.b.ai.computePerDecision then
    setAgentState(self, agent, "no_compute", "not enough Compute")
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
  local ok, call = pcall(self.decide, self, id, ctx)
  if not ok then self:log("ERROR", "decide failed: " .. tostring(call)); return end
  local reqId, status = self.aiQueue:submit({ agentId = id, monitor = agent.type == "monitor" })
  if not reqId then
    setAgentState(self, agent, "no_compute", self.aiConfig.budgetMessage)
    return
  end
  self.resources.compute = self.resources.compute - self.b.ai.computePerDecision
  agent.decisions[#agent.decisions + 1] = self.tick
  self.lastDecision = { agent = id, tick = self.tick, ctx = ctx, call = call }
  local d = self.b.ai
  agent.pending = { call = call, ctx = ctx, reqId = reqId, started = status == "running",
    delay = self:ticks(d.delaySecondsMin + self.rand() * (d.delaySecondsMax - d.delaySecondsMin)) }
  self.reqs[reqId] = agent.pending
  setAgentState(self, agent, "thinking")
end

function Sim:step()
  self.tick = self.tick + 1
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
