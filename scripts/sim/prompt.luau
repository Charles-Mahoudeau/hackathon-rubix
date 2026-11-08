-- PromptBuilder (spec §9.1): assembles the exact prompt an agent is billed for, and its token weight per section.
-- The panel, the editor and the ledger all call Prompt.build, so what the player sees is what is billed.
local Ai = require("@scripts/config/ai")
local Compute = require("./compute")
local ContextBuilder = require("./context_builder")
local Renderer = require("./context_renderer")
local Json = require("./json")

local Prompt = {}

local function rulesText(agent, format)
  local r = Ai.rules
  local lines = {
    r.intro,
    "Your role: " .. (r.role[agent.type] or agent.type) .. ".",
    r.act, r.reply, r.replyShape, r.fallback,
  }
  if format == "compact" then
    for _, l in ipairs(r.compactLegend) do lines[#lines + 1] = l end
  end
  return table.concat(lines, "\n")
end

-- One arg as a short phrase: "integer 10-300 required (desc)". Static text, it is the tool's token weight.
local function argText(spec)
  local parts = { spec.type }
  if spec.enum then parts[#parts + 1] = table.concat(spec.enum, "|") end
  if spec.min or spec.max then parts[#parts + 1] = (spec.min or "") .. "-" .. (spec.max or "") end
  if spec.maxLength then parts[#parts + 1] = "<=" .. spec.maxLength .. " chars" end
  if spec.required then parts[#parts + 1] = "required" end
  local text = table.concat(parts, " ")
  if spec.desc then text = text .. " (" .. spec.desc .. ")" end
  return text
end

local function toolsText(sim, agentId)
  local out = {}
  for _, name in ipairs(sim:equippedTools(agentId)) do
    local sch = sim.registry.schemas[name]
    if sch then
      local args = {}
      for k, v in pairs(sch.args) do args[k] = argText(v) end
      out[#out + 1] = Json.encode({ name = name, description = sch.description, args = args })
    end
  end
  return table.concat(out, "\n")
end

local function orNone(text)
  if text == nil or text == "" then return "none" end
  return text
end

-- Token weight of each equipped tool's schema line (D14: every equipped tool is paid for in every prompt).
function Prompt.toolWeights(sim, agentId)
  local out = {}
  for _, name in ipairs(sim:equippedTools(agentId)) do
    local sch = sim.registry.schemas[name]
    local args = {}
    for k, v in pairs(sch.args) do args[k] = argText(v) end
    out[#out + 1] = { name = name, tokens = Compute.estimateTokens(Ai, Json.encode({ name = name, description = sch.description, args = args })) }
  end
  return out
end

-- opts.settings overrides the agent's own context settings (the panel previews options without saving them);
-- opts.directive / opts.order override the saved texts (the editor previews a draft the same way).
-- -> { text, sections = {rules, directive, order, context, tools}, input, contextText, format }
function Prompt.build(sim, agentId, opts)
  local agent = sim.agents[agentId]
  local settings = (opts and opts.settings) or agent.contextSettings
  local contextText = Renderer.render(ContextBuilder.build(sim, agentId, settings), settings.format)
  local parts = {
    rules = rulesText(agent, settings.format),
    directive = "[PLAYER DIRECTIVE]\n" .. orNone(opts and opts.directive or agent.directive),
    order = "[CURRENT ORDER]\n" .. orNone(opts and opts.order or agent.order),
    context = "[CONTEXT]\n" .. contextText,
    tools = "[TOOLS]\n" .. toolsText(sim, agentId),
  }
  local sections, input = {}, 0
  for name, text in pairs(parts) do
    sections[name] = Compute.estimateTokens(Ai, text)
    input = input + sections[name]
  end
  local text = table.concat({ parts.rules, parts.directive, parts.order, parts.context, parts.tools }, "\n\n")
  return { text = text, sections = sections, input = input, contextText = contextText, format = settings.format,
    system = parts.rules, user = table.concat({ parts.directive, parts.order, parts.context, parts.tools }, "\n\n") }
end

-- What the real provider is sent for one decision: `built` is a Prompt.build result. `tools` is what the validator
-- accepts (equipped tools by name); `note` is the short line Axis records as the user turn (memory, not the full prompt).
function Prompt.forProvider(sim, agentId, built)
  local tools = {}
  for _, name in ipairs(sim:equippedTools(agentId)) do tools[name] = sim.registry.schemas[name] end
  local ship
  for _, sid in ipairs(sim.shipOrder) do
    if sim.ships[sid].owner == agentId then ship = sim.ships[sid] break end
  end
  local note = ("t=%.1fs %s credits %d compute %.1f"):format(sim.tick * sim.b.tickSeconds, agentId,
    sim.resources.credits, sim.resources.compute)
  if ship then note = note .. (" ship %s at %s hold %d"):format(ship.state, ship.at, ship.cargo) end
  return { system = built.system, user = built.user, note = note, tools = tools }
end

-- Tokens billed for the model's reply (the JSON tool call). `reasoning` may be nil.
function Prompt.outputTokens(call, reasoning)
  local reply = Json.encode(Json.map({ { "reasoning", reasoning or "" }, { "tool", call and call.name or "" },
    { "args", call and call.args or {} } }))
  return Compute.estimateTokens(Ai, reply)
end

return Prompt
