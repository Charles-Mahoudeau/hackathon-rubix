-- Server-side simulation core. Pure Lua/Luau, no engine deps, headless-runnable.
local balance = require("config.balance")
local world = require("config.world")
local Sim = {}
Sim.__index = Sim

local function lcg(seed)
  local s = seed
  return function()
    s = (s * 1103515245 + 12345) % 2147483648
    return s / 2147483648
  end
end

function Sim.new(opts)
  opts = opts or {}
  local b = opts.balance or balance
  local self = setmetatable({ b = b, tick = 0, logs = {}, rand = lcg(opts.seed or b.seed) }, Sim)
  self.resources = { credits = b.startCredits, titanium = 0, cobalt = 0,
    compute = b.startCompute, reputation = b.startReputation }
  self.warehouse = { titanium = 0, cobalt = 0 }
  self.planets = {}
  for _, p in ipairs(world.planets) do
    local planet = { id = p.id, name = p.name, kind = p.kind, jumps = p.jumps, tier = p.tier,
      prices = p.prices, ore = p.ore, veins = {} }
    if p.kind == "harvest" then
      for i = 1, world.veinCount do
        local r = world.veinRichnessMin + self.rand() * (world.veinRichnessMax - world.veinRichnessMin)
        planet.veins[i] = { richness = r * (p.oreBonus or 1), scanned = false }
      end
    end
    self.planets[p.id] = planet
  end
  self.buyer = world.startBuyer
  self.agents, self.ships = {}, {}
  for kind, def in pairs(b.agents) do
    self.agents[kind] = { id = kind, tier = def.startTier, tools = {}, pending = nil, mode = "default" }
    for _, t in ipairs(def.tools) do self.agents[kind].tools[t] = true end
  end
  self.ships.s1 = { id = "s1", owner = "miner", state = "idle", at = world.startBuyer, cargo = 0, ore = nil,
    timer = 0, target = nil, skill = nil }
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

-- Validate a tool call. Returns ok, err. Never throws.
function Sim:validate(agentId, call)
  local agent = self.agents[agentId]
  if not agent then return false, "unknown agent" end
  if type(call) ~= "table" or type(call.name) ~= "string" then return false, "malformed call" end
  local args = call.args or {}
  if type(args) ~= "table" then return false, "args must be table" end
  if not agent.tools[call.name] then return false, "unknown or disallowed tool: " .. call.name end
  if not tierHasTool(self, agent, call.name) then return false, "tool not equipped: " .. call.name end
  local ship = self.ships[args.ship or "s1"]
  local n = call.name
  if n == "mine" or n == "scan" then
    local p = self.planets[args.planet]
    if not p or p.kind ~= "harvest" then return false, "bad planet" end
    if n == "mine" then
      if type(args.vein) ~= "number" or not p.veins[args.vein] then return false, "bad vein" end
    end
  elseif n == "sell" then
    if args.planet and (not self.planets[args.planet] or self.planets[args.planet].kind ~= "trade") then
      return false, "bad trade planet"
    end
  elseif n == "store" then
    if not self.warehouse[args.resource or ""] or type(args.amount) ~= "number" or args.amount <= 0 then
      return false, "bad store args"
    end
  elseif n == "ship" then
    if not self.planets[args.to or ""] or self.planets[args.to].kind ~= "trade" then return false, "bad destination" end
  elseif n == "run_skill" then
    if not self.skills[args.name or ""] then return false, "unknown skill" end
  end
  if agent.id == "miner" and (n == "mine" or n == "return" or n == "sell" or n == "scan") and not ship then
    return false, "unknown ship"
  end
  return true
end

