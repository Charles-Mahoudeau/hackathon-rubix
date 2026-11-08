-- Prompt assembly (spec §9.1, order: rules, directive, order, context, tools) over the sim's context snapshot, rendered in
-- the compact format of spec §9.2.1. Deterministic: same inputs, same text.
local Json = require("@scripts/ai/json")

local Prompt = {}

local RULES = [[You control one agent of a small space mining company in the game GRIDMIND.
Your role: {role}.
You act only by calling exactly one tool from the TOOLS list.
Reply with JSON only, no other text:
{"reasoning": "<at most 25 words>", "tool": "<tool name>", "args": { ... }}
If there is nothing useful to do, call wait.
CONTEXT format: "key: value" lines; "name[n] col col ..." starts a table with one row per item;
"k=v,k=v" groups values in one cell; "?" means unknown; y/n are yes/no.
Abbreviations: res=resource, rich=richness, res%=reserve percent, _s=seconds, at=location.]]

local ROLES = {
  miner = "the Miner, who sends the mining ship to veins, brings the ore back and sells it",
  logistician = "the Logistician, who sells and ships what the warehouse holds",
  monitor = "the Monitor, who supervises the other agents",
}

local function num(x)
  if x == nil then return "?" end
  return tostring(math.floor(x * 10 + 0.5) / 10)
end

local function sortedKeys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end

function Prompt.renderContext(sim, ctx)
  local lines = {}
  local function add(s) lines[#lines + 1] = s end
  add("time: " .. num(ctx.tick * sim.b.tickSeconds) .. "s")
  local s = ctx.ship
  add(("ship: at=%s state=%s hold=%s/%s ore=%s vein=%s"):format(s.at, s.state, num(s.cargo), num(s.hold), s.ore or "?", s.vein or "?"))
  local rows = {}
  for _, pid in ipairs(sortedKeys(ctx.planets)) do
    local p = ctx.planets[pid]
    for _, v in ipairs(p.veins) do
      rows[#rows + 1] = ("%s %s %s %s %d %s %s"):format(v.id, pid, v.ore, v.richness and num(v.richness) or v.band, v.jumps,
        v.reserve and num(100 * v.reserve / v.max) or "?", p.reachable and "y" or "n")
    end
  end
  if #rows > 0 then
    add(("veins[%d] id planet res rich jumps res%% reachable"):format(#rows))
    for _, r in ipairs(rows) do add(r) end
  end
  local depots = {}
  for _, pid in ipairs(sortedKeys(ctx.planets)) do depots[#depots + 1] = pid .. "=" .. num(ctx.planets[pid].depotRate) end
  add("depot_rate: " .. table.concat(depots, " "))
  add("credits: " .. num(ctx.resources.credits))
  add("compute: " .. num(ctx.resources.compute))
  return table.concat(lines, "\n")
end

-- tools: the names the agent holds, in order. Returns the schemas by name and the TOOLS text.
local function renderTools(names, schemas)
  local equipped, out = {}, {}
  for _, name in ipairs(names) do
    local def = schemas[name]
    if def then
      equipped[name] = def
      local args = {}
      for _, a in ipairs(sortedKeys(def.args or {})) do
        local spec = def.args[a]
        args[a] = { type = spec.type, required = spec.required or nil, enum = spec.enum, min = spec.min, max = spec.max }
      end
      out[#out + 1] = Json.encode({ name = name, description = def.description, args = args })
    end
  end
  return equipped, table.concat(out, "\n")
end

-- Returns { system, user, note, tools = equipped schemas by name }.
function Prompt.build(sim, agentId, ctx, schemas)
  local agent = sim.agents[agentId]
  local equipped, toolsText = renderTools(sim:equippedTools(agentId), schemas)
  local directive = agent.directive
  local order = agent.order
  local user = table.concat({
    "[PLAYER DIRECTIVE]", (directive and directive ~= "") and directive or "none",
    "[CURRENT ORDER]", (order and order ~= "") and order or "none",
    "[CONTEXT]", Prompt.renderContext(sim, ctx),
    "[TOOLS]", toolsText,
  }, "\n")
  local s = ctx.ship
  local note = ("t=%ss %s ship %s at %s hold %s/%s credits %s"):format(num(ctx.tick * sim.b.tickSeconds), agentId, s.state, s.at,
    num(s.cargo), num(s.hold), num(ctx.resources.credits))
  return { system = (RULES:gsub("{role}", function() return ROLES[agentId] or agentId end)), user = user, note = note, tools = equipped }
end

return Prompt
