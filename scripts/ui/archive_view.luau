-- Archive screen view-model (GR5-10, spec §13): the company-wide skills with who runs them and with what values, the
-- slot count, the calls of the feed that can be recorded, and the "Simulate 1 h away" demo button once a skill exists.
-- Pure reads and sim calls, so the whole path is testable headless; the shell only lays it out.
local Skills = require("@scripts/sim/skills")
local Debug = require("@scripts/sim/debug")
local OfflineView = require("@scripts/ui/offline_view")
local Screens = require("@scripts/config/screens")

local View = {}

local function paramsText(values)
  local keys = {}
  for k in pairs(values or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = ("%s=%s"):format(k, tostring(values[k])) end
  return table.concat(parts, ", ")
end

local function stepText(step)
  local args = {}
  local keys = {}
  for k in pairs(step.args or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do args[#args + 1] = ("%s=%s"):format(k, tostring(step.args[k])) end
  local text = step.tool .. (#args > 0 and (" " .. table.concat(args, " ")) or "")
  if step.guard and step.guard.min_unit_price then text ..= (" (only if price >= %g)"):format(step.guard.min_unit_price) end
  return text
end

function View.model(sim)
  local usage = Skills.usage(sim)
  local skills = {}
  for _, name in ipairs(Skills.names(sim)) do
    local s = sim.skills[name]
    local paramNames = {}
    for p in pairs(s.params or {}) do paramNames[#paramNames + 1] = "$" .. p end
    table.sort(paramNames)
    local steps = {}
    for i, st in ipairs(s.steps) do steps[i] = stepText(st) end
    local runners = {}
    for _, u in ipairs(usage[name] or {}) do
      runners[#runners + 1] = { agent = u.agent, params = paramsText(u.params), aborted = u.aborted,
        restart = u.aborted and ("archive.restart." .. u.agent) or nil }
    end
    skills[#skills + 1] = { name = name, agentType = s.agent_type, loop = s.loop, params = paramNames, steps = steps,
      createdFrom = s.created_from or "manual", runners = runners, delete = "archive.delete." .. name }
  end
  local used, max = Skills.count(sim), sim:archiveCapacity()
  return {
    skills = skills,
    slots = { used = used, max = max, text = ("Skills %d/%d"):format(used, max) },
    canSimulateAway = used > 0,
    simulateAway = used > 0 and "archive.away" or nil,
    offline = OfflineView.model(sim),
  }
end

-- One string that changes when what the screen shows changes.
function View.signature(sim)
  local parts = { OfflineView.signature(sim), tostring(Skills.count(sim)) }
  for _, id in ipairs(sim.agentOrder) do
    local a = sim.agents[id]
    if a.mode == "skill" then parts[#parts + 1] = id .. tostring(a.activeSkill) .. tostring(a.skillRun and a.skillRun.aborted or "") end
  end
  return table.concat(parts, ",")
end

-- The feed calls the player can record into a skill: successful calls of one agent, oldest first (spec §13.1).
function View.recordable(sim, agentId)
  local out = {}
  for _, e in ipairs(sim.feed) do
    if e.kind == "call" and e.agent == agentId and e.status == "ok" then out[#out + 1] = { id = e.id, tool = e.tool, args = e.args } end
  end
  return out
end

-- "Save as skill" on feed calls firstId..lastId. -> ok, name | false, error, suggestion
function View.recordAndSave(sim, agentId, firstId, lastId, name, opts)
  local skill, err = Skills.record(sim, agentId, firstId, lastId, name)
  if not skill then return false, err end
  return Skills.save(sim, skill, opts)
end

-- Form: a skill from step rows typed by the player (same validation as a recording).
function View.saveForm(sim, skill, opts) return Skills.save(sim, skill, opts) end

-- Assign (player or editor drop-down): name nil = back to AI mode. -> ok | false, error
function View.assign(sim, agentId, name, params) return Skills.assign(sim, agentId, name, params) end

-- "archive.delete.<name>", "archive.restart.<agent>", "archive.away" -> handled, ok, error.
function View.act(sim, action)
  if type(action) ~= "string" then return false end
  local name = action:match("^archive%.delete%.(.+)$")
  if name then return true, Skills.delete(sim, name) end
  local agent = action:match("^archive%.restart%.(.+)$")
  if agent then return true, Skills.restart(sim, agent) end
  if action == "archive.away" then
    if Skills.count(sim) == 0 then return true, false, "no_skill" end
    local ok, res = Debug.run(sim, "simulateAway", { hours = Screens.archive.awayHours })
    return true, ok, ok and nil or res
  end
  return false
end

return View
