-- Alerts (spec §8.7): sim events that may wake the Monitor. Every alert is kept for the Alerts panel; the ones the Monitor
-- listens to (its alert-type toggles, its scope) also sit in the queue until it handles them or they get too old.
-- Pure Luau, headless, no UI calls: the panel reads rows(), the sim only emits `alert_raised`.
local Logistics = require("./logistics")

local Alerts = {}

local function cfg(sim) return sim.b.alerts end

function Alerts.init(sim)
  sim.alerts = { seq = 0, list = {} }
  sim.alertTrack = { agents = {}, veins = {}, freighters = {}, stations = {} } -- edge detection state, rebuilt after a load
end

function Alerts.monitorOf(sim)
  for _, id in ipairs(sim.agentOrder) do
    if sim.agents[id].type == "monitor" then return sim.agents[id] end
  end
  return nil
end

local GROUP_OF_ALERT = { station_full = "logistics", freighter_idle = "logistics" }

local function groupOf(sim, kind, agentId)
  local agent = agentId and sim.agents[agentId]
  if agent then return sim.registry:scopeOfAgentType(agent.type) end
  return GROUP_OF_ALERT[kind] or sim.registry:groupOfAlert(kind)
end

local function paramsText(params)
  if type(params) ~= "table" then return nil end
  local keys = {}
  for k in pairs(params) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(params[k]) end
  return #parts > 0 and table.concat(parts, ",") or nil
end

function Alerts.inScope(sim, alert)
  local scope = sim.monitorSettings.scope
  return scope == "company" or alert.group == scope
end

