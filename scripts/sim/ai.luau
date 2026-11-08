-- AI decision interface. Swapping in RUBIX later = replace ONLY Ai.decide.
-- Contract: decide(sim, agentId, context) -> { name = string, args = table }
-- AI output is always a tool call, never free text; Sim validates everything.
local World = require("@scripts/config/world")
local AiConfig = require("@scripts/config/ai")
local Skills = require("@scripts/sim/skills")

local Ai = {}
local mode = "stub" -- "stub" (spec §10.5, reads the directive) | "optimal" (always the best call) | "vague" (random bad calls)
local providers = {} -- name -> decide(sim, agentId, ctx); the real provider registers itself here
local provider = "stub"

local logisticianStub, monitorStub

local function optimal(sim, agentId, ctx)
  local kind = sim.agents[agentId].type
  if kind == "logistician" then return logisticianStub(sim, agentId, ctx) end
  if kind == "monitor" then return monitorStub(sim, agentId, ctx) end
  if kind ~= "miner" then return { name = "report", args = { message = "idle" } } end
  local ship = ctx.ship
  if ship.cargo > 0 then return { name = "sell", args = { ship = ship.id } } end
  -- best known vein on a reachable planet: richness (band midpoint if unscanned) x hardness x depot price, per trip jump
  local mid = { low = 1.0, medium = 1.5, high = 2.0 }
  local best, bv = -1, nil
  for _, p in pairs(ctx.planets) do
    if p.reachable then
      for _, v in ipairs(p.veins) do
        local ore = World.ores[v.ore]
        local depleted = v.reserve ~= nil and v.reserve < 1
        local score = (v.richness or mid[v.band]) * ore.hardness * ore.basePrice * p.depotRate / (v.jumps + 1)
        if not depleted and score > best then best, bv = score, v.id end
      end
    end
  end
  if not bv then return { name = "wait", args = { seconds = sim.b.waitMinSeconds } } end
  return { name = "mine", args = { vein = bv, ship = ship.id } }
end

local function sortedKeys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end

local function firstWord(text, words)
  local best, bestPos
  for _, w in ipairs(words) do
    local pos = text:find("%f[%a]" .. w:lower())
    if pos and (not bestPos or pos < bestPos) then best, bestPos = w, pos end
  end
  return best
end

