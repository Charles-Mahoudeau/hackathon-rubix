-- Server-side simulation core. Pure Luau, no engine deps, headless-runnable.
local Balance = require("@scripts/config/balance")
local World = require("@scripts/config/world")

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
  self.agents, self.ships = {}, {}
  for kind, def in pairs(b.agents) do
    self.agents[kind] = { id = kind, tier = def.startTier, tools = {}, pending = nil, mode = "default" }
    for _, t in ipairs(def.tools) do self.agents[kind].tools[t] = true end
  end
  self.ships.s1 = { id = "s1", owner = "miner", state = "idle", at = World.homePlanet, cargo = 0, cargoF = 0,
    ore = nil, timer = 0, vein = nil, engineMark = b.ship.engineMark, engineMult = b.ship.engineMult }
  self.skills = {}
  return self
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
  local ship = self.ships[args.ship or "s1"]
  local shipTool = n == "mine" or n == "return" or n == "sell" or n == "scan"
  if agent.id == "miner" and (shipTool or n == "wait") and not ship then return false, "unknown ship" end
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
  elseif n == "ship" then
    if not World.markets[args.destination or ""] then return false, "bad destination" end
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
  local ship = self.ships[args.ship or "s1"]
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
  elseif n == "ship" then
    self:log("INFO", "ship order to " .. args.destination)
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

function Sim:stepShip(ship)
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
    local rate = b.ship.drillRate * v.richness * World.ores[v.ore].hardness
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
  local ship = self.ships.s1
  if agentId == "miner" and ctx and ctx.ship and ctx.ship.state ~= ship.state then
    self:log("WARN", ("%s: stale decision dropped (ship was %s, now %s)"):format(agentId, ctx.ship.state, ship.state))
    return false, "stale"
  end
  return self:apply(agentId, call)
end

function Sim:step()
  self.tick = self.tick + 1
  self:stepVeins()
  for _, ship in pairs(self.ships) do self:stepShip(ship) end
  for id, agent in pairs(self.agents) do
    local pend = agent.pending
    if pend then
      pend.delay = pend.delay - 1
      if pend.delay <= 0 then agent.pending = nil; self:resolveDecision(id, pend.call, pend.ctx) end
    elseif self.decide and self:needsDecision(id) then
      local ctx = self:context(id)
      local ok, call = pcall(self.decide, self, id, ctx)
      if not ok then self:log("ERROR", "decide failed: " .. tostring(call))
      else
        self.resources.compute = math.max(0, self.resources.compute - self.b.ai.computePerDecision)
        self.lastDecision = { agent = id, tick = self.tick, ctx = ctx, call = call }
        local d = self.b.ai
        agent.pending = { call = call, ctx = ctx,
          delay = self:ticks(d.delaySecondsMin + self.rand() * (d.delaySecondsMax - d.delaySecondsMin)) }
      end
    end
  end
end

function Sim:needsDecision(agentId)
  if agentId == "miner" then return self.ships.s1.state == "idle" end
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
  local ship = self.ships.s1
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
      hold = self.b.ship.cargoCap, vein = ship.vein and ship.vein.id or nil },
    planets = planets,
    home = self.home,
  }
end

function Sim:run(ticks) for _ = 1, ticks do self:step() end end

return Sim
