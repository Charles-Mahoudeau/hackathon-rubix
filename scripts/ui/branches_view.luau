-- Branches screen (B-0, spec §15b.1): one row per branch with its state (open / available to buy / locked with the reason),
-- its agents, and their net credits/h and Compute/h. Pure reads of the sim; actions are "branches.open.<id>".
local DecisionLog = require("@scripts/sim/decision_log")
local Registry = require("@scripts/sim/branches/registry")
local BranchesConfig = require("@scripts/config/branches")
local Words = require("@scripts/config/copy")

local View = {}

local function round1(x) return math.floor(x * 10 + 0.5) / 10 end

local function reasonText(sim, why)
  local R = BranchesConfig.reasons
  local rep = why:match("^reputation_(%d+)$")
  if rep then return R.reputation:format(tonumber(rep)) end
  local item = why:match("^needs_([%w_]+)$")
  if item then
    local def = sim.b.shop.items[item]
    return R.needs:format(def and def.name or item)
  end
  return R[why] or why
end

local function row(sim, def)
  local names, credits, compute = {}, 0, 0
  for _, id in ipairs(sim.agentOrder) do
    if sim.registry:branchOfAgentType(sim.agents[id].type) == def.id then
      local stats = DecisionLog.stats(sim, id)
      names[#names + 1] = id
      credits += stats.net_per_hour
      compute += stats.compute_per_hour
    end
  end
  local r = { id = def.id, name = def.name, agents = names, creditsPerHour = math.floor(credits + 0.5), computePerHour = round1(compute) }
  local cost = def.unlock and def.unlock.cost or 0
  if Registry.isOpen(sim, def.id) then
    r.state, r.label = BranchesConfig.states.open, Words.states.open
    return r
  end
  local lock = Registry.lockReason(sim, def)
  if lock then
    r.state, r.label, r.note = BranchesConfig.states.locked, Words.states.locked, reasonText(sim, lock)
    return r
  end
  r.state, r.label, r.cost = BranchesConfig.states.available, Words.states.available, cost
  if Registry.blocker(sim, def.id) then
    r.note = reasonText(sim, "not_enough_credits")
  else
    r.action = "branches.open." .. def.id
  end
  return r
end

function View.model(sim)
  local rows = {}
  for _, def in ipairs(sim.registry.list) do rows[#rows + 1] = row(sim, def) end
  local opened = 0
  for _, r in ipairs(rows) do
    if r.state == BranchesConfig.states.open then opened += 1 end
  end
  -- The hint only shows while mining is the one open branch.
  return { rows = rows, used = #sim.agentOrder, capacity = sim:commandCapacity(), hint = opened <= 1 and Words.branches.hint or nil }
end

function View.signature(sim)
  local parts = { tostring(#sim.agentOrder), tostring(math.floor(sim.resources.credits / 100)) }
  for _, r in ipairs(View.model(sim).rows) do
    parts[#parts + 1] = r.id .. r.state .. #r.agents .. r.creditsPerHour .. r.computePerHour .. (r.note or "")
  end
  return table.concat(parts, ",")
end

-- "branches.open.<id>" -> handled, ok, err
function View.act(sim, action)
  if type(action) ~= "string" then return false end
  local id = action:match("^branches%.open%.([%w_]+)$")
  if not id then return false end
  return true, sim:openBranch(id)
end

return View
