-- Monitor (spec §8.7, T5): the supervisor agent. It wakes on queued alerts or on its heartbeat, sees the team in one table
-- and acts through set_order / assign_skill / pause_agent / resume_agent. It never mines or sells itself.
-- Pure Luau, headless, no UI calls.
local Alerts = require("./alerts")
local Skills = require("./skills")
local Feed = require("./feed")
local Compute = require("./compute")
local DecisionLog = require("./decision_log")
local World = require("@scripts/config/world")
local Missions = require("./missions")
local Registry = require("./branches/registry")
local Monitor = {}

local function cfg(sim) return sim.b.monitor end

function Monitor.init(sim)
  local alertTypes = {}
  for _, t in ipairs(sim.registry.alertTypes) do alertTypes[t] = true end
  sim.monitorSettings = { scope = cfg(sim).defaultScope, heartbeat = cfg(sim).heartbeat.default, alertTypes = alertTypes }
end

function Monitor.agent(sim) return sim.agents.monitor end

-- Why the Monitor cannot be hired now (nil: it can).
function Monitor.hireBlocker(sim)
  if not sim.upgrades.commandCenter then return "command_center_locked" end
  if sim.agents.monitor then return "already_hired" end
  if #sim.agentOrder >= sim:commandCapacity() then return "command_capacity" end
  return nil
end

function Monitor.hire(sim)
  local why = Monitor.hireBlocker(sim)
  if why then
    sim:log("ERROR", "hire: cannot hire the Monitor (" .. why .. ")")
    return false, why
  end
  local agent = sim:addAgent("monitor", "monitor", { tier = sim.tier })
  Monitor.armHeartbeat(sim, agent)
  sim:log("INFO", "monitor: hired (empty directive)")
  sim:emit("agent_added", { agent = "monitor" })
  return true, "monitor"
end

function Monitor.armHeartbeat(sim, agent)
  local hb = sim.monitorSettings.heartbeat
  agent.nextHeartbeat = hb and (sim.tick + sim:ticks(hb)) or nil
end

-- changes: { scope = "company|mining|logistics", heartbeat = seconds | false, alertTypes = { type = bool } }
function Monitor.setSettings(sim, changes)
  local st, c = sim.monitorSettings, cfg(sim)
  if changes.scope ~= nil then
    local found = false
    for _, s in ipairs(Registry.scopes(sim)) do if s == changes.scope then found = true end end
    if not found then return false, "bad_scope" end
    st.scope = changes.scope
  end
  if changes.heartbeat ~= nil then
    local hb = changes.heartbeat
    if hb == false or hb == 0 then
      st.heartbeat = false
    elseif type(hb) == "number" then
      local h = c.heartbeat
      hb = math.max(h.min, math.min(h.max, math.floor(hb / h.step + 0.5) * h.step))
      st.heartbeat = hb
    else
      return false, "bad_heartbeat"
    end
    if sim.agents.monitor then Monitor.armHeartbeat(sim, sim.agents.monitor) end
  end
  for t, on in pairs(changes.alertTypes or {}) do
    if st.alertTypes[t] == nil then return false, "unknown_alert_type" end
    st.alertTypes[t] = on == true
  end
  return true
end

function Monitor.setLock(sim, agentId, locked)
  local agent = sim.agents[agentId]
  if not agent or agent.type == "monitor" then return false, "unknown_agent" end
  agent.monitorLock = locked == true
  return true
end

-- Woken by an alert in its queue, or by the heartbeat; with the heartbeat off and no alert it never decides.
function Monitor.needsDecision(sim, agent)
  if #Alerts.queue(sim) > 0 then return true end
  return agent.nextHeartbeat ~= nil and sim.tick >= agent.nextHeartbeat
end

-- A decision is sent: it takes the oldest queued alert and restarts the heartbeat.
function Monitor.onSend(sim, agent)
  Alerts.consume(sim)
  Monitor.armHeartbeat(sim, agent)
end

function Monitor.inScope(sim, target)
  local scope = sim.monitorSettings.scope
  return scope == "company" or sim.registry:scopeOfAgentType(target.type) == scope
end

local function skillAborted(agent) return agent.mode == "skill" and agent.skillRun ~= nil and agent.skillRun.aborted ~= nil end

function Monitor.validate(sim, agent, n, args)
  if n == "wait" or n == "report" then return true end
  local target = type(args.agent) == "string" and sim.agents[args.agent] or nil
  if not target or target.type == "monitor" then return false, "unknown_agent" end
  if not Monitor.inScope(sim, target) then return false, "out_of_scope" end
  if target.monitorLock then return false, "agent_locked" end
  if n == "set_order" then
    if type(args.text) ~= "string" then return false, "bad_args" end
    if Compute.estimateTokens(sim.compute.cfg, args.text) > sim.compute.cfg.editor.orderMaxTokens then return false, "too_long" end
  elseif n == "assign_skill" then
    local skill, err = Skills.canStart(sim, target.id, args.skill, args.params)
    if not skill then
      if err == "unknown_skill" and sim.skills[args.skill or ""] then err = "wrong_agent_type" end
      return false, err
    end
  elseif n == "pause_agent" then
    if target.state == "paused_error" then return false, "already_paused" end
  elseif n == "resume_agent" then
    if target.state ~= "paused_error" and not skillAborted(target) then return false, "not_paused" end
  end
  return true
