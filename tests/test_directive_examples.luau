-- Run from repo root: luau tests/test_directive_examples.luau
-- GR5-106: directive examples dropdown. Data limits, filtering by role / mission / branch, applying only the draft text,
-- prerequisites reported and never granted, stub note, and the open panel fits the screen.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Compute = require("@scripts/sim/compute")
local Editor = require("@scripts/ui/agent_editor")
local Shell = require("@scripts/ui/shell")
local Fit = require("@scripts/ui/fit")
local Theme = require("@scripts/config/theme")
local Screens = require("@scripts/config/screens")
local Cfg = require("@scripts/config/directive_examples")
local Library = require("@scripts/sim/prompt_library")
local Data = require("@scripts/config/prompt_library")

local view = Theme.layout.view
local function walk(spec, fn) fn(spec) for _, c in ipairs(spec.children or {}) do walk(c, fn) end end
local function texts(spec) local out = {} walk(spec, function(n) if n.text then out[#out + 1] = n.text.text end end) return out end
local function has(spec, needle) for _, t in ipairs(texts(spec)) do if t:find(needle, 1, true) then return true end end return false end
local function actions(spec) local out = {} walk(spec, function(n) if n.button then out[n.button.action] = true end end) return out end
local function ids(list) local out = {} for _, ex in ipairs(list) do out[ex.id] = ex end return out end
local function sim() local s = Sim.new() s:setDecider(Ai.decide) return s end
-- A T4 company that has really opened the refining branch (as tests/test_refining.luau does).
local function refinery()
  local s = Sim.new()
  s:enterTier(3)
  s.lifetimeRevenue = 60000
  s.resources.credits = 500000
  s.resources.compute = 500
  assert(s:buyUpgrade("warehouse") and s:buyUpgrade("trading_post"))
  s:enterTier(4)
  assert(s:openBranch("refining"))
  return s
end

-- 1. the editor reads the prompt library (data limits are covered by tests/test_prompt_library.luau)
do
  local s = sim()
  assert(#Library.validate(s) == 0, "the library the editor reads is valid")
  local limit = s.compute.cfg.editor.directiveMaxTokens
  for _, ex in ipairs(Editor.examples(s, "miner")) do
    assert(Compute.estimateTokens(s.compute.cfg, ex.directive) <= limit and ex.fits, ex.id .. ": directive within the limit")
    assert(utf8.len(ex.hint) <= Data.hintMaxChars, ex.id .. ": hint length")
  end
end

-- 2. filtering: role, active mission, locked branches
do
  local s = sim()
  local m = ids(Editor.examples(s, "miner"))
  assert(m.miner_bad and m.miner_ok and m.miner_good and m.miner_m1_ok, "mission 1 miner examples at game start")
  assert(not m.miner_m2_good and not m.miner_m5_good, "later missions stay hidden")
  for _, ex in pairs(m) do assert(ex.gradeLabel == Cfg.grades[ex.grade]) end
  s.missions[1].status = "complete"
  s.missions[2].status = "active"
  assert(ids(Editor.examples(s, "miner")).miner_m2_good, "mission 2 examples appear once it is active")
  for _, ex in ipairs(Editor.examples(s, "miner")) do assert(ex.id:find("^miner"), "only the miner's examples") end

  -- a branch role whose branch is closed gets nothing; once opened it lists its own role only
  assert(s.agents.refiner == nil and #Editor.examples(s, "refiner") == 0 and #Editor.examples(s, "scavenger") == 0)
  local r = Editor.examples(refinery(), "refiner")
  assert(#r >= 3)
  for _, ex in ipairs(r) do assert(ex.id:find("^refiner")) end
  local g = refinery()
  g.branchesOpen.refining = false
  assert(#Editor.examples(g, "refiner") == 0, "a locked branch shows no examples")
end

-- 3. applying changes only the draft directive
do
  local s = sim()
  local before = { order = s.agents.miner.order, directive = s.agents.miner.directive, tools = table.concat(s:equippedTools("miner"), ","),
    settings = s.agents.miner.contextSettings.prices_orbis, skills = next(s.skills) }
  local draft = Editor.newDraft(s, "miner")
  draft.order = "go home"
  local ok = Editor.applyExample(s, "miner", draft, "miner_good")
  assert(ok and draft.directive ~= "" and draft.directive ~= before.directive, "directive filled")
  assert(draft.order == "go home", "order untouched")
  assert(s.agents.miner.directive == before.directive and s.agents.miner.order == before.order, "nothing saved")
  assert(table.concat(s:equippedTools("miner"), ",") == before.tools and s.agents.miner.contextSettings.prices_orbis == before.settings and next(s.skills) == before.skills)

  assert(select(2, Editor.applyExample(s, "miner", draft, "nope")) == "unknown_example")
  assert(select(2, Editor.applyExample(s, "miner", draft, "miner_m5_good")) == "unknown_example", "hidden example cannot be applied by id")

  -- replacing different unsaved text needs a confirmation; saved or identical text does not
  draft.directive = "my own unsaved words"
  local ok2, why = Editor.applyExample(s, "miner", draft, "miner_ok")
  assert(not ok2 and why == "confirm_replace" and draft.directive == "my own unsaved words")
  assert(Editor.applyExample(s, "miner", draft, "miner_ok", true) and draft.directive ~= "my own unsaved words")
  draft.directive = s.agents.miner.directive
  assert(Editor.applyExample(s, "miner", draft, "miner_bad"), "saved text is replaced without a prompt")
end

-- 4. directive limit is respected
do
  local s = sim()
  s.aiConfig.editor.directiveMaxTokens = 5
  s.compute.cfg.editor.directiveMaxTokens = 5
  local draft = Editor.newDraft(s, "miner")
  local ex = ids(Editor.examples(s, "miner")).miner_good
  assert(not ex.fits)
  local ok, why = Editor.applyExample(s, "miner", draft, "miner_good")
  assert(not ok and why == "too_long" and draft.directive == s.agents.miner.directive)
end

-- 5. prerequisites are reported, never granted; the stub note follows the provider
do
  local s = sim()
  s.missions[1].status = "complete"
  s.missions[3].status = "active"
  local good = ids(Editor.examples(s, "miner")).miner_m3_good
  assert(not good.ready, "the saved skill is missing at game start")
  local sawSkill = false
  for _, p in ipairs(good.prerequisites) do if p.text:find("skill K1Loop", 1, true) and not p.met then sawSkill = true end end
  assert(sawSkill, "the missing skill is listed")
  local draft = Editor.newDraft(s, "miner")
  assert(Editor.applyExample(s, "miner", draft, "miner_m3_good"))
  assert(next(s.skills) == nil and not ids(Editor.examples(s, "miner")).miner_m3_good.ready, "applying did not grant the skill")

  s.missions[3].status = "complete"
  s.missions[2].status = "active"
  local scan = ids(Editor.examples(s, "miner")).miner_m2_good
  assert(scan and not scan.ready, "an example needing the scanner is listed with its blocker, not hidden")
  local unmet = false
  for _, p in ipairs(scan.prerequisites) do if not p.met and p.text:find("scanner", 1, true) then unmet = true end end
  assert(unmet, "the scanner upgrade is named as missing")
  s.missions[2].status = "complete"
  s.missions[5].status = "active"
  local setup = ids(Editor.examples(s, "miner")).miner_m5_good
  local noted = false
  for _, p in ipairs(setup.prerequisites) do if p.info and p.text:find("trading post", 1, true) then noted = true end end
  assert(noted, "the mission setup (warehouse, trading post) is listed to check")

  local l = refinery()
  local ship = ids(Editor.examples(l, "refiner"))
  local partial
  for _, ex in pairs(ship) do if ex.stubNote then partial = ex end end
  assert(partial and partial.stubNote:find("does not read", 1, true), "stub limits are stated")
  l.provider = {}
  for _, ex in pairs(Editor.examples(l, "refiner")) do assert(ex.stubNote == nil, "no stub note with a real provider") end
end

-- 6. the shell: button, open panel, empty state, tiers, long text, narrow content
do
  local s = sim()
  Screens.editor.agent = "miner"
  local closed = Shell.spec(s, "agents", {})
  assert(has(closed, "Examples (") and actions(closed)["editor.examples.toggle"])
  assert(#Fit.check(closed, view) == 0, table.concat(Fit.check(closed, view), "\n"))

  local list = Editor.examples(s, "miner")
  local opened = Shell.spec(s, "agents", { examples = { open = true } })
  assert(#Fit.check(opened, view) == 0, table.concat(Fit.check(opened, view), "\n"))
  assert(has(opened, "EXAMPLES") and has(opened, "Pick an example"), "preview prompt before selecting")
  for _, ex in ipairs(list) do assert(actions(opened)["editor.example.pick." .. ex.id]) end

  s.missions[1].status = "complete"
  s.missions[3].status = "active"
  for _, ex in ipairs(Editor.examples(s, "miner")) do
    local sp = Shell.spec(s, "agents", { examples = { open = true, selected = ex.id } })
    assert(#Fit.check(sp, view) == 0, ex.id .. ": " .. table.concat(Fit.check(sp, view), "\n"))
    assert(has(sp, ex.directive:sub(1, 20)), ex.id .. ": directive shown")
    assert(actions(sp)["editor.example.use." .. ex.id])
    assert(has(sp, "PREREQUISITES") and has(sp, Cfg.noMeasure:sub(1, 20)))
    for _, t in ipairs(texts(sp)) do assert(not t:find("%.%.%.$"), "text cut off: " .. t) end
  end
  local conf = Shell.spec(s, "agents", { examples = { open = true, selected = "miner_good", confirm = "miner_good" } })
  assert(has(conf, "Replace unsaved text?"))

  -- an agent without examples says so
  local rf = refinery()
  Screens.editor.agent = "refiner"
  local rs = Shell.spec(rf, "agents", { examples = { open = true } })
  assert(#Fit.check(rs, view) == 0, table.concat(Fit.check(rs, view), "\n"))
  assert(has(rs, "Refiner") or has(rs, "refiner"))
  rf.branchesOpen.refining = false
  local none = Shell.spec(rf, "agents", { examples = { open = true } })
  assert(has(none, Cfg.noExamples) and #Fit.check(none, view) == 0, "empty state")
  Screens.editor.agent = "miner"

  for tier = 1, 5 do
    local t = sim()
    t.tier = tier
    t.missions[1].status = "complete"
    t.missions[3].status = "active"
    local sp = Shell.spec(t, "agents", { examples = { open = true, selected = "miner_good" }, draft = { directive = string.rep("word ", 300), order = "" } })
    assert(#Fit.check(sp, view) == 0, "T" .. tier .. ": " .. table.concat(Fit.check(sp, view), "\n"))
  end
end
print("test_directive_examples: ok")