local function travelTicks(self, from, to)
  local a, b = self.planets[from].jumps, self.planets[to].jumps
  return math.max(1, math.abs(a - b)) * self:ticks(self.b.jumpSeconds)
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
    ship.state, ship.target, ship.timer = "travel_out", { planet = args.planet, vein = args.vein }, travelTicks(self, ship.at, args.planet)
    ship.dest = args.planet
  elseif n == "return" then
    ship.state, ship.dest, ship.timer = "travel_back", self.buyer, travelTicks(self, ship.at, self.buyer)
  elseif n == "sell" then
    local dest = args.planet or self.buyer
    if ship.at ~= dest then
      ship.state, ship.dest, ship.timer, ship.sellOnArrival = "travel_back", dest, travelTicks(self, ship.at, dest), true
    else self:sell(ship, dest) end
  elseif n == "scan" then
    if self.resources.compute < self.b.ship.scanCost then self:log("ERROR", "not enough compute"); return false, "compute" end
    self.resources.compute = self.resources.compute - self.b.ship.scanCost
    for _, v in ipairs(self.planets[args.planet].veins) do v.scanned = true end
    self:log("INFO", "scan " .. args.planet)
  elseif n == "store" then
    local have = self.resources[args.resource]
    local amt = math.min(args.amount, have, self.b.warehouse.capacity - self.warehouse[args.resource])
    self.resources[args.resource] = have - amt
    self.warehouse[args.resource] = self.warehouse[args.resource] + amt
  elseif n == "ship" then
    self:log("INFO", "ship order to " .. args.to)
  elseif n == "report" then
    self:log("INFO", agentId .. " report: " .. tostring(args.text))
  elseif n == "run_skill" then
    self:log("INFO", "run_skill " .. args.name)
    return self:apply(agentId, self.skills[args.name])
  end
  return true
end

function Sim:sell(ship, planetId)
  if ship.cargo > 0 and ship.ore then
    local price = self.planets[planetId].prices[ship.ore]
    local gain = math.floor(ship.cargo * price)
    self.resources.credits = self.resources.credits + gain
    self:log("INFO", ("sold %d %s for %d"):format(ship.cargo, ship.ore, gain))
    ship.cargo, ship.ore = 0, nil
  end
  ship.state = "idle"
end

function Sim:stepShip(ship)
  local b = self.b
  if ship.state == "travel_out" or ship.state == "travel_back" then
    ship.timer = ship.timer - 1
    if ship.timer <= 0 then
      ship.at = ship.dest
      if ship.state == "travel_out" then ship.state = "mining"
      elseif ship.sellOnArrival or ship.cargo > 0 then ship.sellOnArrival = nil; self:sell(ship, ship.at)
      else ship.state = "idle" end
    end
  elseif ship.state == "mining" then
    local p = self.planets[ship.target.planet]
    local v = p.veins[ship.target.vein]
    ship.ore = p.ore
    ship.cargoF = (ship.cargoF or 0) + b.ship.mineRatePerSecond * b.tickSeconds * v.richness
    ship.cargo = math.floor(ship.cargoF)
    if ship.cargo >= b.ship.cargoCap then
      ship.cargo, ship.cargoF = b.ship.cargoCap, 0
      self:apply(ship.owner, { name = "return", args = { ship = ship.id } })
    end
  end
end

-- AI hook: decide(sim, agentId, context) -> toolCall. Swap in ai module's decide.
function Sim:setDecider(fn) self.decide = fn end

function Sim:step()
  self.tick = self.tick + 1
  for _, ship in pairs(self.ships) do self:stepShip(ship) end
  for id, agent in pairs(self.agents) do
    local pend = agent.pending
    if pend then
      pend.delay = pend.delay - 1
      if pend.delay <= 0 then agent.pending = nil; self:apply(id, pend.call) end
    elseif self.decide and self:needsDecision(id) then
      local ok, call = pcall(self.decide, self, id, self:context(id))
      if not ok then self:log("ERROR", "decide failed: " .. tostring(call))
      else
        self.resources.compute = math.max(0, self.resources.compute - self.b.ai.computePerDecision)
        local d = self.b.ai
        agent.pending = { call = call, delay = self:ticks(d.delaySecondsMin + self.rand() * (d.delaySecondsMax - d.delaySecondsMin)) }
      end
    end
  end
end

function Sim:needsDecision(agentId)
  if agentId == "miner" then return self.ships.s1.state == "idle" end
  return false
end

function Sim:context(agentId)
  return { tick = self.tick, resources = self.resources, ship = self.ships.s1, planets = self.planets, buyer = self.buyer }
end

function Sim:run(ticks) for _ = 1, ticks do self:step() end end

return Sim
