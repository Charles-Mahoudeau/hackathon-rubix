-- AI decision interface. Swapping in RUBIX later = replace ONLY Ai.decide.
-- Contract: decide(sim, agentId, context) -> { name = string, args = table }
-- AI output is always a tool call, never free text; Sim validates everything.
local World = require("@scripts/config/world")

local Ai = {}
local mode = "stub" -- "stub" | "vague"
local providers = {} -- name -> decide(sim, agentId, ctx); the real provider registers itself here
local provider = "stub"

local function stub(sim, agentId, ctx)
  if agentId ~= "miner" then return { name = "report", args = { message = "idle" } } end
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

-- Deliberately vague: sometimes emits invalid calls, to exercise validation.
local function vague(sim, agentId, ctx)
  if sim.rand() < sim.b.ai.vagueErrorRate then
    local bad = { { name = "dig", args = {} }, { name = "mine", args = { vein = "K99" } }, { name = "scan", args = { planet = "kessa" } },
      { name = "mine", args = { vein = "A1" } } }
    return bad[1 + math.floor(sim.rand() * #bad)]
  end
  return stub(sim, agentId, ctx)
end

-- The returned module table is read-only, so the mode lives in a local behind a setter.
function Ai.setMode(m)
  assert(m == "stub" or m == "vague", "Ai.setMode: unknown mode " .. tostring(m))
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
  return stub(sim, agentId, ctx)
end

return Ai
