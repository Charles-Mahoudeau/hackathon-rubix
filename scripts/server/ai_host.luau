-- Server-side wiring of the AI provider into a Sim, driven by config/ai.luau and switchable at runtime (debug panel).
-- The server tick system calls AiHost.attach(sim) once; the stub stays the fallback and the offline path.
local AiConfig = require("@scripts/config/ai")
local AxisHttp = require("@scripts/server/axis_http")
local Provider = require("@scripts/ai/provider")

local AiHost = {}

local provider = nil

local function axisProvider(run)
  if not provider then
    provider = Provider.new(AiConfig, { transport = AxisHttp, now = AxisHttp.now, run = run })
    AxisHttp.onFrame(function() provider:update() end)
  end
  return provider
end

-- name: "stub" | "axis". `run` names the conversation (a new game = a new run = fresh agent memory).
function AiHost.select(sim, name, run)
  assert(name == "stub" or name == "axis", "AiHost.select: unknown provider " .. tostring(name))
  sim:setRealClock(AxisHttp.now)
  sim:setProvider(name == "axis" and axisProvider(run or tostring(sim.b.seed)) or nil)
end

function AiHost.attach(sim) AiHost.select(sim, AiConfig.provider) end

return AiHost
