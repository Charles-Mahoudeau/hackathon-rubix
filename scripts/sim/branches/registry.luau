-- Branch registry (spec §15b.0, B-0). A branch is data: one table per branch, in sim/branches/<id>.luau, listed in
-- sim/branches/index.luau. The registry merges every branch into what the sim reads: agent types, tool tiers and schemas,
-- alert kinds, parameter kinds and Monitor scopes. Pure Luau, headless, no UI calls.
--
-- A branch table:
--   id, name, scope                       scope = the Monitor scope of the branch
--   unlock = { startsOpen = true } | { tier, cost, rep, needs }   how it opens (needs = a shop item id)
--   agent = { type, tools = {...}, startTier, toolSlots, stub = { optimal, directive }, busy?(sim, agent) -> bool, skip?(sim, agent, call) -> reason | nil,
--     context?(sim, agent) -> snapshot for the prompt, at?(sim, agent) -> location text for the Monitor }
--     busy/skip tell the skill runner when the asset is occupied and which steps have nothing to do
--   asset = { type, label }               what the agent runs (ship, ...)
--   tools = { name = { tier, schema?, validate?(sim, agent, args) -> ok, err, apply?(sim, agentId, args, info) -> text, result } }
--   alerts = { kinds = { name = { after? } }, detect?(sim, cfg, raise) }
--   paramKinds = { name = { check(sim, paramName, value, decl) -> error text | nil } }
--   onOpen?(sim)                          creates the first agent and asset
-- A tool with a `schema` is new (its schema and tier come from the branch); without one it is a tool of config/tools.luau.
local Feed = require("@scripts/sim/feed")
local Words = require("@scripts/config/copy")
local ToolsConfig = require("@scripts/config/tools")
local BranchesConfig = require("@scripts/config/branches")

local Registry = {}
Registry.__index = Registry

-- Parameter kinds that exist for later branches (spec §15b.0): registered, with no checker, until their branch lands.
Registry.reservedParamKinds = { "site", "recipe", "route", "convoy_filter" }

-- Kinds the company-wide Archive always knows (checked in sim/skills.luau): they belong to no branch.
Registry.sharedParamKinds = { "destination", "buyer", "station" }

-- Keys of a table in name order, so a branch's tools and alert kinds register in the same order on every run.
local function sortedKeys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end

