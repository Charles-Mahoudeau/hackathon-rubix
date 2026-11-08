-- AI decision interface. Swapping in RUBIX later = replace ONLY Ai.decide.
-- Contract: decide(sim, agentId, context) -> { name = string, args = table }
-- AI output is always a tool call, never free text; Sim validates everything.
local World = require("@scripts/config/world")
local AiConfig = require("@scripts/config/ai")

local Ai = {}
local mode = "stub" -- "stub" (spec §10.5, reads the directive) | "optimal" (always the best call) | "vague" (random bad calls)
local providers = {} -- name -> decide(sim, agentId, ctx); the real provider registers itself here
local provider = "stub"

local function optimal(sim, agentId, ctx)
  if sim.agents[agentId].type ~= "miner" then return { name = "report", args = { message = "idle" } } end
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
  if sim.agents[agentId].type ~= "miner" then return { name = "report", args = { message = "idle" } } end
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
