-- Run from repo root: luau tests/test_branches.luau
-- B-0: mining declared as the first branch, the registry, the Branches panel, Monitor scopes by branch, and the acceptance
-- test: a dummy branch with one tool is added without touching anything outside sim/branches/ and config/.
local Sim = require("@scripts/sim/sim")
local Registry = require("@scripts/sim/branches/registry")
local Branches = require("@scripts/sim/branches/index")
local Mining = require("@scripts/sim/branches/mining")
local RaidingBranch = require("@scripts/sim/branches/raiding")
local Persistence = require("@scripts/sim/persistence")
local BranchesView = require("@scripts/ui/branches_view")
local AlertsView = require("@scripts/ui/alerts_view")

local function has(list, v) for _, x in ipairs(list) do if x == v then return true end end return false end
local function eq(list, want)
  assert(#list == #want, table.concat(list, ",") .. " vs " .. table.concat(want, ","))
  for i, v in ipairs(want) do assert(list[i] == v, table.concat(list, ",") .. " vs " .. table.concat(want, ",")) end
end

-- 1. mining is a branch: declared as data, open from the start, same values as before the refactor
do
  local s = Sim.new()
  local r = s.registry
  assert(#Branches.all == 2 and Branches.all[1] == Mining and Branches.all[2] == RaidingBranch and r.byId.mining and r.byId.raiding)
  assert(Registry.isOpen(s, "mining") and s.agents.miner and s.ships.s1 and s.ships.s1.owner == "miner")
  local miner = r.agentTypes.miner
  eq(miner.tools, { "mine", "return", "sell", "store", "report", "wait", "scan", "run_skill" })
  assert(miner.toolSlots == 5 and miner.startTier == 1 and miner.branch == "mining")
  assert(r.toolTier.mine == 1 and r.toolTier["return"] == 1 and r.toolTier.scan == 2 and r.toolTier.store == 3)
  assert(r.toolTier.sell == 1 and r.toolTier.ship == 4 and r.toolTier.set_order == 5)
  eq(r.alertTypes, { "agent_paused", "skill_aborted", "no_compute", "agent_idle", "losing_money", "crowding", "station_full", "freighter_idle", "notoriety_high", "retaliation" })
  eq(Registry.scopes(s), { "company", "mining", "logistics" })
  assert(r.alertGroup.crowding == "mining" and r:scopeOfAgentType("miner") == "mining" and r:scopeOfAgentType("logistician") == "logistics")
  for _, k in ipairs({ "vein", "resource", "pct", "site", "recipe", "route", "convoy_filter", "destination", "buyer", "station" }) do
    assert(r.paramKinds[k], "parameter kind " .. k)
  end
end

-- 2. the Branches panel: mining open with its agents; raiding locked until Tier 4
do
  local s = Sim.new()
  local m = BranchesView.model(s)
  assert(#m.rows == 2 and m.rows[2].id == "raiding" and m.rows[2].state == "locked")
  assert(m.rows[1].id == "mining" and m.rows[1].state == "open" and #m.rows[1].agents == 1 and m.rows[1].agents[1] == "miner")
  assert(m.used == 1 and m.capacity == s:commandCapacity())
  assert(s:openBranch("mining") == false and select(2, s:openBranch("mining")) == "already_open")
  assert(select(2, s:openBranch("nope")) == "unknown_branch")
  assert(BranchesView.signature(s) == BranchesView.signature(s))
end

-- 3. the acceptance test: a dummy branch with one tool, defined here only (no production file knows it)
local pinged = 0
local Dummy = {
  id = "dummy", name = "Dummy", scope = "dummy_scope",
  unlock = { tier = 2, cost = 1000, rep = 0, needs = nil },
  agent = { type = "scout", tools = { "ping", "report", "wait" }, startTier = 1, toolSlots = 3,
    stub = { optimal = function() return { name = "ping", args = {} } end, directive = function() return { name = "ping", args = {} } end } },
  asset = { type = "probe", label = "probe" },
  tools = { ping = { tier = 1,
    schema = { description = "Ping the void.", args = {} },
    validate = function() return true end,
    apply = function(sim, agentId) pinged += 1 return "pinged" end } },
  alerts = { kinds = { void_noise = {} } },
  paramKinds = { void = { check = function(sim, name, v) if v ~= "ok" then return name .. ": bad void" end end } },
  onOpen = function(sim) sim:addAgent("scout", "scout") end,
}
do
  local s = Sim.new({ branches = { Mining, Dummy } })
  assert(s.agents.scout == nil and not Registry.isOpen(s, "dummy"))
  local row = BranchesView.model(s).rows[2]
  assert(row.id == "dummy" and row.state == "locked" and row.note and not row.action, "locked at tier 1")
  assert(select(2, s:openBranch("dummy")) == "tier_locked")
  eq(Registry.scopes(s), { "company", "mining", "logistics" })

  s.tier = 2
  s.resources.credits = 500
  row = BranchesView.model(s).rows[2]
  assert(row.state == "available" and row.cost == 1000 and not row.action and row.note == "not enough credits")
  assert(select(2, s:openBranch("dummy")) == "not_enough_credits" and s.resources.credits == 500)

  s.resources.credits = 1500
  row = BranchesView.model(s).rows[2]
  assert(row.state == "available" and row.action == "branches.open.dummy")
  local handled, ok = BranchesView.act(s, row.action)
  assert(handled and ok and s.resources.credits == 500, "paid for the branch")
  assert(Registry.isOpen(s, "dummy") and s.agents.scout and s.agents.scout.tools.ping)
  row = BranchesView.model(s).rows[2]
  assert(row.state == "open" and row.agents[1] == "scout")
  assert(has(s.registry.alertTypes, "void_noise") and s.registry.alertGroup.void_noise == "dummy_scope")
  assert(s.registry.paramKinds.void and s.registry.paramKinds.void.branch == "dummy")

  -- its tool is validated, applied, and shown in the prompt schema; command capacity is shared
  assert(s:validate("scout", { name = "ping", args = {} }))
  assert(not s:validate("scout", { name = "mine", args = { vein = "k1" } }))
  assert(s:apply("scout", { name = "ping", args = {} }) and pinged == 1)
  assert(s.registry.schemas.ping and has(s.registry.toolOrder, "ping"))
  assert(#s.agentOrder == 2 and BranchesView.model(s).used == 2)

  -- Monitor scope per open branch
  eq(Registry.scopes(s), { "company", "mining", "dummy_scope", "logistics" })
  assert(s:setMonitorSettings({ scope = "dummy_scope" }))
  assert(s.monitorSettings.scope == "dummy_scope")

  -- a saved game keeps the open branches
  local data = Persistence.serialize(s, 0)
  local back = assert(Persistence.restore(data, { branches = { Mining, Dummy } }))
  assert(Registry.isOpen(back, "dummy") and back.agents.scout and #back.agentOrder == 2)
end

-- 4. the registry refuses a branch that collides with an existing one
do
  assert(not pcall(Sim.new, { branches = { Mining, Mining } }))
  local clash = { id = "x", name = "X", scope = "mining", unlock = { startsOpen = true } }
  assert(not pcall(Sim.new, { branches = { Mining, clash } }))
end

-- 5. with the default branches, only mining adds a Monitor scope until raiding is opened
do
  local s = Sim.new()
  eq(Registry.scopes(s), { "company", "mining", "logistics" })
  local m = AlertsView.model(s)
  assert(m.scope == "company")
end

print("branches OK")