-- Spec §10.5: a deterministic keyword interpreter. What the order and the directive leave open is picked from the
-- sim's stub stream, so a vague prompt wanders (random ore, random hold %) and a precise one works well.
-- The order is read first, so it wins over the directive.
local function directiveStub(sim, agentId, ctx)
  local kind = sim.agents[agentId].type
  if kind == "logistician" then return logisticianStub(sim, agentId, ctx) end
  if kind == "monitor" then return monitorStub(sim, agentId, ctx) end
  if kind ~= "miner" then return { name = "report", args = { message = "idle" } } end
  local agent = sim.agents[agentId]
  local texts = { (agent.order or ""):lower(), (agent.directive or ""):lower() }
  local function first(fn)
    for _, t in ipairs(texts) do
      local v = fn(t)
      if v ~= nil then return v end
    end
  end
  local cfg = AiConfig.stub
  local rand = sim.randStub
  local ship = ctx.ship
  if ship.cargo > 0 then return { name = "sell", args = { ship = ship.id } } end

  local rows = {}
  for _, pid in ipairs(World.planetOrder) do
    local p = ctx.planets[pid]
    if p and p.reachable then
      for _, v in ipairs(p.veins) do
        if not (v.reserve ~= nil and v.reserve < 1) then rows[#rows + 1] = { planet = pid, vein = v } end
      end
    end
  end
  if sim:hasTool(agentId, "scan") and first(function(t) if t:find("scan", 1, true) then return true end end) then
    for _, pid in ipairs(World.planetOrder) do
      local p = ctx.planets[pid]
      if p and p.reachable then
        for _, v in ipairs(p.veins) do
          if not v.scanned then return { name = "scan", args = { planet = pid } } end
        end
      end
    end
  end
  if #rows == 0 then return { name = "wait", args = { seconds = AiConfig.stub.waitSeconds } } end

  local function pick(list) return list[1 + math.floor(rand() * #list)] end
  local function filtered(fn)
    local out = {}
    for _, r in ipairs(rows) do if fn(r) then out[#out + 1] = r end end
    return out
  end

  local choice
  local veinId = first(function(t)
    for id in t:gmatch("%f[%w](%a%d)%f[%W]") do
      for _, r in ipairs(rows) do if r.vein.id:lower() == id then return r.vein.id end end
    end
  end)
  if veinId then
    for _, r in ipairs(rows) do if r.vein.id == veinId then choice = r end end
  else
    local ore = first(function(t)
      local w = firstWord(t, sortedKeys(World.ores))
      if w then for _, r in ipairs(rows) do if r.vein.ore == w then return w end end end
    end)
    local pool = ore and filtered(function(r) return r.vein.ore == ore end) or rows
    local planet = first(function(t)
      for _, r in ipairs(pool) do
        if t:find("%f[%a]" .. r.planet:lower()) then return r.planet end
      end
    end)
    if planet then pool = (function() local o = {} for _, r in ipairs(pool) do if r.planet == planet then o[#o + 1] = r end end return o end)() end
    local mode = first(function(t)
      if t:find("richest", 1, true) or t:find("best", 1, true) then return "richest" end
      if t:find("nearest", 1, true) or t:find("closest", 1, true) then return "nearest" end
    end)
    local mid = { low = 1.0, medium = 1.5, high = 2.0 }
    if mode == "richest" then
      for _, r in ipairs(pool) do
        local rich = r.vein.richness or mid[r.vein.band]
        if not choice or rich > (choice.vein.richness or mid[choice.vein.band]) then choice = r end
      end
    elseif mode == "nearest" then
      for _, r in ipairs(pool) do if not choice or r.vein.jumps < choice.vein.jumps then choice = r end end
    else
      choice = pick(pool)
    end
  end
  local pct = first(function(t)
    local v = t:match("(%d+)%s*%%")
    if v then return math.max(10, math.min(100, tonumber(v))) end
  end)
  if not pct then pct = cfg.holdPct[1] + math.floor(rand() * (cfg.holdPct[2] - cfg.holdPct[1] + 1)) end
  return { name = "mine", args = { vein = choice.vein.id, stop_at_hold_pct = pct } }
end

-- Logistician stub (spec §10.5). The order, then the directive, may name an ore, a market and "sell" / "ship". Left open,
-- it picks the fullest stock of at least `minStock` and a random market that buys it, so two vague Logisticians on one
-- station pick the same stock and collide (spec §8.6). A stock below `minStock` or no docked freighter: wait.
logisticianStub = function(sim, agentId, ctx)
  local agent = sim.agents[agentId]
  local texts = { (agent.order or ""):lower(), (agent.directive or ""):lower() }
  local cfg = sim.b.logistics.stub
  local function first(fn)
    for _, t in ipairs(texts) do
      local v = fn(t)
      if v ~= nil then return v end
    end
  end
  local idle = { name = "wait", args = { seconds = cfg.waitSeconds } }
  local ore = first(function(t) return firstWord(t, sortedKeys(World.ores)) end)
  local market = first(function(t) return firstWord(t, World.marketOrder) end)
  local wantsSell = first(function(t) if t:find("sell", 1, true) then return true end end)
  local wantsShip = first(function(t) if t:find("ship", 1, true) then return true end end)
  local resource, have = ore, ore and ctx.stock[ore] or 0
  if not ore then
    for _, o in ipairs(World.oreOrder) do
      local q = ctx.stock[o] or 0
      if q >= cfg.minStock and q > have then resource, have = o, q end
    end
  end
  if not resource or have < 1 then return idle end
  local cargo = sim.b.freighter.cargo
  if wantsSell and not wantsShip and market ~= "halcyon" and market ~= "meridian" then
    local buyer = (market == "orbis" and ctx.station.kind == "main") and "orbis" or "hmc"
    return { name = "sell", args = { resource = resource, qty = "all", buyer = buyer } }
  end
  local docked = false
  for _, f in ipairs(ctx.freighters) do if f.state == "docked" then docked = true end end
  if not docked then return idle end
  local dest = market
  if not dest then
    local pool = {}
    for _, m in ipairs(ctx.markets) do
      if World.markets[m].demand[resource] then pool[#pool + 1] = m end
    end
    if #pool == 0 then return idle end
    dest = pool[1 + math.floor(sim.randStub() * #pool)]
  end
  return { name = "ship", args = { resource = resource, qty = math.min(have, cargo), destination = dest } }
end

-- Spec §10.5 for the Monitor: a keyword interpreter over its order and directive, acting on the oldest queued alert.
-- What the text leaves open is picked from the stub stream; with no alert it waits.
local function parseParams(text)
  local out = {}
  for k, v in tostring(text or ""):gmatch("([%w_]+)=([^,]+)") do out[k] = tonumber(v) or v end
  return out
end

-- Best vein for a `vein` parameter: not excluded, not depleted, the highest reserve percent (unscanned counts as 50).
local function bestVein(ctx, decl, exclude, reach)
  local f, best, bestPct = decl.filter or {}, nil, -1
  for _, v in ipairs(ctx.veins) do
    local pct = v.pct or 50
    if v.id ~= exclude and pct > 0 and reach(v) and (not f.resource or v.ore == f.resource) and (not f.planet or v.planet == f.planet) and pct > bestPct then
      best, bestPct = v.id, pct
    end
  end
  return best
end

-- Parameter values for `skill` with every vein parameter on a fresh vein the target can reach; nil when another kind cannot be filled in.
local function rotatedParams(sim, ctx, skill, known, depleted, target)
  local params = {}
  local ship = target.type == "miner" and sim:ownedShip(target.id) or nil
  local function reach(v) return not ship or sim:inRange(ship, v.planet) end
  for name, decl in pairs(skill.params or {}) do
    if decl.kind == "vein" then
      params[name] = bestVein(ctx, decl, depleted, reach)
      if not params[name] then return nil end
    elseif known[name] ~= nil then
      params[name] = known[name]
    else
      return nil
    end
  end
  return params
end

function monitorStub(sim, agentId, ctx)
  local agent = sim.agents[agentId]
  local wait = { name = "wait", args = { seconds = sim.b.monitor.stubWaitSeconds } }
  local alert = ctx.alerts[1]
  if not alert or not alert.agent or not sim.agents[alert.agent] then return wait end
  local target = sim.agents[alert.agent]
  local texts = { (agent.order or ""):lower(), (agent.directive or ""):lower() }
  local function has(...)
    for _, t in ipairs(texts) do
      for _, w in ipairs({ ... }) do if t:find(w, 1, true) then return true end end
    end
    return false
  end
  local known = parseParams(alert.params)
  local depleted = known.vein

  if has("resume", "restart", "unstick") then
    return { name = "resume_agent", args = { agent = target.id } }
  end
  if has("next vein", "another vein", "rotate") and alert.skill and sim.skills[alert.skill] then
    local params = rotatedParams(sim, ctx, sim.skills[alert.skill], known, depleted, target)
    if params then return { name = "assign_skill", args = { agent = target.id, skill = alert.skill, params = params } } end
  end
  if has("skill", "switch", "reassign") then
    for _, name in ipairs(Skills.names(sim)) do
      local skill = sim.skills[name]
      if skill.agent_type == target.type and name ~= alert.skill then
        local params = rotatedParams(sim, ctx, skill, known, depleted, target)
        if params then return { name = "assign_skill", args = { agent = target.id, skill = name, params = params } } end
      end
    end
  end
  if has("order", "tell") then
    return { name = "set_order", args = { agent = target.id, text = sim.b.monitor.stubOrder:format(alert.reason) } }
  end
  if has("pause") and alert.type == "losing_money" then
    return { name = "pause_agent", args = { agent = target.id } }
  end
  local options = {
    { name = "set_order", args = { agent = target.id, text = sim.b.monitor.stubOrder:format(alert.reason) } },
    { name = "resume_agent", args = { agent = target.id } },
    { name = "pause_agent", args = { agent = target.id } },
    wait,
  }
  local valid = {}
  for _, call in ipairs(options) do if sim:validate(agentId, call) then valid[#valid + 1] = call end end
  return valid[1 + math.floor(sim.randStub() * #valid)]
end

-- Deliberately vague: sometimes emits invalid calls, to exercise validation.
local function vague(sim, agentId, ctx)
  if sim.rand() < sim.b.ai.vagueErrorRate then
    local bad = { { name = "dig", args = {} }, { name = "mine", args = { vein = "K99" } }, { name = "scan", args = { planet = "kessa" } },
      { name = "mine", args = { vein = "A1" } } }
    return bad[1 + math.floor(sim.rand() * #bad)]
  end
  return optimal(sim, agentId, ctx)
end

-- The returned module table is read-only, so the mode lives in a local behind a setter.
function Ai.setMode(m)
  assert(m == "stub" or m == "optimal" or m == "vague", "Ai.setMode: unknown mode " .. tostring(m))
  mode = m
end

function Ai.register(name, decide)
  assert(name ~= "stub" and type(decide) == "function", "Ai.register: needs a name other than 'stub' and a function")
  providers[name] = decide
end

-- Debug panel / config switch (spec §10.1). Returns ok, err; an unregistered provider leaves the current one in place.
function Ai.use(name)
  if name ~= "stub" and not providers[name] then return false, "provider_unavailable: " .. tostring(name) end
  provider = name
  return true
end

function Ai.provider() return provider end

function Ai.decide(sim, agentId, ctx)
  if provider ~= "stub" then return providers[provider](sim, agentId, ctx) end
  if mode == "vague" then return vague(sim, agentId, ctx) end
  if mode == "stub" then return directiveStub(sim, agentId, ctx) end
  return optimal(sim, agentId, ctx)
end

return Ai
