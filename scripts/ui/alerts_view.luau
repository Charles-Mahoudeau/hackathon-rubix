-- Alerts screen (GR5-29, spec §8.7): the alert log, the Monitor's hire button and its settings (scope, heartbeat, which alert
-- types wake it). Pure reads of the sim; actions are "alerts.<verb>[.<arg>]".
local Alerts = require("@scripts/sim/alerts")
local Monitor = require("@scripts/sim/monitor")

local View = {}

local BLOCKER = {
  command_center_locked = "Buy the command center in the Shop first",
  command_capacity = "No free command slot",
}

local function nextOf(list, current)
  for i, v in ipairs(list) do
    if v == current then return list[i % #list + 1] end
  end
  return list[1]
end

function View.model(sim)
  local b, st = sim.b, sim.monitorSettings
  local hired = sim.agents.monitor ~= nil
  local hb = st.heartbeat
  local types = {}
  for _, t in ipairs(b.alerts.types) do
    types[#types + 1] = { type = t, on = st.alertTypes[t] == true, action = "alerts.type." .. t }
  end
  local blocker = Monitor.hireBlocker(sim)
  return {
    hired = hired,
    hire = (not hired and not blocker) and "alerts.hire" or nil,
    hireNote = (not hired and blocker) and (BLOCKER[blocker] or blocker) or nil,
    scope = st.scope, scopeAction = "alerts.scope",
    heartbeatText = hb and ("%d s"):format(hb) or "off",
    heartbeatActions = { down = "alerts.heartbeat.down", up = "alerts.heartbeat.up", off = "alerts.heartbeat.off" },
    types = types,
    rows = Alerts.rows(sim),
  }
end

function View.signature(sim)
  local parts = { tostring(sim.agents.monitor ~= nil), sim.monitorSettings.scope, tostring(sim.monitorSettings.heartbeat), tostring(#sim.alerts.list) }
  for _, t in ipairs(sim.b.alerts.types) do parts[#parts + 1] = tostring(sim.monitorSettings.alertTypes[t]) end
  for _, r in ipairs(Alerts.rows(sim)) do parts[#parts + 1] = r.id .. r.status end
  return table.concat(parts, ",")
end

-- -> handled, ok, err
function View.act(sim, action)
  if type(action) ~= "string" or action:sub(1, 7) ~= "alerts." then return false end
  local c = sim.b.monitor
  if action == "alerts.hire" then return true, sim:hireMonitor() end
  if action == "alerts.scope" then
    return true, sim:setMonitorSettings({ scope = nextOf(c.scopes, sim.monitorSettings.scope) })
  end
  local hb = sim.monitorSettings.heartbeat
  local h = c.heartbeat
  if action == "alerts.heartbeat.off" then
    local value = h.default
    if hb then value = false end
    return true, sim:setMonitorSettings({ heartbeat = value })
  end
  if action == "alerts.heartbeat.down" then return true, sim:setMonitorSettings({ heartbeat = (hb or h.default) - h.step }) end
  if action == "alerts.heartbeat.up" then return true, sim:setMonitorSettings({ heartbeat = (hb or h.default) + h.step }) end
  local t = action:match("^alerts%.type%.([%w_]+)$")
  if t and sim.monitorSettings.alertTypes[t] ~= nil then
    return true, sim:setMonitorSettings({ alertTypes = { [t] = not sim.monitorSettings.alertTypes[t] } })
  end
  return false
end

return View
