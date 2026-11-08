-- Prompt library accessors (GR5-107): the BAD / OK / GOOD examples of config/prompt_library.luau, filtered by what the company has
-- really unlocked. Read-only, no randomness, no UI: a view asks for the examples of the agent it is editing.
local Data = require("@scripts/config/prompt_library")
local Compute = require("@scripts/sim/compute")
local Registry = require("@scripts/sim/branches/registry")

local PromptLibrary = {}

local function findBy(list, key, value)
  for _, item in ipairs(list) do if item[key] == value then return item end end
end

-- Why `ex` (an example of an agent of type `agentType`) cannot be used yet, or nil when it can. A branch role needs its branch
-- open; every tool the directive relies on must belong to the agent type and be unlocked at the company's tier.
function PromptLibrary.blocker(sim, agentType, ex)
  local kind = sim.registry.agentTypes[agentType]
  if not kind then return "unknown_agent_type" end
  if kind.branch and not Registry.isOpen(sim, kind.branch) then return "branch_locked" end
  if sim.tier < (kind.startTier or 1) then return "tier_locked" end
  local tools = {}
  for _, t in ipairs(kind.tools) do tools[t] = true end
  for _, tool in ipairs(ex.tools or {}) do
    if not tools[tool] then return "tool_not_permitted" end
    local tier = sim.registry.toolTier[tool]
    if tier == nil or tier > sim.tier then return "tier_locked" end
    if tool == "scan" and not sim.upgrades.scanner then return "needs_scanner" end
  end
  return nil
end

local function shape(sim, agentType, role, ex)
  return { grade = ex.grade, text = ex.text, text2 = ex.text2, hint = ex.hint, outcome = ex.outcome, support = ex.support,
    unread = ex.unread, role = role, blocker = PromptLibrary.blocker(sim, agentType, ex) }
end

function PromptLibrary.roleIds()
  local out = {}
  for _, r in ipairs(Data.roles) do out[#out + 1] = r.id end
  return out
end

-- Role examples for an agent type, bad / ok / good. Empty when the agent type has no entry or its branch is not open yet, so a
-- locked branch leaves no trace in the editor.
function PromptLibrary.roleExamples(sim, agentType)
  local role = findBy(Data.roles, "agentType", agentType)
  if not role then return {} end
  local kind = sim.registry.agentTypes[agentType]
  if kind and kind.branch and not Registry.isOpen(sim, kind.branch) then return {} end
  local out = {}
  for _, ex in ipairs(role.examples) do out[#out + 1] = shape(sim, agentType, role.id, ex) end
  return out
end

-- Examples of mission `id` (1-8). They are listed once the mission is reachable (not "locked"): earlier missions stay readable.
function PromptLibrary.missionExamples(sim, id)
  local m = findBy(Data.missions, "id", id)
  local entry = sim.missions[id]
  if not m or not entry or entry.status == "locked" then return {} end
  local agentType = findBy(Data.roles, "id", m.role).agentType
  local out = {}
  for _, ex in ipairs(m.examples) do out[#out + 1] = shape(sim, agentType, m.role, ex) end
  return out
end

-- What the editor shows for one agent: its role examples, and the examples of the current mission when that mission is its job.
function PromptLibrary.forAgent(sim, agentId)
  local agent = sim.agents[agentId]
  if not agent then return { role = {}, mission = {} } end
  local out = { role = PromptLibrary.roleExamples(sim, agent.type), mission = {} }
  for _, m in ipairs(Data.missions) do
    local entry = sim.missions[m.id]
    local role = findBy(Data.roles, "id", m.role)
    if entry and entry.status == "active" and role.agentType == agent.type then
      out.mission = PromptLibrary.missionExamples(sim, m.id)
      out.missionId = m.id
    end
  end
  return out
end

function PromptLibrary.challenges() return Data.challenges end

local function each(fn)
  for _, r in ipairs(Data.roles) do
    for _, ex in ipairs(r.examples) do fn("role " .. r.id, r.agentType, ex) end
  end
  for _, m in ipairs(Data.missions) do
    local agentType = findBy(Data.roles, "id", m.role).agentType
    for _, ex in ipairs(m.examples) do fn("mission " .. m.id, agentType, ex) end
  end
end

-- Problems with the data, as strings (empty = valid): three grades per entry, every directive within the editor's token limit,
-- every hint within hintMaxChars, only tools the agent type is permitted, "partial" examples naming what the stub does not read.
function PromptLibrary.validate(sim)
  local problems = {}
  local limit = sim.aiConfig.editor.directiveMaxTokens
  local function add(where, msg) problems[#problems + 1] = where .. ": " .. msg end
  local function check(where, agentType, ex)
    local label = where .. " " .. tostring(ex.grade)
    for _, field in ipairs({ "text", "text2" }) do
      if ex[field] then
        local tokens = Compute.estimateTokens(sim.compute.cfg, ex[field])
        if tokens > limit then add(label, field .. " is " .. tokens .. " tokens, over " .. limit) end
        if tokens == 0 then add(label, field .. " is empty") end
      end
    end
    if utf8.len(ex.hint or "") == nil or utf8.len(ex.hint) > Data.hintMaxChars or ex.hint == "" then add(label, "hint over " .. Data.hintMaxChars .. " characters or empty") end
    if (ex.outcome or "") == "" then add(label, "no outcome") end
    local kind = sim.registry.agentTypes[agentType]
    local permitted = {}
    for _, t in ipairs(kind and kind.tools or {}) do permitted[t] = true end
    if #(ex.tools or {}) == 0 then add(label, "no tools listed") end
    for _, tool in ipairs(ex.tools or {}) do
      if not permitted[tool] then add(label, "tool " .. tool .. " is not permitted for " .. agentType) end
    end
    if ex.support ~= "stub" and ex.support ~= "partial" then add(label, "support must be stub or partial") end
    if ex.support == "partial" and #(ex.unread or {}) == 0 then add(label, "partial support must list what the stub does not read") end
    if ex.support == "stub" and ex.unread then add(label, "stub support lists unread clauses") end
  end
  each(function(where, agentType, ex) check(where, agentType, ex) end)
  for _, r in ipairs(Data.roles) do
    if #r.examples ~= #Data.grades then add("role " .. r.id, "needs " .. #Data.grades .. " examples") end
    for i, g in ipairs(Data.grades) do
      if not r.examples[i] or r.examples[i].grade ~= g then add("role " .. r.id, "example " .. i .. " must be " .. g) end
    end
  end
  for i, m in ipairs(Data.missions) do
    if m.id ~= i then add("mission " .. i, "id out of order") end
    for j, g in ipairs(Data.grades) do
      if not m.examples[j] or m.examples[j].grade ~= g then add("mission " .. m.id, "example " .. j .. " must be " .. g) end
    end
  end
  if #Data.missions ~= #sim.missions then add("missions", "library has " .. #Data.missions .. ", game has " .. #sim.missions) end
  if #Data.challenges ~= 5 then add("challenges", "needs five") end
  for _, c in ipairs(Data.challenges) do
    if type(c.target) ~= "number" or type(c.seed) ~= "number" or not c.fixture then add("challenge " .. c.id, "needs fixture, seed and numeric target") end
  end
  return problems
end

return PromptLibrary
