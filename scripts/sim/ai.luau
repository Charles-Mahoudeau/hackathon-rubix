-- AI decision interface. Swapping in RUBIX later = replace ONLY Ai.decide.
-- Contract: decide(sim, agentId, context) -> { name = string, args = table }
-- AI output is always a tool call, never free text; Sim validates everything.
Ai = Ai or {}
Ai.mode = "stub" -- "stub" | "vague"

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

function Ai.decide(sim, agentId, ctx)
  if Ai.mode == "vague" then return vague(sim, agentId, ctx) end
  return stub(sim, agentId, ctx)
end