-- `extra.skill` / `extra.params`: the skill that aborted and the parameter values it ran with.
function Alerts.raise(sim, kind, agentId, reason, extra)
  extra = extra or {}
  local st = sim.alerts
  st.seq += 1
  local monitor = Alerts.monitorOf(sim)
  local a = { id = st.seq, type = kind, agent = agentId, reason = reason or "", tick = sim.tick, group = groupOf(sim, kind, agentId),
    skill = extra.skill, params = paramsText(extra.params),
    queued = monitor ~= nil and sim.monitorSettings.alertTypes[kind] == true }
  st.list[#st.list + 1] = a
  if #st.list > cfg(sim).logMax then table.remove(st.list, 1) end
  sim:log("WARN", ("alert %s%s: %s"):format(kind, agentId and (" " .. agentId) or "", a.reason))
  sim:emit("alert_raised", { alert = a })
  return a
end

local function maxAgeTicks(sim) return sim:ticks(sim.b.monitor.queueMaxSeconds) end

-- The alerts the Monitor can still act on, oldest first.
function Alerts.queue(sim)
  local out, monitor = {}, Alerts.monitorOf(sim)
  if not monitor then return out end
  local oldest = sim.tick - maxAgeTicks(sim)
  for _, a in ipairs(sim.alerts.list) do
    if a.queued and not a.handled and a.tick >= oldest and Alerts.inScope(sim, a) then out[#out + 1] = a end
  end
  return out
end

-- The Monitor takes the oldest queued alert for the decision it just sent: one decision, one alert (spec §8.7).
function Alerts.consume(sim)
  local head = Alerts.queue(sim)[1]
  if head then head.handled = sim.tick end
  return head
end

function Alerts.status(sim, a)
  if a.handled then return "handled" end
  if not a.queued then return "unwatched" end
  if a.tick < sim.tick - maxAgeTicks(sim) then return "expired" end
  return "queued"
end

-- Panel rows, newest first.
function Alerts.rows(sim)
  local rows, dt = {}, sim.b.tickSeconds
  for i = #sim.alerts.list, 1, -1 do
    local a = sim.alerts.list[i]
    rows[#rows + 1] = { id = a.id, type = a.type, agent = a.agent, reason = a.reason, skill = a.skill, params = a.params,
      ageS = math.floor((sim.tick - a.tick) * dt), status = Alerts.status(sim, a) }
  end
  return rows
end

-- Net credits over the last `seconds`: sales credited to the agent minus its Compute at the Compute price.
local function netOver(sim, agentId, seconds)
  local now = sim.tick * sim.b.tickSeconds
  local from, earned, spent = now - seconds, 0, 0
  for _, e in ipairs(sim.earnings[agentId] or {}) do
    if e.t >= from then earned += e.amount end
  end
  for _, e in ipairs(sim.compute.spend) do
    if e.agent == agentId and e.t >= from then spent += e.cost end
  end
  return earned - spent * sim.aiConfig.compute.priceCredits, spent
end

local function stepAgents(sim, c, deep)
  local tr = sim.alertTrack.agents
  for _, id in ipairs(sim.agentOrder) do
    local agent = sim.agents[id]
    if agent.type ~= "monitor" then
      local t = tr[id]
      if not t then
        t = { state = agent.state, since = sim.tick, born = sim.tick }
        tr[id] = t
      end
      if agent.state ~= t.state then
        if agent.state == "paused_error" and agent.pausedBy ~= "monitor" then
          Alerts.raise(sim, "agent_paused", id, agent.blockReason or "paused")
        elseif agent.state == "no_compute" then
          Alerts.raise(sim, "no_compute", id, agent.blockReason or "no Compute")
        end
        t.state, t.since, t.idleRaised = agent.state, sim.tick, false
      end
      if agent.state == "idle" and not t.idleRaised and sim.tick - t.since >= sim:ticks(c.idleSeconds) then
        t.idleRaised = true
        Alerts.raise(sim, "agent_idle", id, ("idle for %d s"):format(c.idleSeconds))
      end
      if deep and sim.tick - t.born >= sim:ticks(c.losingMoneySeconds) then
        local net = netOver(sim, id, c.losingMoneySeconds)
        if net < 0 and not t.losingRaised then
          t.losingRaised = true
          Alerts.raise(sim, "losing_money", id, ("net %d cr over %d s"):format(math.floor(net), c.losingMoneySeconds))
        elseif net >= 0 then
          t.losingRaised = false
        end
      end
    end
  end
end

-- Detection that belongs to a branch (crowding: mining) runs from the branch's own `alerts.detect`.
local function stepBranches(sim, c)
  for _, def in ipairs(sim.registry.list) do
    if def.alerts and def.alerts.detect and sim.branchesOpen[def.id] then def.alerts.detect(sim, c, Alerts.raise) end
  end
end

local function stepStations(sim, c)
  local tr = sim.alertTrack.stations
  for _, sid in ipairs(sim.stationOrder) do
    local st = sim.stations[sid]
    local pct = 100 * Logistics.used(st) / Logistics.storageCap(sim, st)
    if pct > c.stationFullPct then
      if not tr[sid] then
        tr[sid] = true
        Alerts.raise(sim, "station_full", Logistics.logisticiansAt(sim, sid)[1], ("%s at %d%%"):format(Logistics.label(st), math.floor(pct)))
      end
    else
      tr[sid] = nil
    end
  end
end

local function stepFreighters(sim, c)
  local tr = sim.alertTrack.freighters
  for _, f in ipairs(sim.freighters) do
    if f.state == "idle" then
      local t = tr[f.id]
      if not t then t = { since = sim.tick }; tr[f.id] = t end
      if not t.raised and sim.tick - t.since >= sim:ticks(c.freighterIdleSeconds) then
        t.raised = true
        Alerts.raise(sim, "freighter_idle", nil, ("%s docked at %s for %d s"):format(f.id, f.station, c.freighterIdleSeconds))
      end
    else
      tr[f.id] = nil
    end
  end
end

-- Once per checkSeconds of game time (the Monitor does not run offline, so neither do alerts).
function Alerts.step(sim)
  if sim.offline then return end
  local c = cfg(sim)
  local every = sim:ticks(c.checkSeconds)
  if sim.tick % every ~= 0 then return end
  stepAgents(sim, c, sim.tick % (every * 10) == 0)
  stepBranches(sim, c)
  stepStations(sim, c)
  stepFreighters(sim, c)
end

return Alerts
