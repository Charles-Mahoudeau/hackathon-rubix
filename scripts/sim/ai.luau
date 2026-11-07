-- AI decision interface. Swapping in RUBIX later = replace ONLY Ai.decide.
-- Contract: decide(sim, agentId, context) -> { name = string, args = table }
-- AI output is always a tool call, never free text; Sim validates everything.
Ai = Ai or {}
Ai.mode = "stub" -- "stub" | "vague"

local function stub(sim, agentId, ctx)
  if agentId ~= "miner" then return { name = "report", args = { text = "idle" } } end
  local ship = ctx.ship
  if ship.cargo > 0 then return { name = "sell", args = { ship = ship.id } } end
  -- pick best known vein across harvest planets (unscanned = assume avg => index 1)
  local best, bp, bv = -1, nil, nil
  for id, p in pairs(ctx.planets) do
    if p.kind == "harvest" then
      for i, v in ipairs(p.veins) do
        local score = (v.scanned and v.richness or 1) / (p.jumps + 1)
        if score > best then best, bp, bv = score, id, i end
      end
    end
  end
  return { name = "mine", args = { planet = bp, vein = bv, ship = ship.id } }
end

-- Deliberately vague: sometimes emits invalid calls, to exercise validation.
local function vague(sim, agentId, ctx)
  if sim.rand() < sim.b.ai.vagueErrorRate then
    local bad = { { name = "dig", args = {} }, { name = "mine", args = { planet = "kessel", vein = 99 } }, { name = "scan", args = { planet = "kessel" } } }
    return bad[1 + math.floor(sim.rand() * #bad)]
  end
  return stub(sim, agentId, ctx)
end

function Ai.decide(sim, agentId, ctx)
  if Ai.mode == "vague" then return vague(sim, agentId, ctx) end
  return stub(sim, agentId, ctx)
end

