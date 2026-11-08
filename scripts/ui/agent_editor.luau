-- Agent editor view-model (spec §9.4, GR5-5): the directive and order drafts, their live token counters and the estimated
-- cost of one decision. Pure reads of the sim plus a draft table, no engine calls, so it is testable headless.
-- Cost uses the real prompt builder with the draft swapped in, so what the editor shows is what the ledger will bill.
local Compute = require("@scripts/sim/compute")
local Prompt = require("@scripts/sim/prompt")
local ComputeView = require("@scripts/ui/compute_view")
local Settings = require("@scripts/sim/context_settings")
local Skills = require("@scripts/sim/skills")
local Screens = require("@scripts/config/screens")
local ExamplesConfig = require("@scripts/config/directive_examples")
local Registry = require("@scripts/sim/branches/registry")

local Editor = {}

-- A draft starts as what the agent has saved.
function Editor.newDraft(sim, agentId)
  local agent = sim.agents[agentId]
  return { directive = agent.directive, order = agent.order }
end

-- A counter: tokens of the text against its limit. state: "ok" | "warn" (near the limit) | "over" (cannot be saved).
-- Both "warn" and "over" are drawn amber.
local function counter(cfg, text, max)
  local tokens = Compute.estimateTokens(cfg, text)
  local state = "ok"
  if tokens > max then state = "over" elseif tokens >= max * cfg.editor.amberFraction then state = "warn" end
  return { tokens = tokens, max = max, state = state, amber = state ~= "ok", text = ("%d / %d"):format(tokens, max) }
end

function Editor.canSave(sim, draft)
  local e = sim.compute.cfg.editor
  return Compute.estimateTokens(sim.compute.cfg, draft.directive) <= e.directiveMaxTokens
    and Compute.estimateTokens(sim.compute.cfg, draft.order) <= e.orderMaxTokens
end

