-- Debug panel actions (spec §16.4) and the §17 demo credit-boost budget.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Debug = require("@scripts/sim/debug")
local Persistence = require("@scripts/sim/persistence")
local DebugPanel = require("@scripts/ui/debug")
local DebugConfig = require("@scripts/config/debug")
local Model = require("@scripts/ui/shell_model")
local Shell = require("@scripts/ui/shell")

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

-- Click route (GR5-72): every §16.4 action through the same `debug.*` button actions the client sends to DebugPanel.act.
do
  local function walk(spec, out)
    if spec.button then out[#out + 1] = spec.button.action end
    for _, c in ipairs(spec.children or {}) do walk(c, out) end
    return out
  end
  local sim, ps = Sim.new(), DebugPanel.new()
  local function click(action, ctx) return DebugPanel.act(sim, ps, action, ctx) end

  -- reachable from the nav, and its buttons carry exactly the panel's actions
  local function navHas(id) for _, e in ipairs(Model.nav(1, "map")) do if e.id == id then return true end end return false end
  assert(navHas("debug") and Shell.parseAction("nav.debug", 1) == "debug", "Debug is in the nav while enabled")
  local spec, shown = Shell.spec(sim, "debug", { debug = ps })
  assert(shown == "debug")
  local actions = walk(spec, {})
  local function offered(a) for _, x in ipairs(actions) do if x == a then return true end end return false end
  for _, a in ipairs({ "debug.addCredits", "debug.addCompute", "debug.setStuck", "debug.setTier.3", "debug.revealVeins", "debug.triggerShortage",
    "debug.simulateAway.1", "debug.setProvider.stub", "debug.setProvider.axis", "debug.lastPrompt", "debug.resetSave" }) do
    assert(offered(a), "panel button missing: " .. a)
  end
  for _, a in ipairs(actions) do
    if a:match("^debug%.") then assert(DebugPanel.parseAction(a), "button action does not parse: " .. a) end
  end

  assert(not click("nav.map") and not click("debug.nuke"), "foreign actions are not handled")
  assert(click("debug.addCredits") and sim.resources.credits == 1500 and sim.debug.creditBoosts == 1 and ps.toast:find("1500"))
  assert(click("debug.addCompute") and sim.resources.compute == 30)
  assert(click("debug.setTier.4") and sim.tier == 4 and sim.agents.miner.tier == 4)
  assert(click("debug.setTier.9") and sim.tier == 4 and ps.toast == "bad tier", "bad tier refused, said so")
  assert(click("debug.revealVeins") and ps.toast == "Revealed 12 veins")
  assert(click("debug.triggerShortage") and sim.market.markets.orbis.res.cobalt.kind == "shortage")

  -- provider: stub works, axis is unavailable here (no host registered it) and says so
  assert(click("debug.setProvider.stub") and Ai.provider() == "stub")
  assert(click("debug.setProvider.axis") and ps.toast:find("provider_unavailable") and Ai.provider() == "stub")

  -- away: 1 h, the report lands on the sim for the Archive box
  local before = sim.tick
  assert(click("debug.simulateAway.1") and sim.tick == before + 36000 and ps.toast:find("1 h away"))
  assert(click("debug.simulateAway.9") and ps.toast == "bad hours")

  -- last prompt: refused before any decision, then shown
  assert(click("debug.lastPrompt") and ps.toast == "no decision yet" and ps.prompt == nil)
  local fresh = Sim.new(); fresh:setDecider(Ai.decide); fresh:run(10)
  assert(DebugPanel.act(fresh, ps, "debug.lastPrompt") and ps.prompt and ps.prompt:find("%[CONTEXT%]"), "the raw prompt, not the context table")
  local m = DebugPanel.model(fresh, ps)
  assert(m.promptTitle and #m.promptLines > 0)
  ps.prompt = string.rep("long prompt\n", 100)
  assert(#DebugPanel.model(fresh, ps).promptLines >= 100, "long prompts remain available to scroll")

  -- reset save: needs a second click; swaps in a fresh game
  local st = Persistence.memoryStorage()
  local ctx = { storage = st, path = "s", savedAt = 1 }
  sim.resources.credits = 77777
  local handled, swapped = click("debug.resetSave", ctx)
  assert(handled and swapped == nil and sim.resources.credits == 77777 and ps.confirmReset, "first click only arms")
  handled, swapped = click("debug.resetSave", ctx)
  assert(handled and swapped and swapped.resources.credits == 500 and not ps.confirmReset and ps.prompt == nil)

  -- the model's own signature follows what it shows
  local sig = DebugPanel.signature(sim, ps)
  click("debug.addCompute")
  assert(DebugPanel.signature(sim, ps) ~= sig)

  -- disabled build: no nav entry, screen falls back to the map, every click refused
  DebugConfig.enabled = false
  assert(not navHas("debug") and Shell.parseAction("nav.debug", 5) == nil)
  local _, fallback = Shell.spec(sim, "debug", { debug = ps })
  assert(fallback == "map", "the Debug screen is not reachable when disabled")
  local credits = sim.resources.credits
  assert(click("debug.addCredits") and sim.resources.credits == credits and ps.toast == "debug disabled")
  DebugConfig.enabled = true
end

print("debug OK")
