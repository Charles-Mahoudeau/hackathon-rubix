-- Run from repo root: luau tests/test_agents_layout.luau
-- GR5-67 gate: the Agents, Context and Archive layouts show real values, selected / locked / empty states, scrollable long text,
-- and stay inside the main panel at every tier. Headless: specs only.
local Theme = require("@scripts/config/theme")
local Screens = require("@scripts/config/screens")
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Skills = require("@scripts/sim/skills")
local Shell = require("@scripts/ui/shell")
local Fit = require("@scripts/ui/fit")
local Editor = require("@scripts/ui/agent_editor")
local ComputeView = require("@scripts/ui/compute_view")
local ArchiveView = require("@scripts/ui/archive_view")
local Studio = require("@scripts/ui/skill_studio")

local view = Theme.layout.view
local function walk(spec, fn) fn(spec) for _, c in ipairs(spec.children or {}) do walk(c, fn) end end
local function texts(spec) local out = {} walk(spec, function(n) if n.text then out[#out + 1] = n.text.text end end) return out end
local function has(spec, needle) for _, t in ipairs(texts(spec)) do if t:find(needle, 1, true) then return true end end return false end
local function actions(spec) local out = {} walk(spec, function(n) if n.button then out[n.button.action] = true end end) return out end
local function scrolls(spec) local n = 0 walk(spec, function(s) if s.scroll then n += 1 end end) return n end

-- 1. Agents, T1: one agent, selected, tools with weights, scroll regions, no clipping
local sim = Sim.new()
sim:setDecider(Ai.decide)
sim:setDirective("miner", "Mine cobalt on K3 until the hold is 100%, then sell at HMC.")
sim:run(1200)
local spec = Shell.spec(sim, "agents", {})
assert(#Fit.check(spec, view) == 0, table.concat(Fit.check(spec, view), "\n"))
assert(has(spec, "AGENTS  1") and has(spec, "> miner"), "list shows the selected agent")
assert(actions(spec)["team.open.miner"] and actions(spec)["editor.tab.context"] and actions(spec)["editor.save"])
assert(has(spec, "Mine cobalt on K3"), "the full directive is in the scrollable preview")
assert(has(spec, "DIRECTIVE (permanent)") and has(spec, "ORDER (one-off, until cleared)") and has(spec, "MODE / COMPUTE") and has(spec, "FEED  miner"))
local m = Editor.model(sim, "miner")
assert(has(spec, ("TOOLS  slots %d / %d"):format(m.toolSlots.used, m.toolSlots.max)), "tool slots are the real ones")
assert(has(spec, m.cost.text) and has(spec, ("%d input + %d output = %d tokens"):format(m.inputTokens, m.outputTokens, m.totalTokens)))
assert(scrolls(spec) >= 5, "directive, order, tools, mode and feed scroll")
assert(has(spec, "AI budget this hour:"))

-- locked tool: the actual requirement
assert(#m.lockedTools >= 1, "T1 Miner owns tools it cannot use yet")
for _, t in ipairs(m.lockedTools) do assert(has(spec, t.name .. "  locked: " .. t.reason), "lock reason for " .. t.name) end

-- feed: calls of this agent, Save as skill reachable
local feed = Editor.feed(sim, "miner")
assert(#feed.entries >= 1 and feed.saveAction == "studio.rec.open.miner")
local st = Studio.new()
local handled, opened = Studio.act(sim, st, feed.saveAction)
assert(handled and opened == "archive" and st.mode == "record" and st.agent == "miner")

-- over the limit: ERROR + reason, save stays disabled
local long = string.rep("word ", 400)
local over = Shell.spec(sim, "agents", { draft = { directive = long, order = "" } })
assert(has(over, "ERROR") and has(over, "over the limit"), "over-limit shows ERROR and the reason")
assert(#Fit.check(over, view) == 0, table.concat(Fit.check(over, view), "\n"))
-- a single word wider than the field is kept whole, broken into lines
local wide = Shell.spec(sim, "agents", { draft = { directive = string.rep("x", 300), order = "" } })
assert(#Fit.check(wide, view) == 0, table.concat(Fit.check(wide, view), "\n"))

-- 2. Agents at T5: several agents, a click opens each, the selected one is marked, the Monitor lock shows
local team = Sim.new()
team.tier = 5
for _, a in pairs(team.agents) do a.tier = team.tier end
team:addAgent("miner_b", "miner"); team:addShip("s2", "miner_b")
team:addAgent("logistician", "logistician", { tier = team.tier })
team:setMonitorLock("miner_b", true)
team:setDecider(Ai.decide)
team:run(600)
assert(#team.agentOrder >= 2, "T5 has a team")
for _, id in ipairs(team.agentOrder) do
  Screens.editor.agent = id
  local s = Shell.spec(team, "agents", {})
  assert(#Fit.check(s, view) == 0, id .. ": " .. table.concat(Fit.check(s, view), "\n"))
  assert(has(s, "> " .. id), id .. " marked selected")
  for _, other in ipairs(team.agentOrder) do assert(actions(s)["team.open." .. other], "row for " .. other) end
end
Screens.editor.agent = "miner"

-- 3. Context: exact rendered text, both format weights, a way to pick the agent, locks with their tier
local pm = ComputeView.contextPanel(sim, "miner")
local ctx = Shell.spec(sim, "agents", { tab = "context" })
assert(#Fit.check(ctx, view) == 0, table.concat(Fit.check(ctx, view), "\n"))
assert(pm.contextText ~= "" and has(ctx, pm.contextText:match("^[^\n ]+")), "preview starts with the real rendered context")
assert(has(ctx, "CONTEXT PREVIEW") and has(ctx, pm.cost.text) and has(ctx, "tokens"))
local fmt
for _, r in ipairs(pm.rows) do if r.key == "format" then fmt = r end end
for _, o in ipairs(fmt.options) do assert(has(ctx, ("%s (+%d)"):format(o.text, o.weight)), "format weight " .. o.text) end
assert(actions(ctx)["pick.agent.miner"] and actions(ctx)["editor.tab.editor"])
for _, r in ipairs(pm.rows) do
  if not r.available then assert(has(ctx, ("Locked: unlocks at T%d"):format(r.unlockTier)), "lock reason " .. r.key) end
end
assert(scrolls(ctx) >= 2, "settings and preview scroll")

-- 4. Archive: empty, then a selected skill with parameters, steps and assignments
local arch = Sim.new()
arch.tier = 5
arch.resources.credits = 100000
local empty = Shell.spec(arch, "archive", {})
assert(#Fit.check(empty, view) == 0 and has(empty, "No skills") and has(empty, "ARCHIVE  Skills 0/"))
arch.upgrades.archive = 3
assert(ArchiveView.saveForm(arch, { name = "ore-run", agent_type = "miner", loop = true, params = { vein = { kind = "vein" } },
  steps = { { tool = "mine", args = { vein = "$vein" } }, { tool = "return" }, { tool = "sell" } } }))
assert(ArchiveView.saveForm(arch, { name = "just-sell", agent_type = "miner", loop = false, params = {}, steps = { { tool = "sell" } } }))
assert(ArchiveView.assign(arch, "miner", "ore-run", { vein = "K1" }))
local studio = Studio.new()
local a1 = Shell.spec(arch, "archive", { studio = studio })
assert(#Fit.check(a1, view) == 0, table.concat(Fit.check(a1, view), "\n"))
assert(has(a1, "just-sell") and has(a1, "ore-run") and has(a1, "Saved"), "both skills listed, detail says Saved")
assert(has(a1, "PARAMETERS / ASSIGNMENTS") and has(a1, "ORDERED STEPS") and has(a1, "zero Compute"))
assert(Studio.act(arch, studio, "studio.select.ore-run") and studio.selected == "ore-run")
local a2 = Shell.spec(arch, "archive", { studio = studio })
assert(has(a2, "$vein  vein") and has(a2, "1. mine vein=$vein") and has(a2, "3. sell") and has(a2, "run by miner vein=K1"), "real parameters, steps, assignment")
assert(has(a2, "Loops:") and actions(a2)["studio.stop.miner"] and actions(a2)["archive.delete.ore-run"])
assert(not Studio.act(arch, studio, "studio.select.nope"), "unknown skill is refused")
for _, mode in ipairs({ "record", "form" }) do
  Studio.act(arch, studio, "studio.mode." .. mode)
  local s = Shell.spec(arch, "archive", { studio = studio })
  assert(#Fit.check(s, view) == 0, mode .. ": " .. table.concat(Fit.check(s, view), "\n"))
end

-- nothing the screens print is cut with "..." at nominal data
for _, sp in ipairs({ spec, ctx, a1, a2, Shell.spec(team, "agents", {}) }) do
  for _, t in ipairs(texts(sp)) do
    if not t:find("^Skill ") then assert(not t:find("%.%.%.$"), "text cut off: " .. t) end
  end
end

-- 5. every tier, every screen of this issue
for tier = 1, 5 do
  local s = Sim.new()
  s.tier = tier
  for _, id in ipairs({ "agents", "archive" }) do
    for _, tab in ipairs({ "editor", "context" }) do
      local spec2 = Shell.spec(s, id, { tab = tab })
      assert(#Fit.check(spec2, view) == 0, ("T%d %s/%s"):format(tier, id, tab))
    end
  end
end
print("test_agents_layout: ok")