end

-- A line in the target's own feed, tagged as coming from the Monitor.
local function tell(sim, targetId, text) Feed.info(sim, targetId, text, "monitor") end

function Monitor.apply(sim, agentId, call, rid)
  local args, n = call.args or {}, call.name
  local entry = Feed.begin(sim, agentId, call, sim:takeReasoning(), rid)
  if n == "wait" then
    Feed.finish(sim, entry, "waiting")
    return true
  end
  if n == "report" then
    sim:log("INFO", agentId .. " report: " .. tostring(args.message))
    Feed.finish(sim, entry, "sent")
    if args.to ~= nil and args.to ~= "player" then
      sim:deliver(args.to, ("from %s: %s"):format(agentId, tostring(args.message)))
    else
      Feed.info(sim, agentId, tostring(args.message))
    end
    return true
  end
  local target = sim.agents[args.agent]
  local result
  if n == "set_order" then
    sim:setOrder(target.id, args.text)
    target.orderSource = "monitor"
    -- an aborted skill does not read the order: hand the agent back to its AI
    if skillAborted(target) then Skills.stop(sim, target.id) end
    tell(sim, target.id, "order from the Monitor: " .. args.text)
    result = "order set"
  elseif n == "assign_skill" then
    Skills.assign(sim, target.id, args.skill, args.params)
    tell(sim, target.id, "the Monitor assigned skill " .. args.skill)
    result = "running " .. args.skill
  elseif n == "pause_agent" then
    target.pausedBy = "monitor"
    sim:pauseAgent(target.id, "paused by the Monitor")
    result = "paused"
  elseif n == "resume_agent" then
    if target.state == "paused_error" then
      sim:resumeAgent(target.id)
    else
      Skills.restart(sim, target.id)
    end
    tell(sim, target.id, "the Monitor resumed this agent")
    result = "resumed"
  end
  Feed.finish(sim, entry, ("%s: %s"):format(target.id, result))
  if n ~= "pause_agent" then Missions.onMonitorFix(sim, target.id) end
  sim:emit("monitor_action", { monitor = agentId, tool = n, agent = target.id })
  return true, { agent = target.id, result = result }
end

-- Number of decisions of `agentId` that ended in an error during the last 10 game minutes.
local function errors10m(sim, agentId)
  local from, n = sim.tick * sim.b.tickSeconds - 600, 0
  for _, rec in ipairs(sim.records[agentId] or {}) do
    if rec.t_game >= from and DecisionLog.isError(rec) then n += 1 end
  end
  return n
end

-- The agents table of the Monitor's context (spec §9.2.4), one row per supervised agent. Detached from the sim.
function Monitor.agentRows(sim)
  local rows = {}
  for _, id in ipairs(sim.agentOrder) do
    local a = sim.agents[id]
    if a.type ~= "monitor" and Monitor.inScope(sim, a) then
      local at
      if a.type == "miner" then
        local ship = sim:ownedShip(id)
        at = ship.vein and (ship.vein.id .. "@" .. ship.at) or ship.at
      elseif sim.registry.agentTypes[a.type] and sim.registry.agentTypes[a.type].at then
        at = sim.registry.agentTypes[a.type].at(sim, a)
      else
        at = a.station
      end
      local stats = DecisionLog.stats(sim, id)
      rows[#rows + 1] = { id = id, type = a.type, mode = a.mode == "skill" and ("skill:" .. tostring(a.activeSkill)) or "ai",
        params = a.mode == "skill" and a.skillParams or nil, state = a.state, at = at,
        net_h = math.floor(stats.net_per_hour + 0.5), compute_h = math.floor(stats.compute_per_hour * 10 + 0.5) / 10,
        err_10m = errors10m(sim, id), locked = a.monitorLock == true }
    end
  end
  return rows
end

-- Detached snapshot for the decider (stub or provider prompt checks).
function Monitor.context(sim)
  local alerts = {}
  for _, a in ipairs(Alerts.queue(sim)) do
    alerts[#alerts + 1] = { id = a.id, type = a.type, agent = a.agent, reason = a.reason, skill = a.skill, params = a.params,
      age_s = math.floor((sim.tick - a.tick) * sim.b.tickSeconds) }
  end
  local skills = {}
  for _, name in ipairs(Skills.names(sim)) do skills[#skills + 1] = { name = name, agent_type = sim.skills[name].agent_type } end
  local veins = {}
  for _, planetId in ipairs(World.planetOrder) do
    for _, v in ipairs(sim.planets[planetId].veins) do
      if (not v.hidden) or v.scanned then
        veins[#veins + 1] = { id = v.id, ore = v.ore, planet = v.planet, pct = v.scanned and math.floor(v.reserve * 100 / v.max) or nil }
      end
    end
  end
  return { tick = sim.tick, scope = sim.monitorSettings.scope, alerts = alerts, agents = Monitor.agentRows(sim),
    skills = skills, veins = veins, resources = { credits = sim.resources.credits, compute = sim.resources.compute } }
end

return Monitor
