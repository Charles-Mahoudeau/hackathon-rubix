-- Run from repo root: luau tests/test_editor.luau
-- GR5-5: agent editor. Limits, live counters, cost per decision, save/clear, prompt reach, screen spec.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Editor = require("@scripts/ui/agent_editor")
local Prompt = require("@scripts/sim/prompt")
local Shell = require("@scripts/ui/shell")
local AiConfig = require("@scripts/config/ai")

local function sim() local s = Sim.new() s:setDecider(Ai.decide) return s end
local function words(chars) return string.rep("a", chars) end

-- 1. limits: 400 tokens = 1600 chars for the directive, 100 tokens = 400 chars for the order
do
  local s = sim()
  assert(s:setDirective("miner", words(1600)), "400 tokens fit")
  local ok, err = s:setDirective("miner", words(1601))
  assert(not ok and err == "too_long", "401 tokens refused")
  assert(#s.agents.miner.directive == 1600, "refused text changes nothing")
  assert(s:setOrder("miner", words(400)), "100 tokens fit")
  ok, err = s:setOrder("miner", words(401))
  assert(not ok and err == "too_long", "101 tokens refused")
end

-- 2. counters: ok -> warn (amber, near the limit) -> over (amber, cannot save)
do
  local s = sim()
  local d = { directive = "", order = "" }
  local m = Editor.model(s, "miner", d)
  assert(m.directive.state == "ok" and not m.directive.amber and m.directive.text == "0 / 400")
  d.directive = words(1500)
  m = Editor.model(s, "miner", d)
  assert(m.directive.state == "warn" and m.directive.amber and m.canSave, "near the limit is amber but saves")
  d.directive = words(1604)
  m = Editor.model(s, "miner", d)
  assert(m.directive.state == "over" and m.directive.amber and not m.canSave, "over the limit is blocked")
  assert(m.directive.tokens == 401)
  local ok, err = Editor.save(s, "miner", d)
  assert(not ok and err == "too_long" and s.agents.miner.directive == "", "over-limit save does nothing")
  d.directive, d.order = "", words(404)
  m = Editor.model(s, "miner", d)
  assert(m.order.state == "over" and m.order.max == 100 and not m.canSave)
end

-- 3. the editor's numbers are the real prompt's: sections add up, cost = (input + output) / 1000 rounded up
do
  local s = sim()
  local d = { directive = "Mine cobalt on K3 until the hold is 100%, then sell at HMC.", order = "go home" }
  local m = Editor.model(s, "miner", d)
  local sum = 0
  for _, name in ipairs({ "rules", "directive", "order", "context", "tools" }) do assert(m.sections[name] ~= nil, name) sum += m.sections[name] end
  assert(sum == m.inputTokens, "sections sum to the input")
  assert(m.totalTokens == m.inputTokens + AiConfig.estimatedOutputTokens)
  assert(m.cost.compute == math.ceil(m.totalTokens / 1000 * 10 - 1e-9) / 10, "§6.4 formula")
  assert(m.cost.credits == m.cost.compute * 40, "credits = Compute x 40")
  s:setDirective("miner", d.directive) s:setOrder("miner", d.order)
  local built = Prompt.build(s, "miner")
  assert(built.input == m.inputTokens, "saved prompt weighs what the draft predicted")
  assert(#m.formats == 2 and m.formats[1].format == "compact" and m.formats[2].format == "json")
  assert(m.formats[2].context > m.formats[1].context, "json context weighs more than compact")
  assert(#m.tools >= 5 and m.tools[1].tokens > 0, "each equipped tool has a weight")
  assert(m.skills.slots == 1, "1 skill slot at T1")
end

-- 4. a long directive costs more Compute per decision than a short one
do
  local s = sim()
  local short = Editor.model(s, "miner", { directive = "mine", order = "" })
  local long = Editor.model(s, "miner", { directive = words(1600), order = "" })
  assert(long.totalTokens - short.totalTokens > 390, "400 tokens more")
  assert(long.cost.compute > short.cost.compute, "long costs more Compute")
  assert(long.cost.credits > short.cost.credits)
end

-- 5. save reaches the prompt; the order persists until cleared
do
  local s = sim()
  local d = Editor.newDraft(s, "miner")
  d.directive, d.order = "Only mine iridium", "sell now"
  assert(Editor.model(s, "miner", d).dirty)
  local ok, toast = Editor.save(s, "miner", d)
  assert(ok and toast == AiConfig.editor.savedToast, "applied toast")
  assert(not Editor.model(s, "miner", d).dirty)
  local p = Prompt.build(s, "miner")
  assert(p.text:find("Only mine iridium", 1, true) and p.text:find("sell now", 1, true), "texts are in the prompt")
  s:run(600)
  assert(s.agents.miner.order == "sell now", "order persists across decisions")
  assert(Prompt.build(s, "miner").text:find("sell now", 1, true))
  Editor.clearOrder(s, "miner", d)
  assert(s.agents.miner.order == "" and d.order == "")
  assert(Prompt.build(s, "miner").text:find("[CURRENT ORDER]\nnone", 1, true), "cleared order reads none")
end

-- 6. presets: vague and precise, the precise one fits the limit
do
  local s = sim()
  local d = Editor.newDraft(s, "miner")
  local list = Editor.presets(s)
  assert(#list == 2)
  assert(Editor.applyPreset(s, d, "vague") and d.directive == "mine")
  assert(Editor.applyPreset(s, d, "precise") and Editor.model(s, "miner", d).canSave)
  assert(not Editor.applyPreset(s, d, "nope"))
end

-- 7. the Agents screen draws the editor (a spec with two text inputs, counters, buttons)
do
  local s = sim()
  local draft = Editor.newDraft(s, "miner")
  local spec = Shell.spec(s, "agents", { draft = draft })
  local inputs, buttons = 0, {}
  local function walk(n)
    if n.input then inputs += 1 end
    if n.button then buttons[n.button.action] = true end
    for _, c in ipairs(n.children or {}) do walk(c) end
  end
  walk(spec)
  assert(inputs == 0, "the shell holds no input (they are their own tree)")
  local inputsSpec = Shell.inputsSpec(draft, {})
  walk(inputsSpec)
  assert(inputs == 2, "directive and order inputs: " .. inputs)
  local f = Shell.editorFields()
  assert(f.directive.x + f.directive.w < f.order.x and f.order.y == f.directive.y, "fields sit side by side without overlapping")
  assert(buttons["editor.save"] and buttons["editor.clear_order"] and buttons["editor.preset.vague"] and buttons["editor.preset.precise"])
end

print("test_editor: ok")
