-- PromptBuilder (spec §9.1): assembles the exact prompt an agent is billed for, and its token weight per section.
-- The panel, the editor and the ledger all call Prompt.build, so what the player sees is what is billed.
local Ai = require("@scripts/config/ai")
local ToolsConfig = require("@scripts/config/tools")
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

local function toolsText(sim, agentId)
  local out = {}
  for _, name in ipairs(sim:equippedTools(agentId)) do
    local sch = ToolsConfig.schemas[name]
    if sch then
      local args = {}
      for k, v in pairs(sch.args) do args[k] = v end
      out[#out + 1] = Json.encode({ name = name, description = sch.description, args = args })
    end
  end
  return table.concat(out, "\n")
end

local function orNone(text)
  if text == nil or text == "" then return "none" end
  return text
end

-- opts.settings overrides the agent's own context settings (the panel previews options without saving them).
-- -> { text, sections = {rules, directive, order, context, tools}, input, contextText, format }
function Prompt.build(sim, agentId, opts)
  local agent = sim.agents[agentId]
  local settings = (opts and opts.settings) or agent.contextSettings
  local contextText = Renderer.render(ContextBuilder.build(sim, agentId, settings), settings.format)
  local parts = {
    rules = rulesText(agent, settings.format),
    directive = "[PLAYER DIRECTIVE]\n" .. orNone(agent.directive),
    order = "[CURRENT ORDER]\n" .. orNone(agent.order),
    context = "[CONTEXT]\n" .. contextText,
    tools = "[TOOLS]\n" .. toolsText(sim, agentId),
  }
  local sections, input = {}, 0
  for name, text in pairs(parts) do
    sections[name] = Compute.estimateTokens(Ai, text)
    input = input + sections[name]
  end
  local text = table.concat({ parts.rules, parts.directive, parts.order, parts.context, parts.tools }, "\n\n")
  return { text = text, sections = sections, input = input, contextText = contextText, format = settings.format }
end

-- Tokens billed for the model's reply (the JSON tool call). `reasoning` may be nil.
function Prompt.outputTokens(call, reasoning)
  local reply = Json.encode(Json.map({ { "reasoning", reasoning or "" }, { "tool", call and call.name or "" },
    { "args", call and call.args or {} } }))
  return Compute.estimateTokens(Ai, reply)
end

return Prompt
