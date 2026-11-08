-- Debug panel actions (spec §16.4) and the §17 demo credit-boost budget.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Debug = require("@scripts/sim/debug")
local Persistence = require("@scripts/sim/persistence")
local DebugPanel = require("@scripts/ui/debug")

local s = Sim.new()
assert(select(2, Debug.run(s, "addCredits", { amount = 250 })) == 750)
assert(Debug.run(s, "addCredits"), "default boost")
assert(s.resources.credits == 1750 and s.debug.creditBoosts == 2)
assert(not Debug.withinDemoBudget(s), "two boosts exceed the demo budget")
assert(Debug.withinDemoBudget(Sim.new()))
assert(not Debug.run(s, "addCredits", { amount = -5 }) and not Debug.run(s, "addCredits", { amount = 0 / 0 }))
assert(select(2, Debug.run(s, "addCompute", { amount = 5 })) == 15)

-- tier
assert(not Debug.run(s, "setTier", { tier = 0 }) and not Debug.run(s, "setTier", { tier = 6 }) and not Debug.run(s, "setTier", { tier = 2.5 }))
assert(Debug.run(s, "setTier", { tier = 2 }) and s.tier == 2 and s.agents.miner.tier == 2)

-- veins: hidden K4 becomes minable once revealed
assert(not s:validate("miner", { name = "mine", args = { vein = "K4" } }))
local ok, n = Debug.run(s, "revealVeins")
assert(ok and n == 12)
assert(s:validate("miner", { name = "mine", args = { vein = "K4" } }))

-- shortage is forwarded to the market
assert(not Debug.run(s, "triggerShortage", { market = "nowhere" }))
assert(Debug.run(s, "triggerShortage", { market = "orbis", ore = "cobalt" }))
assert(s.market.markets.orbis.res.cobalt.kind == "shortage", "the market started the shortage")

-- simulate away: 1 h of game time, AI agents idle, decider restored, cap enforced
local away = Sim.new()
away:setDecider(Ai.decide)
local decider = away.decide
assert(Debug.run(away, "simulateAway", { hours = 1 }))
assert(away.tick == 36000 and away.decide == decider and away.lastDecision == nil, "no AI decisions while away")
assert(not Debug.run(away, "simulateAway", { hours = 9 }) and not Debug.run(away, "simulateAway", { hours = 0 }))

-- provider switch: rubix unavailable until registered, then switchable and used by Ai.decide
assert(Ai.provider() == "stub")
local pok, perr = Debug.run(s, "setProvider", { provider = "rubix" })
assert(not pok and perr:find("provider_unavailable") and Ai.provider() == "stub")
Ai.register("rubix", function() return { name = "report", args = { message = "real" } } end)
assert(Debug.run(s, "setProvider", { provider = "rubix" }) and Ai.decide(s, "miner", {}).args.message == "real")
assert(Debug.run(s, "setProvider", { provider = "stub" }) and Ai.provider() == "stub")

-- last prompt
local d = Sim.new()
assert(not Debug.run(d, "lastPrompt"))
d:setDecider(Ai.decide)
d:run(10)
local lok, last = Debug.run(d, "lastPrompt")
assert(lok and last.agent == "miner" and #last.text > 0 and last.call.name)
d.lastDecision.prompt = "PROMPT TEXT"
assert(select(2, Debug.run(d, "lastPrompt")).text == "PROMPT TEXT")

-- reset save
local st = Persistence.memoryStorage()
local used = Sim.new(); used.resources.credits = 99999
Persistence.save(used, st, "s", 0)
assert(not Debug.run(used, "resetSave", {}))
local rok, fresh = Debug.run(used, "resetSave", {}, { storage = st, path = "s", savedAt = 1 })
assert(rok and fresh.resources.credits == 500 and Persistence.load(st, "s").resources.credits == 500)

-- unknown action
assert(not Debug.run(s, "nuke"))

-- panel: every entry maps to a real debug action and back
for _, e in ipairs(DebugPanel.entries) do
  assert(Debug.actions[e.name], "panel entry without action: " .. e.name)
  assert(DebugPanel.parseAction(DebugPanel.actionOf(e)) == e.name)
end
assert(DebugPanel.parseAction("menu.play") == nil and DebugPanel.parseAction("debug.nuke") == nil)
for name in pairs(Debug.actions) do
  local found = false
  for _, e in ipairs(DebugPanel.entries) do if e.name == name then found = true end end
  assert(found, "action missing from the panel: " .. name)
end
print("debug OK")
