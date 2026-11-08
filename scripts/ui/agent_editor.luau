-- Agent editor view-model (spec §9.4, GR5-5): the directive and order drafts, their live token counters and the estimated
-- cost of one decision. Pure reads of the sim plus a draft table, no engine calls, so it is testable headless.
-- Cost uses the real prompt builder with the draft swapped in, so what the editor shows is what the ledger will bill.
local Compute = require("@scripts/sim/compute")
local Prompt = require("@scripts/sim/prompt")
local ComputeView = require("@scripts/ui/compute_view")
local Settings = require("@scripts/sim/context_settings")

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
    sections = p.sections,
    inputTokens = p.input,
    outputTokens = cfg.estimatedOutputTokens,
    totalTokens = totalTokens,
    cost = { compute = compute, credits = Compute.creditsFor(cfg, compute), text = ComputeView.costText(sim, compute) },
    formats = formats,
    format = p.format,
    tools = Prompt.toolWeights(sim, agentId),
    skills = { slots = sim:skillSlots(agentId), used = 0 },
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
