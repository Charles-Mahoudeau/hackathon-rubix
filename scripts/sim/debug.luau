-- Debug actions (spec §16.4). Server side, no UI: the panel (ui/debug.luau) and the `debug_*` messages call Debug.run.
-- run(sim, action, args, ctx) -> ok, result | error string. Disabled builds reject everything.
local DebugConfig = require("@scripts/config/debug")
local Json = require("./json")
local Ai = require("./ai")
local Persistence = require("./persistence")

local Debug = {}

local function positiveNumber(v) return type(v) == "number" and v == v and v > 0 and v < math.huge end

local actions = {}

function actions.addCredits(sim, args)
  local amount = args.amount or DebugConfig.creditBoost
  if not positiveNumber(amount) then return false, "bad amount" end
  sim.resources.credits += amount
  sim.debug.creditBoosts += 1
  sim:log("WARN", ("debug: +%d credits"):format(amount))
  return true, sim.resources.credits
end

function actions.addCompute(sim, args)
  local amount = args.amount or DebugConfig.computeBoost
  if not positiveNumber(amount) then return false, "bad amount" end
  sim.resources.compute += amount
  sim:log("WARN", ("debug: +%d Compute"):format(amount))
  return true, sim.resources.compute
end

function actions.setTier(sim, args)
  local tier = args.tier
  if type(tier) ~= "number" or tier ~= math.floor(tier) or tier < 1 or tier > DebugConfig.maxTier then
    return false, "bad tier"
  end
  sim.tier = tier
  for _, agent in pairs(sim.agents) do agent.tier = tier end
  sim:log("WARN", "debug: tier " .. tier)
  return true, tier
end

function actions.revealVeins(sim)
  local n = 0
  for _, v in pairs(sim.veins) do
    if not v.scanned then v.scanned = true; n += 1 end
  end
  sim:log("WARN", ("debug: revealed %d veins"):format(n))
  return true, n
end

-- The market (M6) must expose forceEvent(kind, marketId, ore); until it exists there is nothing to trigger.
function actions.triggerShortage(sim, args)
  if not sim.market then return false, "unavailable: no market yet (M6)" end
  return sim.market:forceEvent("shortage", args.market, args.ore)
end

-- Same code path as the offline summary will use (M5): AI-mode agents do nothing while away, so the decider is detached.
function actions.simulateAway(sim, args)
  local hours = args.hours or DebugConfig.awayHours
  if not positiveNumber(hours) or hours > DebugConfig.maxAwayHours then return false, "bad hours" end
  local before, decide = sim.resources.credits, sim.decide
  sim.decide = nil
  sim:run(math.floor(hours * 3600 / sim.b.tickSeconds + 0.5))
  sim.decide = decide
  return true, { hours = hours, credits = sim.resources.credits - before }
end

function actions.setProvider(sim, args)
  local ok, e = Ai.use(args.provider)
  if not ok then return false, e end
  return true, Ai.provider()
end

-- The prompt builder (M2) will store the assembled text in lastDecision.prompt; until then the context the AI saw.
function actions.lastPrompt(sim)
  local d = sim.lastDecision
  if not d then return false, "no decision yet" end
  return true, { agent = d.agent, tick = d.tick, text = d.prompt or Json.encode(d.ctx), call = d.call }
end

-- ctx = { storage, path, savedAt }. Returns the fresh sim; the caller must swap it in and re-attach the decider.
function actions.resetSave(sim, args, ctx)
  if not (ctx and ctx.storage and ctx.path) then return false, "no storage" end
  local fresh, e = Persistence.reset(ctx.storage, ctx.path, ctx.savedAt)
  if not fresh then return false, e.message end
  return true, fresh
end

Debug.actions = actions

function Debug.run(sim, action, args, ctx)
  if not DebugConfig.enabled then return false, "debug disabled" end
  local fn = actions[action]
  if not fn then return false, "unknown debug action: " .. tostring(action) end
  return fn(sim, args or {}, ctx)
end

-- Spec §17 jury demo: at most demoMaxCreditBoosts credit boosts.
function Debug.withinDemoBudget(sim) return sim.debug.creditBoosts <= DebugConfig.demoMaxCreditBoosts end

return Debug
