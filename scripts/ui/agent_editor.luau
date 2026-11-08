-- Agent editor view-model (spec §9.4, GR5-5): the directive and order drafts, their live token counters and the estimated
-- cost of one decision. Pure reads of the sim plus a draft table, no engine calls, so it is testable headless.
-- Cost uses the real prompt builder with the draft swapped in, so what the editor shows is what the ledger will bill.
local Compute = require("@scripts/sim/compute")
local Prompt = require("@scripts/sim/prompt")
local ComputeView = require("@scripts/ui/compute_view")
local Settings = require("@scripts/sim/context_settings")
local Skills = require("@scripts/sim/skills")
local Screens = require("@scripts/config/screens")

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
