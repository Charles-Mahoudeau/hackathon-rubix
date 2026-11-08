-- Run from repo root: luau tests/test_monitor.luau
-- GR5-29 (M7c): command center, alerts, the Monitor agent and its tools, the lock, the heartbeat, mission 8.
local Sim = require("@scripts/sim/sim")
local Skills = require("@scripts/sim/skills")
local Market = require("@scripts/sim/market")
local Alerts = require("@scripts/sim/alerts")
local Ai = require("@scripts/sim/ai")

-- A T4 company with Rep 2 and two Miners; the command center is not bought yet.
local function ready()
  local s = Sim.new()
  s.tier = 4
  for _, a in pairs(s.agents) do a.tier = 4 end
  s.lifetimeRevenue = s.b.reputationLevels[2]
  s.resources.credits = 250000
  s.resources.compute = 200
  Market.quiet(s.market)
  s:setDecider(Ai.decide)
  return s
end

local function cobaltLoop(s)
  assert(Skills.save(s, { name = "Titanium loop", agent_type = "miner", loop = true,
    params = { vein = { kind = "vein", filter = { resource = "titanium" } } },
    steps = { { tool = "mine", args = { vein = "$vein" } }, { tool = "return" }, { tool = "sell" } } }))
end

local function withMonitor()
  local s = ready()
  cobaltLoop(s)
  assert(s:buyUpgrade("command_center"))
  assert(s:hireMonitor())
  return s
end

local function eventsOf(s, name)
  local n = 0
  for _, e in ipairs(s:drainEvents()) do if e.name == name then n += 1 end end
  return n
end

-- 1. the command center enters T5 and unlocks the Monitor
do
  local s = ready()
  s.resources.credits = 100
  assert(select(2, s:buyUpgrade("command_center")) == "not_enough_credits")
  assert(select(2, s:hireMonitor()) == "command_center_locked")
  s.resources.credits = 250000
  assert(s:buyUpgrade("command_center") and s.tier == 5 and s.agents.miner.tier == 5, "T5")
  local ok, id = s:hireMonitor()
  assert(ok and id == "monitor" and s.agents.monitor.type == "monitor")
  assert(select(2, s:hireMonitor()) == "already_hired")
  local tools = s:equippedTools("monitor")
  assert(table.concat(tools, ",") == "report,wait,set_order,assign_skill,pause_agent,resume_agent", table.concat(tools, ","))
end

-- 2. a precise Monitor directive rotates a depleted $vein and the agent resumes within 120 s
do
  local s = withMonitor()
  s.agents.monitor.directive = "When a skill aborts, assign it the next vein."
  assert(s:setMonitorSettings({ heartbeat = false }))
  assert(s:apply("miner", { name = "run_skill", args = { name = "Titanium loop", params = { vein = "K1" } } }))
  s:run(200)
  assert(s.agents.miner.mode == "skill" and s.agents.miner.state == "acting")
  s:drainEvents()
  -- the vein stays dry until the loop notices (the reserve regrows slowly on its own)
  local t0, resumed
  for _ = 1, 6000 do
    if not t0 then s.veins.K1.reserve = 0 end
    s:step()
    if not t0 and #s.alerts.list > 0 then t0 = s.alerts.list[1].tick end
    local m = s.agents.miner
    if t0 and m.skillParams and m.skillParams.vein ~= "K1" and m.state == "acting" then resumed = s.tick; break end
  end
  assert(t0, "the skill aborted on the dry vein")
  assert(resumed, "the Monitor rotated the vein")
  assert((resumed - t0) * s.b.tickSeconds <= 120, "within 120 s: " .. (resumed - t0) * s.b.tickSeconds)
  local rows = Alerts.rows(s)
  assert(rows[1].type == "skill_aborted" and rows[1].agent == "miner" and rows[1].reason == "vein_depleted" and rows[1].status == "handled")
  local tagged = false
  for _, e in ipairs(s.feed) do if e.source == "monitor" and e.agent == "miner" then tagged = true end end
  assert(tagged, "the target's feed shows the Monitor's action")
end

