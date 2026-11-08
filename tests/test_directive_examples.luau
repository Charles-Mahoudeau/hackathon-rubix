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

-- 1. the data: unique ids, valid grades and roles, real tools, directives within the limit, short hints
do
  local s = sim()
  local seen = {}
  local limit = s.compute.cfg.editor.directiveMaxTokens
  for _, ex in ipairs(Cfg.examples) do
    assert(not seen[ex.id], "duplicate id " .. ex.id)
    seen[ex.id] = true
    assert(Cfg.grades[ex.grade], ex.id .. ": grade")
    assert(s.registry.agentTypes[ex.role], ex.id .. ": role " .. ex.role)
    assert(Compute.estimateTokens(s.compute.cfg, ex.directive) <= limit, ex.id .. ": directive over the limit")
    assert(utf8.len(ex.hint) <= Cfg.hintMax, ex.id .. ": hint over " .. Cfg.hintMax .. " chars")
    assert(ex.stub == "ok" or ex.stub == "partial", ex.id .. ": stub flag")
    for _, need in ipairs(ex.needs) do
      if need.kind == "tool" then assert(s.registry.schemas[need.name], ex.id .. ": unknown tool " .. need.name) end
    end
  end
  for _, role in ipairs({ "miner", "logistician", "monitor", "refiner", "scavenger", "privateer" }) do
    local grades = {}
    for _, ex in ipairs(Cfg.examples) do if ex.role == role then grades[ex.grade] = true end end
    assert(grades.bad and grades.ok and grades.good, role .. " has BAD, OK and GOOD")
  end
end

-- 2. filtering: role, mission start, locked branches
do
  local s = sim()
  local m = ids(Editor.examples(s, "miner"))
  assert(m.miner_bad and m.miner_ok and m.miner_good and m.miner_m1_ok, "mission 1 miner examples at game start")
  assert(not m.miner_m2_good and not m.miner_m5_good, "later missions stay hidden")
  for _, ex in pairs(m) do assert(ex.gradeLabel == Cfg.grades[ex.grade]) end
  s.missions[2].status = "active"
  assert(ids(Editor.examples(s, "miner")).miner_m2_good, "mission 2 examples appear once it starts")
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
  local saved = Cfg.examples[1].directive
  Cfg.examples[1].directive = string.rep("a", 1700)
  local draft = Editor.newDraft(s, "miner")
  local ex = ids(Editor.examples(s, "miner"))[Cfg.examples[1].id]
  assert(not ex.fits)
  local ok, why = Editor.applyExample(s, "miner", draft, Cfg.examples[1].id)
  assert(not ok and why == "too_long" and draft.directive == s.agents.miner.directive)
  Cfg.examples[1].directive = saved
end

-- 5. prerequisites are reported, never granted; the stub note follows the provider
do
  local s = sim()
  s.missions[5].status = "active"
  local good = ids(Editor.examples(s, "miner")).miner_m5_good
  assert(not good.ready, "Orbis prices / trading post are missing at game start")
  local missing = 0
  for _, p in ipairs(good.prerequisites) do if not p.met then missing += 1 end end
  assert(missing >= 1)
  local draft = Editor.newDraft(s, "miner")
  assert(Editor.applyExample(s, "miner", draft, "miner_m5_good"))
  assert(not ids(Editor.examples(s, "miner")).miner_m5_good.ready, "applying did not grant a prerequisite")
  assert(s.upgrades.tradingPost ~= true)

  local partial
  for _, ex in ipairs(Cfg.examples) do if ex.stub ~= "ok" and ex.role == "miner" then partial = ex end end
  if partial then
    for i = 1, 8 do s.missions[i].status = "active" end
    assert(ids(Editor.examples(s, "miner"))[partial.id].stubNote == Cfg.stubNote, "stub limits are stated")
    s.provider = {}
    assert(ids(Editor.examples(s, "miner"))[partial.id].stubNote == nil, "no stub note with a real provider")
    s.provider = nil
  end
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

  s.missions[5].status = "active"
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
    for i = 1, 8 do t.missions[i].status = "active" end
    local sp = Shell.spec(t, "agents", { examples = { open = true, selected = "miner_good" }, draft = { directive = string.rep("word ", 300), order = "" } })
    assert(#Fit.check(sp, view) == 0, "T" .. tier .. ": " .. table.concat(Fit.check(sp, view), "\n"))
  end
end
print("test_directive_examples: ok")