-- Tools the agent owns but cannot use yet, each with the actual requirement.
function Editor.lockedTools(sim, agentId)
  local agent = sim.agents[agentId]
  local out = {}
  for _, name in ipairs(sim.registry.toolOrder) do
    if agent.tools[name] and not sim:hasTool(agentId, name) then
      local tier = sim.registry.toolTier[name]
      local reason = (name == "scan" and not sim.upgrades.scanner) and "buy the Scanner in the shop"
        or (tier and tier > agent.tier and ("unlocks at T%d"):format(tier)) or "not available"
      out[#out + 1] = { name = name, reason = reason }
    end
  end
  return out
end

-- The agent list (left column): one row per agent, the selected one marked, a Monitor-locked one flagged.
function Editor.list(sim, selectedId)
  local rows = {}
  for _, id in ipairs(sim.agentOrder) do
    local a = sim.agents[id]
    rows[#rows + 1] = { id = id, type = a.type, state = a.state, selected = id == selectedId, locked = a.monitorLock == true,
      action = "team.open." .. id, status = a.monitorLock and (a.state .. ", locked") or a.state }
  end
  return rows
end

-- Newest calls of one agent (the Agents screen feed), and whether a run of 2-8 successful calls can be saved as a skill.
function Editor.feed(sim, agentId)
  local out, list = {}, sim.feed or {}
  for i = #list, 1, -1 do
    local e = list[i]
    if e.agent == agentId then
      out[#out + 1] = { text = e.text, status = e.status or "ok", source = e.source, tool = e.tool }
      if #out >= Screens.editor.feedLines then break end
    end
  end
  local ok = 0
  for i = #list, 1, -1 do
    local e = list[i]
    if e.agent == agentId and e.kind == "call" then
      if e.status ~= "ok" then break end
      ok += 1
    end
  end
  return { entries = out, canSave = ok >= 2, saveAction = "studio.rec.open." .. agentId }
end

-- The whole editor for one agent.
function Editor.model(sim, agentId, draft)
  local cfg = sim.compute.cfg
  local agent = sim.agents[agentId]
  draft = draft or Editor.newDraft(sim, agentId)
  local p = Prompt.build(sim, agentId, { directive = draft.directive, order = draft.order })
  local totalTokens = p.input + cfg.estimatedOutputTokens
  local compute = Compute.cost(cfg, totalTokens)

  local formats = {}
  for _, f in ipairs({ "compact", "json" }) do
    local fp = Prompt.build(sim, agentId, { directive = draft.directive, order = draft.order,
      settings = assert(Settings.with(agent.contextSettings, "format", f)) })
    formats[#formats + 1] = { format = f, context = fp.sections.context, total = fp.input, active = f == p.format }
  end

  local saved = Editor.newDraft(sim, agentId)
  return {
    agentId = agentId,
    directive = counter(cfg, draft.directive, cfg.editor.directiveMaxTokens),
    order = counter(cfg, draft.order, cfg.editor.orderMaxTokens),
    canSave = Editor.canSave(sim, draft),
    dirty = draft.directive ~= saved.directive or draft.order ~= saved.order,
    orderActive = agent.order ~= "",
    orderSource = (agent.order ~= "" and agent.orderSource) or nil,
    -- the Monitor lock: only shown once a Monitor is hired, and never for the Monitor itself
    lock = (sim.agents.monitor and agent.type ~= "monitor") and { locked = agent.monitorLock == true, action = "editor.lock" } or nil,
    sections = p.sections,
    inputTokens = p.input,
    outputTokens = cfg.estimatedOutputTokens,
    totalTokens = totalTokens,
    cost = { compute = compute, credits = Compute.creditsFor(cfg, compute), text = ComputeView.costText(sim, compute) },
    formats = formats,
    format = p.format,
    tools = Prompt.toolWeights(sim, agentId),
    lockedTools = Editor.lockedTools(sim, agentId),
    toolSlots = (function() local used, max = sim:toolSlots(agentId) return { used = used, max = max } end)(),
    type = agent.type, state = agent.state, mode = agent.mode == "skill" and (agent.activeSkill or "skill") or "AI",
    skills = { slots = sim:skillSlots(agentId), used = Skills.count(sim), active = agent.activeSkill, params = agent.skillParams },
  }
end

-- Directive examples (GR5-106, config/directive_examples.luau). The dropdown lists the examples of the agent's role, once
-- the role's branch is open and, for mission examples, once that mission has started. An example only ever fills the
-- directive draft: its prerequisites are reported, never granted.
local function missionStarted(sim, n)
  for _, e in ipairs(sim.missions or {}) do
    if e.id == n then return e.status ~= "locked" end
  end
  return false
end

local function exampleVisible(sim, ex)
  if ex.general then return true end
  for _, n in ipairs(ex.missions or {}) do
    if missionStarted(sim, n) then return true end
  end
  return false
end

-- One prerequisite -> { text, met }.
local function prerequisite(sim, agentId, need)
  local agent = sim.agents[agentId]
  if need.kind == "tool" then
    return { text = "tool " .. need.name, met = sim:hasTool(agentId, need.name) }
  elseif need.kind == "skill" then
    local sk = sim.skills[need.name]
    return { text = "skill " .. need.name .. " saved in the Archive", met = sk ~= nil and sk.agent_type == agent.type }
  elseif need.kind == "setting" then
    return { text = need.label, met = agent.contextSettings[need.key] == need.value }
  elseif need.kind == "upgrade" then
    return { text = need.label, met = sim.upgrades[need.id] == true }
  elseif need.kind == "monitor_alert" then
    local st = sim.monitorSettings
    return { text = "Monitor alert " .. need.name .. " on", met = st ~= nil and st.alertTypes ~= nil and st.alertTypes[need.name] == true }
  elseif need.kind == "monitor_heartbeat_off" then
    local st = sim.monitorSettings
    return { text = "Monitor heartbeat off", met = st ~= nil and st.heartbeat == false }
  end
  return { text = tostring(need.kind), met = false }
end

-- The examples the player can pick for this agent, in config order. -> { { id, grade, gradeLabel, directive, hint, watch,
-- stubNote, prerequisites = { { text, met } }, ready, tokens, fits }, ... }
function Editor.examples(sim, agentId)
  local agent = sim.agents[agentId]
  local out = {}
  if not agent then return out end
  local branch = sim.registry:branchOfAgentType(agent.type)
  if branch and not Registry.isOpen(sim, branch) then return out end
  local cfg = sim.compute.cfg
  for _, ex in ipairs(ExamplesConfig.examples) do
    if ex.role == agent.type and exampleVisible(sim, ex) then
      local needs, ready = {}, true
      for _, need in ipairs(ex.needs) do
        local r = prerequisite(sim, agentId, need)
        needs[#needs + 1] = r
        if not r.met then ready = false end
      end
      local tokens = Compute.estimateTokens(cfg, ex.directive)
      out[#out + 1] = { id = ex.id, grade = ex.grade, gradeLabel = ExamplesConfig.grades[ex.grade], directive = ex.directive, hint = ex.hint,
        watch = ex.watch, stubNote = (sim.provider == nil and ex.stub ~= "ok") and ExamplesConfig.stubNote or nil,
        prerequisites = needs, ready = ready, tokens = tokens, fits = tokens <= cfg.editor.directiveMaxTokens }
    end
  end
  return out
end

-- Put an example's directive in the draft. Nothing else changes: not the order, the tools, the skills, the settings, nor
-- the saved directive (that waits for Save). Replacing an unsaved, different directive needs `confirmed`.
-- -> true | false, "unknown_example" | "too_long" | "confirm_replace"
function Editor.applyExample(sim, agentId, draft, id, confirmed)
  local found
  for _, ex in ipairs(Editor.examples(sim, agentId)) do
    if ex.id == id then found = ex end
  end
  if not found then return false, "unknown_example" end
  if not found.fits then return false, "too_long" end
  local unsaved = draft.directive ~= "" and draft.directive ~= sim.agents[agentId].directive and draft.directive ~= found.directive
  if unsaved and not confirmed then return false, "confirm_replace" end
  draft.directive = found.directive
  return true
end

-- The dropdown as the shell draws it: `state` is { open, selected, confirm } kept by the client (nil = closed).
function Editor.examplesView(sim, agentId, state)
  state = state or {}
  local list = Editor.examples(sim, agentId)
  local agent = sim.agents[agentId]
  local selected = state.selected
  local known = false
  for _, ex in ipairs(list) do if ex.id == selected then known = true end end
  if not known then selected = nil end
  return { open = state.open == true, list = list, selected = selected, confirm = state.confirm, roleLabel = ExamplesConfig.roleLabels[agent.type] or agent.type,
    empty = ExamplesConfig.noExamples, noSelection = "Pick an example to preview it", watchLabel = ExamplesConfig.watchLabel,
    noMeasure = ExamplesConfig.noMeasure, useLabel = "Use this directive", confirmLabel = "Replace unsaved text? Click again",
    tooLong = "Over the directive limit: cannot be used." }
end

-- Preset keys in display order.
function Editor.presets(sim)
  local out = {}
  for key, preset in pairs(sim.compute.cfg.editor.presets) do out[#out + 1] = { key = key, label = preset.label } end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

-- Put a preset's directive in the draft; the order is left alone.
function Editor.applyPreset(sim, draft, key)
  local preset = sim.compute.cfg.editor.presets[key]
  if not preset then return false, "unknown_preset" end
  draft.directive = preset.directive
  return true
end

-- Save the draft into the agent: it is read at the agent's next decision. Nothing is saved when either text is over its
-- limit. -> ok, toast | error code
function Editor.save(sim, agentId, draft)
  if not Editor.canSave(sim, draft) then return false, "too_long" end
  local ok, err = sim:setDirective(agentId, draft.directive)
  if not ok then return false, err end
  ok, err = sim:setOrder(agentId, draft.order)
  if not ok then return false, err end
  return true, sim.compute.cfg.editor.savedToast
end

-- Clear the one-off order, in the draft and in the agent at once.
function Editor.clearOrder(sim, agentId, draft)
  draft.order = ""
  return sim:setOrder(agentId, "")
end

return Editor
