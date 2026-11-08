-- Builds the sim the client runs until the net protocol replicates the server one (spec §16, [ENGINE]).
-- Without a decider Sim:stepAgent makes no decision, so every agent would stay idle whatever its directive says.
-- The Axis provider is server-only (keys, rtype.Http plugin), so the client stand-in always runs the stub (spec §10.5).
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")

local SimHost = {}

function SimHost.new(opts)
  local sim = Sim.new(opts)
  sim:setDecider(Ai.decide)
  return sim
end

return SimHost
