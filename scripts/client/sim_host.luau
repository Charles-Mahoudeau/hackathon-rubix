-- Gives the client's sim its AI decider (the sim the client runs until the net protocol replicates the server one,
-- spec §16, [ENGINE]). Without a decider Sim:stepAgent makes no decision, so every agent would stay idle whatever its
-- directive says. Loaded, new, reset and placeholder sims all come through here.
-- The Axis provider is server-only (keys, rtype.Http plugin), so the client stand-in always runs the stub (spec §10.5).
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")

local SimHost = {}

-- Returns the sim, so it can wrap a constructor call.
function SimHost.attach(sim)
  sim:setDecider(Ai.decide)
  return sim
end

function SimHost.new(opts) return SimHost.attach(Sim.new(opts)) end

return SimHost