local function insertAfter(list, after, name)
  for i, v in ipairs(list) do
    if v == after then table.insert(list, i + 1, name) return end
  end
  list[#list + 1] = name
end

-- defs: the branch tables in display order. b: the balance table (shared agent types, tiers, alert types).
function Registry.new(defs, b)
  local reg = setmetatable({ list = {}, byId = {}, agentTypes = {}, toolTier = {}, toolDefs = {}, schemas = {}, toolOrder = {},
    alertGroup = {}, paramKinds = {}, scopeOf = {} }, Registry)
  for name, spec in pairs(ToolsConfig.schemas) do reg.schemas[name] = spec end
  for _, name in ipairs(ToolsConfig.order) do reg.toolOrder[#reg.toolOrder + 1] = name end
  for tier, names in pairs(b.tiers) do
    for _, name in ipairs(names) do reg.toolTier[name] = tier end
  end
  for kind, def in pairs(b.agents) do
    reg.agentTypes[kind] = { type = kind, tools = def.tools, startTier = def.startTier, toolSlots = b.toolSlots[kind] or 0 }
  end
  reg.alertTypes = {}
  for _, t in ipairs(b.alerts.types) do reg.alertTypes[#reg.alertTypes + 1] = t end
  for _, name in ipairs(Registry.reservedParamKinds) do reg.paramKinds[name] = { reserved = true } end
  for _, name in ipairs(Registry.sharedParamKinds) do reg.paramKinds[name] = { shared = true } end

  for _, def in ipairs(defs) do
    assert(type(def.id) == "string" and not reg.byId[def.id], "branch: missing or duplicate id " .. tostring(def.id))
    assert(def.scope and not reg.scopeOf[def.scope] and not BranchesConfig.scopes[def.scope], "branch " .. def.id .. ": bad or duplicate scope")
    reg.list[#reg.list + 1] = def
    reg.byId[def.id] = def
    reg.scopeOf[def.scope] = def.id
    local a = def.agent
    if a then
      assert(not reg.agentTypes[a.type], "branch " .. def.id .. ": agent type already exists: " .. a.type)
      reg.agentTypes[a.type] = { type = a.type, tools = a.tools, startTier = a.startTier, toolSlots = a.toolSlots, branch = def.id, stub = a.stub,
        busy = a.busy, skip = a.skip, context = a.context, at = a.at }
    end
    for _, name in ipairs(sortedKeys(def.tools or {})) do
      local tool = def.tools[name]
      assert(not reg.toolDefs[name], "branch " .. def.id .. ": tool declared twice: " .. name)
      reg.toolDefs[name] = tool
      reg.toolTier[name] = tool.tier
      if tool.schema then
        assert(not reg.schemas[name], "branch " .. def.id .. ": tool already exists: " .. name)
        reg.schemas[name] = tool.schema
        reg.toolOrder[#reg.toolOrder + 1] = name
      else
        assert(reg.schemas[name], "branch " .. def.id .. ": tool has no schema: " .. name)
      end
    end
    for _, kind in ipairs(sortedKeys(def.alerts and def.alerts.kinds or {})) do
      local spec = def.alerts.kinds[kind]
      assert(not reg.alertGroup[kind], "branch " .. def.id .. ": alert kind declared twice: " .. kind)
      reg.alertGroup[kind] = def.scope
      if spec.after then insertAfter(reg.alertTypes, spec.after, kind) else reg.alertTypes[#reg.alertTypes + 1] = kind end
    end
    for name, spec in pairs(def.paramKinds or {}) do
      local known = reg.paramKinds[name]
      assert(not known or known.reserved, "branch " .. def.id .. ": parameter kind declared twice: " .. name)
      reg.paramKinds[name] = { branch = def.id, check = spec.check }
    end
  end
  return reg
end

-- The scope an agent type belongs to ("mining", "logistics", ...), nil for the Monitor.
function Registry:scopeOfAgentType(kind)
  local t = self.agentTypes[kind]
  if t and t.branch then return self.byId[t.branch].scope end
  if kind == "logistician" then return "logistics" end
  return nil
end

-- Alert kinds of a branch carry its scope; the others are grouped by alerts.luau.
function Registry:groupOfAlert(kind) return self.alertGroup[kind] end

function Registry:branchOfAgentType(kind)
  local t = self.agentTypes[kind]
  return t and t.branch or nil
end

-- Sim state: sim.branchesOpen = { id = true }.
function Registry.isOpen(sim, id) return sim.branchesOpen[id] == true end

-- Why branch `id` cannot be opened now, or nil: unknown_branch | already_open | tier_locked | reputation_<n> | needs_<item> | not_enough_credits.
function Registry.blocker(sim, id)
  local def = sim.registry.byId[id]
  if not def then return "unknown_branch" end
  if Registry.isOpen(sim, id) then return "already_open" end
  local u = def.unlock or {}
  if u.startsOpen then return "already_open" end
  local why = Registry.lockReason(sim, def)
  if why then return why end
  if sim.resources.credits < (u.cost or 0) then return "not_enough_credits" end
  return nil
end

-- What still keeps the branch shut other than credits: tier_locked | reputation_<n> | needs_<item>, or nil.
function Registry.lockReason(sim, def)
  local u = def.unlock or {}
  if sim.tier < (u.tier or 1) then return "tier_locked" end
  if u.rep and sim:reputationLevel() < u.rep then return "reputation_" .. u.rep end
  if u.needs and not sim:ownsItem(u.needs) then return "needs_" .. u.needs end
  return nil
end

-- Opens the branch: pays its cost, runs onOpen. At start (atStart) it is free. -> ok | false, reason
function Registry.open(sim, id, atStart)
  local def = sim.registry.byId[id]
  if not def then return false, "unknown_branch" end
  if not atStart then
    local why = Registry.blocker(sim, id)
    if why then
      sim:log("ERROR", ("branch %s: cannot open (%s)"):format(id, why))
      return false, why
    end
    sim.resources.credits -= (def.unlock and def.unlock.cost) or 0
  end
  sim.branchesOpen[id] = true
  if def.onOpen then def.onOpen(sim) end
  if not atStart then
    sim:log("INFO", ("branch %s opened"):format(id))
    local unlocked = Words.unlocks.branch[id]
    if unlocked then Feed.info(sim, nil, unlocked) end
    sim:emit("branch_opened", { branch = id })
  end
  return true
end

-- Monitor scopes: company, one per open branch (in branch order), then logistics.
function Registry.scopes(sim)
  local out = {}
  for name, s in pairs(BranchesConfig.scopes) do
    if s.first then out[#out + 1] = name end
  end
  for _, def in ipairs(sim.registry.list) do
    if Registry.isOpen(sim, def.id) then out[#out + 1] = def.scope end
  end
  for name, s in pairs(BranchesConfig.scopes) do
    if not s.first then out[#out + 1] = name end
  end
  return out
end

-- The tool call checker/applier a branch declared for `name`, or nil (the tool is handled by the sim itself).
function Registry:toolDef(name) return self.toolDefs[name] end

return Registry
