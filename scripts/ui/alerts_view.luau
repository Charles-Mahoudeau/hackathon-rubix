-- Alerts screen (GR5-29, spec §8.7): the alert log, the Monitor's hire button and its settings (scope, heartbeat, which alert
-- types wake it). Pure reads of the sim; actions are "alerts.<verb>[.<arg>]".
local Alerts = require("@scripts/sim/alerts")
local Monitor = require("@scripts/sim/monitor")
local Registry = require("@scripts/sim/branches/registry")
local Copy = require("@scripts/sim/copy")
local Words = require("@scripts/config/copy")
local Screens = require("@scripts/config/screens")

local View = {}

local BLOCKER = {
  command_center_locked = Words.monitor.needsCommandCenter,
  command_capacity = Words.monitor.noCommandSlot,
}

-- The Monitor's own tool calls, newest first: what it did to which agent, and whether the sim accepted it.
local function history(monitor, limit)
  local out = {}
  if not monitor then return out end
  for i = #monitor.history, 1, -1 do
    local h = monitor.history[i]
    if h.tool ~= "wait" and h.tool ~= "report" then
      local line = ("%s %s"):format(h.tool, tostring(h.args and h.args.agent or "-"))
      out[#out + 1] = { text = line, ok = h.ok ~= false, error = h.ok == false and Copy.error(h.result and h.result.error) or nil }
      if #out >= limit then break end
    end
  end
  return out
end

local function nextOf(list, current)
  for i, v in ipairs(list) do
    if v == current then return list[i % #list + 1] end
  end
  return list[1]
end

function View.model(sim)
  local monitor = Monitor.agent(sim, sim.monitorSettings.scope)
  local st = monitor and monitor.monitorSettings or sim.monitorSettings
  local hired = monitor ~= nil
  local hb = st.heartbeat
  local types = {}
  for _, t in ipairs(sim.registry.alertTypes) do
    types[#types + 1] = { type = t, label = Copy.alert(t), on = st.alertTypes[t] == true, action = "alerts.type." .. t }
  end
  local blocker = Monitor.hireBlocker(sim)
  local rows = Alerts.rows(sim, monitor or false)
  for _, r in ipairs(rows) do r.label = Copy.alert(r.type) end
  local acts = history(monitor, Screens.alerts.historyRows)
  return {
    hired = hired,
    state = hired and Words.states.open or (blocker and Words.states.locked or Words.states.available),
    history = acts,
    emptyAlerts = #rows == 0 and Words.monitor.noAlerts or nil,
    emptyHistory = #acts == 0 and (hired and Words.monitor.noActions or Words.monitor.noMonitor) or nil,
    hire = (not hired and not blocker) and "alerts.hire" or nil,
    hireNote = (not hired and blocker) and (BLOCKER[blocker] or blocker) or nil,
    scope = sim.monitorSettings.scope, scopeAction = "alerts.scope",
    heartbeatText = hb and ("%d s"):format(hb) or "off",
    heartbeatActions = { down = "alerts.heartbeat.down", up = "alerts.heartbeat.up", off = "alerts.heartbeat.off" },
    types = types,
    rows = rows,
  }
end

function View.signature(sim)
  local monitor = Monitor.agent(sim, sim.monitorSettings.scope)
  local st = monitor and monitor.monitorSettings or sim.monitorSettings
  local parts = { tostring(monitor ~= nil), sim.monitorSettings.scope, tostring(st.heartbeat), tostring(#sim.alerts.list) }
  for _, t in ipairs(sim.registry.alertTypes) do parts[#parts + 1] = tostring(st.alertTypes[t]) end
  for _, r in ipairs(Alerts.rows(sim, monitor or false)) do parts[#parts + 1] = r.id .. r.status end
  parts[#parts + 1] = tostring(monitor and #monitor.history or 0) .. tostring(monitor and monitor.histSeq or 0)
  return table.concat(parts, ",")
end

-- -> handled, ok, err
function View.act(sim, action)
  if type(action) ~= "string" or action:sub(1, 7) ~= "alerts." then return false end
  local c = sim.b.monitor
  if action == "alerts.hire" then return true, sim:hireMonitor() end
  if action == "alerts.scope" then
    sim.monitorSettings.scope = nextOf(Registry.scopes(sim), sim.monitorSettings.scope)
    return true, true
  end
  local monitor = Monitor.agent(sim, sim.monitorSettings.scope)
  local st = monitor and monitor.monitorSettings or sim.monitorSettings
  local id = monitor and monitor.id
  local hb = st.heartbeat
  local h = c.heartbeat
  if action == "alerts.heartbeat.off" then
    local value = h.default
    if hb then value = false end
    return true, sim:setMonitorSettings({ heartbeat = value }, id)
  end
  if action == "alerts.heartbeat.down" then return true, sim:setMonitorSettings({ heartbeat = (hb or h.default) - h.step }, id) end
  if action == "alerts.heartbeat.up" then return true, sim:setMonitorSettings({ heartbeat = (hb or h.default) + h.step }, id) end
  local t = action:match("^alerts%.type%.([%w_]+)$")
  if t and st.alertTypes[t] ~= nil then
    return true, sim:setMonitorSettings({ alertTypes = { [t] = not st.alertTypes[t] } }, id)
  end
  return false
end

return View