-- 3. heartbeat off and no alert: the Monitor never decides
do
  local s = withMonitor()
  assert(s:setMonitorSettings({ heartbeat = false }))
  s:run(s.b.monitor.heartbeat.max * 10 * 3)
  assert(#(s.records.monitor or {}) == 0, "no decision")
  assert((s.compute.lifetime.monitor or 0) == 0, "no Compute")
  -- with the heartbeat on, it wakes on its own
  assert(s:setMonitorSettings({ heartbeat = 60 }))
  s:run(1500)
  assert(#(s.records.monitor or {}) >= 1, "heartbeat decision")
end

-- 4. locked agents are never touched
do
  local s = withMonitor()
  s.agents.monitor.directive = "Resume it."
  assert(s:setMonitorLock("miner", true))
  assert(s.agents.miner.monitorLock)
  local ok, err = s:apply("monitor", { name = "set_order", args = { agent = "miner", text = "do it" } })
  assert(not ok and err == "agent_locked")
  ok, err = s:apply("monitor", { name = "pause_agent", args = { agent = "miner" } })
  assert(not ok and err == "agent_locked")
  ok, err = s:apply("monitor", { name = "assign_skill", args = { agent = "miner", skill = "Titanium loop", params = { vein = "K1" } } })
  assert(not ok and err == "agent_locked")
  assert(s.agents.miner.order == "" and s.agents.miner.state ~= "paused_error" and s.agents.miner.mode == "ai")
  s:pauseAgent("miner", "test")
  s:run(3000)
  assert(s.agents.miner.state == "paused_error", "stays paused: the Monitor may not resume it")
  assert(select(2, s:apply("monitor", { name = "resume_agent", args = { agent = "miner" } })) == "agent_locked")
  assert(s:setMonitorLock("miner", false))
  assert(s:apply("monitor", { name = "resume_agent", args = { agent = "miner" } }))
  assert(s.agents.miner.state == "idle")
end

-- 5. mission 8: the Monitor resolves 3 alerts within budget
do
  local Missions = require("@scripts/sim/missions")
  local s = withMonitor()
  for i = 1, 7 do s.missions[i].status = "claimed" end
  assert(s:setMonitorSettings({ heartbeat = false }))
  s.agents.monitor.directive = "When an agent is paused, resume it."
  s:run(100) -- the alert tracker sees the agent before it is paused
  local e = s.missions[8]
  assert(e and e.status == "active", "mission 8 opens once the command center is built: " .. tostring(e and e.status))
  for round = 1, 3 do
    assert(e.status == "active" and e.resolved == round - 1)
    s:run(30) -- let the tracker see the agent acting again
    s:pauseAgent("miner", "test")
    for _ = 1, 1500 do
      s:step()
      if e.resolved >= round or e.status == "complete" then break end
    end
    assert(e.resolved >= round or e.status == "complete", "alert " .. round .. " resolved")
  end
  s:step()
  assert(e.status == "complete", "mission 8 done: " .. e.status)
  local before = s.resources.credits
  assert(Missions.claim(s, 8))
  assert(s.resources.credits == before + 5000)
  -- a Monitor that burns too much Compute fails the mission
  local f = withMonitor()
  for i = 1, 7 do f.missions[i].status = "claimed" end
  f:step()
  f.compute.lifetime.monitor = 11
  f:step()
  assert(f.missions[8].failed, "over the Compute budget")
end

-- 6. alerts, Monitor settings and locks survive a save
do
  local Persistence = require("@scripts/sim/persistence")
  local s = withMonitor()
  local m = s.market -- JSON cannot hold the infinite "never" of Market.quiet
  m.nextTrend, m.nextRival = 1e9, 1e9
  for _, mk in pairs(m.markets) do mk.nextEvent = 1e9 end
  s.agents.monitor.directive = "x"
  assert(s:setMonitorSettings({ scope = "mining", heartbeat = 120, alertTypes = { agent_idle = false } }))
  assert(s:setMonitorLock("miner", true))
  s:run(100)
  s:pauseAgent("miner", "test")
  s:run(30)
  assert(#s.alerts.list == 1)
  local st = Persistence.memoryStorage()
  assert(Persistence.save(s, st, "a", 0))
  local r = assert(Persistence.load(st, "a"))
  assert(#r.alerts.list == 1 and r.alerts.seq == s.alerts.seq and r.alerts.list[1].type == "agent_paused")
  local ms = r.monitorSettings
  assert(ms.scope == "mining" and ms.heartbeat == 120 and ms.alertTypes.agent_idle == false and ms.alertTypes.crowding == true)
  assert(r.agents.monitor and r.agents.miner.monitorLock == true and r.upgrades.commandCenter == true)
  assert(Alerts.rows(r)[1].status == Alerts.rows(s)[1].status)
  -- an old save without alerts keeps the defaults
  local old = Persistence.serialize(s, 0)
  old.state.alerts, old.state.monitorSettings = nil, nil
  local o = assert(Persistence.restore(old))
  assert(#o.alerts.list == 0 and o.monitorSettings.scope == "company" and o.monitorSettings.heartbeat == 300)
end

-- 7. the Alerts screen, the team row and the editor lock
do
  local AlertsView = require("@scripts/ui/alerts_view")
  local TeamView = require("@scripts/ui/team_view")
  local Editor = require("@scripts/ui/agent_editor")
  local Shell = require("@scripts/ui/shell")
  local function texts(node, out)
    out = out or {}
    if node.text and node.text.text then out[#out + 1] = node.text.text end
    for _, c in ipairs(node.children or {}) do texts(c, out) end
    return out
  end
  local s = ready()
  assert(not AlertsView.model(s).hire and AlertsView.model(s).hireNote:find("command center", 1, true))
  assert(s:buyUpgrade("command_center"))
  assert(AlertsView.model(s).hire == "alerts.hire")
  assert(AlertsView.act(s, "alerts.hire") and s.agents.monitor)
  assert(AlertsView.act(s, "alerts.scope") and s.monitorSettings.scope == "mining")
  assert(AlertsView.act(s, "alerts.heartbeat.off") and s.monitorSettings.heartbeat == false)
  assert(AlertsView.act(s, "alerts.heartbeat.off") and s.monitorSettings.heartbeat == 300)
  assert(AlertsView.act(s, "alerts.heartbeat.down") and s.monitorSettings.heartbeat == 240)
  assert(AlertsView.act(s, "alerts.type.crowding") and s.monitorSettings.alertTypes.crowding == false)
  assert(not AlertsView.act(s, "alerts.type.nonsense") and not AlertsView.act(s, "shop.buy"))
  s:run(100)
  s:pauseAgent("miner", "test")
  s:run(30)
  local m = AlertsView.model(s)
  assert(#m.rows == 1 and m.rows[1].type == "agent_paused")
  local spec = Shell.spec(s, "alerts", {})
  local all = table.concat(texts(spec), "\n")
  assert(all:find("Agent paused", 1, true) and all:find("Heartbeat 240 s", 1, true) and all:find("[ ] Vein crowded", 1, true), all)
  local team = TeamView.model(s)
  assert(team.rows[1].lastAlert:find("agent_paused", 1, true) and team.rows[2].lastAlert == "-" and team.rows[2].asset == "command center")
  assert(Shell.spec(s, "team", {}))
  -- the editor: a lock toggle for supervised agents only, and where the order came from
  assert(Editor.model(s, "miner").lock.locked == false and Editor.model(s, "monitor").lock == nil)
  s:setOrder("miner", "go")
  s.agents.miner.orderSource = "monitor"
  assert(Editor.model(s, "miner").orderSource == "monitor")
  require("@scripts/config/screens").editor.agent = "monitor"
  assert(Shell.spec(s, "agents", {}), "the Monitor has an editor")
  require("@scripts/config/screens").editor.agent = "miner"
end

-- 8. the Monitor context renders as spec 9.2.4 (a whole number has no ".0", like every other context), and compact is smaller than JSON
do
  local Builder = require("@scripts/sim/context_builder")
  local Renderer = require("@scripts/sim/context_renderer")
  local s = withMonitor()
  s.tick = 67500 -- 01:52:30
  s.resources.credits, s.resources.compute = 48210, 62.0
  s.skills = { ["Cobalt loop"] = { name = "Cobalt loop", agent_type = "miner", params = { vein = { kind = "vein", filter = { resource = "cobalt" } } } } }
  s.context = function()
    return {
      alerts = { { id = 1, type = "skill_aborted", agent = "miner_2", reason = "vein_depleted", skill = "Cobalt loop", params = "vein=V1", age_s = 12 } },
      agents = {
        { id = "miner_1", type = "miner", mode = "skill:Cobalt loop", params = { vein = "V2" }, state = "acting", at = "V2@varn", net_h = 41200, compute_h = 0, err_10m = 0, locked = false },
        { id = "miner_2", type = "miner", mode = "ai", state = "idle", at = "V1@varn", net_h = 18000, compute_h = 6.5, err_10m = 1, locked = false },
      },
      skills = { { name = "Cobalt loop", agent_type = "miner" } },
      veins = { { id = "V1", ore = "cobalt", pct = 0 }, { id = "V2", ore = "cobalt", pct = 71 } },
    }
  end
  local settings = Sim.deepCopy(s.agents.monitor.contextSettings)
  local data = Builder.build(s, "monitor", settings)
  local golden = [[
time: 01:52:30
alerts[1] type agent reason skill params age_s
skill_aborted miner_2 vein_depleted "Cobalt loop" vein=V1 12
agents[2] id type mode params state at net_h compute_h err_10m locked
miner_1 miner "skill:Cobalt loop" vein=V2 acting V2@varn 41200 0 0 n
miner_2 miner ai - idle V1@varn 18000 6.5 1 n
skills[1] name type params
"Cobalt loop" miner vein:cobalt
veins[2] id res res%
V1 cobalt 0
V2 cobalt 71
credits: 48210
compute: 62]]
  assert(Renderer.compact(data) == golden, Renderer.compact(data))
  assert(#Renderer.compact(data) < #Renderer.json(data), "compact is smaller")
end

print("monitor OK")
