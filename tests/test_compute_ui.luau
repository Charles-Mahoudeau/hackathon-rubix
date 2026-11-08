-- Run from repo root: luau tests/test_compute_ui.luau
-- GR5-6 screens: the top-bar Compute gauge and buy button, per-agent Compute/h, the budget-reached state and the Context
-- panel, drawn from ui/compute_view.luau view-models. Headless: only Shell.spec (a pure description), no engine calls.
local Ai = require("@scripts/config/ai")
local Screens = require("@scripts/config/screens")
local Sim = require("@scripts/sim/sim")
local AiStub = require("@scripts/sim/ai")
local Prompt = require("@scripts/sim/prompt")
local Shell = require("@scripts/ui/shell")
local View = require("@scripts/ui/compute_view")

local function walk(node, fn)
  fn(node)
  for _, child in ipairs(node.children or {}) do walk(child, fn) end
end
local function texts(spec)
  local out = {}
  walk(spec, function(n) if n.text then out[#out + 1] = n.text.text end end)
  return out
end
local function buttons(spec)
  local out = {}
  walk(spec, function(n) if n.button then out[n.button.action] = n end end)
  return out
end
local function hasText(spec, needle)
  for _, t in ipairs(texts(spec)) do if t:find(needle, 1, true) then return true end end
  return false
end
local function labelOf(node) return node.children[1].text.text end

-- top bar: Compute with its credit equivalent, and a buy button, at any Compute level
local sim = Sim.new()
local map = Shell.spec(sim, "map", {})
assert(hasText(map, "Compute  10.0 (400 cr)"), "Compute gauge shows the credit equivalent (x40)")
local buy = buttons(map)["compute.buy.1"]
assert(buy and labelOf(buy) == "Buy 5 Compute (200 cr)", "buy button in the top bar")
sim.resources.compute = 0
sim.resources.credits = 0
local broke = Shell.spec(sim, "map", {})
assert(buttons(broke)["compute.buy.1"], "buy button stays when empty and broke")
assert(hasText(broke, "EMPTY"), "empty Compute is flagged")
sim.resources.compute = 100000
assert(buttons(Shell.spec(sim, "map", {}))["compute.buy.1"], "buy button stays with a huge Compute balance (no cap)")

-- the button greys (dim border) when unaffordable and lights up when affordable
local function borderOf(spec) return buttons(spec)["compute.buy.1"].background.borderColor end
sim.resources.credits = 200
local lit = borderOf(Shell.spec(sim, "map", {}))
sim.resources.credits = 199
local grey = borderOf(Shell.spec(sim, "map", {}))
assert(lit[3] > grey[3] or lit[1] ~= grey[1], "affordable and unaffordable look different")

-- clicks: buying works through the same path the client uses
local c = Sim.new()
c.resources.credits = 450
local handled, ok = View.act(c, "miner", "compute.buy.1")
assert(handled and ok and c.resources.compute == 15 and c.resources.credits == 250)
handled, ok = View.act(c, "miner", "compute.buy.2")
assert(handled and not ok and c.resources.compute == 15, "cannot afford 2 packs: nothing changes")
assert(not View.act(c, "miner", "nav.map") and not View.act(c, "miner", nil), "other actions are not ours")

-- Agents screen, Editor tab: per-agent Compute/h, team total, budget, buy packs
local a = Sim.new()
a:setDecider(AiStub.decide)
a:run(600)
local agents = Shell.spec(a, "agents", { tab = "editor" })
local rows = View.agentRows(a)
assert(rows[1].computePerHour > 0)
assert(hasText(agents, ("miner      %6.1f /h"):format(rows[1].computePerHour)), "per-agent Compute/h is drawn and live")
assert(hasText(agents, "team"), "team total drawn")
assert(hasText(agents, "AI budget this hour:"), "budget line drawn")
for packs = 1, Screens.compute.packs do assert(buttons(agents)["compute.buy." .. packs], "pack " .. packs) end
local before = hasText(Shell.spec(a, "agents", {}), ("miner      %6.1f /h"):format(rows[1].computePerHour))
a:run(400)
local after = View.agentRows(a)[1].computePerHour
assert(before and (after ~= rows[1].computePerHour or a.compute.lifetimeTotal > 0))
assert(hasText(Shell.spec(a, "agents", {}), ("miner      %6.1f /h"):format(after)), "the readout follows the ledger")
assert(buttons(agents)["editor.tab.context"] and buttons(agents)["editor.tab.editor"], "tab buttons")

-- budget reached: said clearly in the top bar, on the agent row and in the budget line; buying still works
local realNow = 0
local b = Sim.new({ aiConfig = { tokensPerHour = 3000 }, aiClock = function() return realNow end })
b:setDecider(AiStub.decide)
b.resources.compute = 1000
b:run(8000)
assert(b.agents.miner.state == "no_compute")
local mapB, agentsB = Shell.spec(b, "map", {}), Shell.spec(b, "agents", { tab = "editor" })
assert(hasText(mapB, "Server AI budget reached"), "top bar says the budget is reached")
assert(hasText(agentsB, "no compute: Server AI budget reached"), "agent row says why it stopped")
assert(hasText(agentsB, "Server AI budget reached"), "budget line says it too")
assert(buttons(mapB)["compute.buy.1"] and buttons(agentsB)["compute.buy.3"], "buy still offered")
assert(not hasText(Shell.spec(Sim.new(), "map", {}), "Server AI budget reached"), "no message while under budget")

-- Context tab: one row per setting, each option's weight is what it adds to the prompt, total == billed estimate
local w = Sim.new()
w.ships.s1.engineMark = 2
local ctx = Shell.spec(w, "agents", { tab = "context" })
local panel = View.contextPanel(w, "miner")
for _, row in ipairs(panel.rows) do assert(hasText(ctx, row.label), "row " .. row.key) end
assert(#panel.rows == 10)
assert(hasText(ctx, panel.cost.text), "total cost drawn")
local base = Prompt.build(w, "miner").input
assert(hasText(ctx, ("%d input + %d output = %d tokens"):format(panel.inputTokens, panel.outputTokens, panel.totalTokens)))
assert(panel.inputTokens == base)
local acts = buttons(ctx)
assert(acts["context.prices_hmc.3"] and acts["context.format.2"] and acts["context.recent_results.step.1"] and acts["context.recent_results.step.-1"])
local hmcAll
for _, o in ipairs(panel.rows[1].options) do if o.value == "all" then hmcAll = o end end
assert(labelOf(acts["context.prices_hmc.3"]) == ("all (+%d)"):format(hmcAll.weight), "option label shows its token weight")
local locked = {}
for _, row in ipairs(panel.rows) do if not row.available then locked[#locked + 1] = row end end
assert(#locked >= 3 and hasText(ctx, "Locked: unlocks at T3") and not acts["context.prices_orbis.2"], "locked rows have no buttons")

-- clicking an option changes the next prompt by exactly the weight the button showed
local delta = hmcAll.weight - panel.rows[1].weight
local h, okSet = View.act(w, "miner", "context.prices_hmc.3")
assert(h and okSet and w.agents.miner.contextSettings.prices_hmc == "all")
assert(Prompt.build(w, "miner").input - base == delta, "weight on the button == real prompt delta")
assert(View.contextPanel(w, "miner").totalTokens == Prompt.build(w, "miner").input + Ai.estimatedOutputTokens)
-- the redrawn screen marks the new choice
local marked
for _, o in ipairs(View.contextPanel(w, "miner").rows[1].options) do if o.selected then marked = o.value end end
assert(marked == "all")
-- stepper clamps at both ends
for _ = 1, 20 do View.act(w, "miner", "context.recent_results.step.1") end
assert(w.agents.miner.contextSettings.recent_results == Ai.recentMax)
for _ = 1, 20 do View.act(w, "miner", "context.recent_results.step.-1") end
assert(w.agents.miner.contextSettings.recent_results == 0)
-- locked and unknown settings are refused, never applied
local _, okLocked, why = View.act(w, "miner", "context.prices_orbis.2")
assert(not okLocked and why == "locked" and w.agents.miner.contextSettings.prices_orbis == true)
local _, okBad = View.act(w, "miner", "context.nope.1")
assert(not okBad)
local _, okIdx = View.act(w, "miner", "context.format.9")
assert(not okIdx)
w.tier = 3
w.upgrades.tradingPost = true
assert(buttons(Shell.spec(w, "agents", { tab = "context" }))["context.prices_orbis.2"], "unlocked toggles get buttons")

-- the Context tab fits the panel: the last row ends inside the main panel
local last = Screens.context.rowY + #panel.rows * Screens.context.rowHeight
assert(last <= Shell.layout().main.h, "context rows fit the main panel")
assert(Screens.compute.y + 8 * Screens.compute.rowHeight + 40 <= Shell.layout().main.h, "compute block fits under the editor")
print("OK")
