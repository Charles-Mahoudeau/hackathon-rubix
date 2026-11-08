-- Run from repo root: luau tests/test_copy.luau
-- GR5-92: alert, error, notification and unlock microcopy. Strings fit, and each one appears only when its event happened.
local Words = require("@scripts/config/copy")
local Copy = require("@scripts/sim/copy")
local Screens = require("@scripts/config/screens")
local Theme = require("@scripts/config/theme")
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Market = require("@scripts/sim/market")
local Model = require("@scripts/ui/shell_model")
local Shell = require("@scripts/ui/shell")
local Fit = require("@scripts/ui/fit")
local AlertsView = require("@scripts/ui/alerts_view")
local BranchesView = require("@scripts/ui/branches_view")
local Editor = require("@scripts/ui/agent_editor")

local function feedTexts(sim)
  local out = {}
  for _, e in ipairs(sim.feed) do out[#out + 1] = e.text end
  return out
end

local function count(sim, text)
  local n = 0
  for _, e in ipairs(sim.feed) do if e.text == text then n += 1 end end
  return n
end

-- 1. every static string fits the limit
do
  local checked = 0
  local function walk(t, path)
    for k, v in pairs(t) do
      if k ~= "prefix" and type(v) == "string" then
        assert(#v <= Words.maxChars, ("%s.%s is %d chars: %s"):format(path, tostring(k), #v, v))
        checked += 1
      elseif type(v) == "table" then walk(v, path .. "." .. tostring(k)) end
    end
  end
  walk(Words, "copy")
  for id, e in pairs(Screens.empty) do
    assert(#e.title <= Words.maxChars and #e.hint <= Words.maxChars or id ~= "alerts", "empty " .. id)
  end
  assert(checked > 60, "walked the copy: " .. checked)
end

-- 2. error codes: provider/invalid replies and ordinary failed actions read differently, unknown codes stay generic
do
  assert(Copy.error("unknown or disallowed tool: dig") == Words.errors.invalidCall)
  assert(Copy.error("tool not equipped: sell") == Words.errors.notEquipped)
  assert(Copy.error("warehouse_full") == "Warehouse full.")
  assert(Copy.error("bad qty") == Words.errors.invalidArgs)
  assert(Copy.error("something unforeseen") == Words.errors.failed)
  assert(Copy.error(nil) == Words.errors.failed)
  assert(Words.provider.failed ~= Words.provider.invalid and Words.provider.failed ~= Words.provider.timeout)
  assert(Copy.alert("agent_paused") == "Agent paused" and Copy.alert("not_a_kind") == "not_a_kind")
end

-- 3. unlock messages follow real events
do
  local s = Sim.new()
  assert(count(s, Words.unlocks.tier[1]) == 1, "T1 line at start")
  assert(count(s, Words.unlocks.tier[2]) == 0 and count(s, Words.unlocks.logistician) == 0 and count(s, Words.unlocks.monitor) == 0)
  s:enterTier(2)
  assert(count(s, Words.unlocks.tier[2]) == 1)
  s:enterTier(2)
  s:enterTier(1)
  assert(count(s, Words.unlocks.tier[2]) == 1 and count(s, Words.unlocks.tier[1]) == 1, "no repeat, no downgrade")

  -- a refused purchase says nothing
  s.resources.credits = 0
  assert(not s:buyUpgrade("hub") and count(s, Words.unlocks.logistician) == 0)
  s.tier = 4
  s.lifetimeRevenue = s.b.reputationLevels[2]
  s.resources.credits = 400000
  Market.quiet(s.market)
  assert(s:buyUpgrade("command_center"))
  assert(count(s, Words.unlocks.monitor) == 1 and count(s, Words.unlocks.tier[5]) == 1)

  -- a branch message only when the branch really opens
  local fresh = Sim.new()
  fresh.resources.credits = 0
  for _, def in ipairs(fresh.registry.list) do
    if def.id ~= "mining" then
      local ok = fresh:openBranch(def.id)
      assert(not ok and count(fresh, Words.unlocks.branch[def.id]) == 0, "refused open: " .. def.id)
    end
  end
  local before = #fresh.feed
  assert(count(fresh, Words.unlocks.branch.salvage) == 0 and before >= 1)
end

-- 4. pause reasons are the exact ones the sim decided
do
  local s = Sim.new()
  s:noteFailure("miner", "provider"); s:noteFailure("miner", "provider"); s:noteFailure("miner", "provider")
  assert(s.agents.miner.state == "paused_error" and s.agents.miner.blockReason == Words.pause.provider)
  assert(count(s, Words.pause.provider) == 1 and count(s, Words.pause.invalid) == 0)
  local t = Sim.new()
  t:noteFailure("miner", "invalid"); t:noteFailure("miner", "invalid")
  assert(t.agents.miner.blockReason == Words.pause.invalid)
  t.resources.compute = 0
  local u = Sim.new()
  u:setDecider(Ai.decide)
  u.resources.compute = 0
  u:run(50)
  assert(u.agents.miner.blockReason == Words.notEnoughCompute and count(u, Words.notEnoughCompute) == 1)
end

-- 5. the emergency notice exists only while the sim offers it
do
  local s = Sim.new()
  assert(Model.notification(s) == nil)
  s.offer = { kind = "emergency_advance" }
  local n = Model.notification(s)
  assert(n.text == Words.notice.emergency and n.button:find("^Claim %+%d"), n.button)
end

-- 6. the editor names which limit is exceeded
do
  local ok, over = { state = "ok" }, { state = "over" }
  assert(Editor.limitNote(ok, ok) == nil)
  assert(Editor.limitNote(over, ok) == Words.editor.directiveOver)
  assert(Editor.limitNote(ok, over) == Words.editor.orderOver)
  assert(Editor.limitNote(over, over) == Words.editor.directiveOver .. " " .. Words.editor.orderOver)
end

-- 7. Monitor and Branches screens at 1280x720: locked, available, unlocked and empty states, no clipping
do
  local view = Theme.layout.view
  local function lint(sim, screen, label)
    local spec = Shell.spec(sim, screen, {})
    local bad = Fit.check(spec, view)
    assert(#bad == 0, label .. ": " .. table.concat(bad, "\n"))
    return spec
  end
  local function texts(node, out)
    out = type(out) == "table" and out or {}
    if type(node) ~= "table" then return out end
    if type(node.text) == "table" and node.text.text then out[#out + 1] = node.text.text end
    if type(node.children) == "table" then
      for _, c in ipairs(node.children) do texts(c, out) end
    end
    return out
  end

  -- locked: no command center
  local s = Sim.new()
  s.tier = 5
  local m = AlertsView.model(s)
  assert(m.state == Words.states.locked and m.hireNote == Words.monitor.needsCommandCenter and m.emptyAlerts == Words.monitor.noAlerts)
  assert(m.emptyHistory == Words.monitor.noMonitor)
  lint(s, "alerts", "monitor locked")
  lint(s, "branches", "branches fresh")
  local b = BranchesView.model(s)
  assert(b.hint == Words.branches.hint, "hint while only mining is open")
  local joined = table.concat(texts((Shell.spec(s, "branches", {}))), "\n")
  assert(joined:find(Words.branches.noAgents, 1, true) and joined:find(Words.states.locked, 1, true) and joined:find("Active", 1, true), joined)

  -- unlocked: everything bought, every branch open, Monitor hired, alerts raised
  local f = Sim.new()
  f:setDecider(Ai.decide)
  f.tier = 4
  f.lifetimeRevenue = 1e9
  f.resources.credits, f.resources.compute = 5e6, 500
  Market.quiet(f.market)
  assert(f:buyUpgrade("command_center") and f:hireMonitor())
  local ids = {}
  for id in pairs(f.b.shop.items) do ids[#ids + 1] = id end
  table.sort(ids)
  for _ = 1, 3 do
    for _, id in ipairs(ids) do f:buyUpgrade(id) end
  end
  for _, def in ipairs(f.registry.list) do assert(f:openBranch(def.id) or def.id == "mining", def.id) end
  f:run(30)
  f:pauseAgent("miner", Words.pause.same)
  f:run(60)
  local am = AlertsView.model(f)
  assert(am.state == Words.states.open and am.hire == nil and #am.rows >= 1 and am.emptyAlerts == nil)
  assert(am.rows[1].label == Words.alerts.agent_paused, am.rows[1].label)
  assert(Words.pause.same == am.rows[1].reason, am.rows[1].reason)
  assert((am.emptyHistory == Words.monitor.noActions) == (#am.history == 0), "empty history words only when no Monitor action")
  local spec = lint(f, "alerts", "monitor unlocked")
  local all = table.concat(texts(spec), "\n")
  assert(all:find(Words.pause.same, 1, true) and all:find(Words.monitor.history, 1, true), all)
  lint(f, "branches", "branches all open")
  local opened = table.concat(texts((Shell.spec(f, "branches", {}))), "\n")
  local anyEmpty = false
  for _, row in ipairs(BranchesView.model(f).rows) do
    if row.state == "open" and #row.agents == 0 then anyEmpty = true end
  end
  assert(anyEmpty == (opened:find(Words.branches.noData, 1, true) ~= nil), "no-data words only for an open branch without agents")
  for _, row in ipairs(BranchesView.model(f).rows) do assert(not row.note or #row.note <= Words.maxChars, row.note) end
  for _, row in ipairs(BranchesView.model(s).rows) do assert(not row.note or #row.note <= Words.maxChars, row.note) end
  assert(BranchesView.model(f).hint == nil, "no hint once a branch is open")
  assert(Model.nav(5)[#Model.nav(5)].label ~= nil)
end

print("copy OK")
