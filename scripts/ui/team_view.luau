-- Team view (GR5-28, spec §8.6): one row per agent with its asset, mode, state, Compute/h, net credits/h and the errors of
-- the last 10 game minutes. Pure reads of the sim; clicking a row opens that agent's editor ("team.open.<id>").
local DecisionLog = require("@scripts/sim/decision_log")
local Logistics = require("@scripts/sim/logistics")

local View = {}

local function round1(x) return math.floor(x * 10 + 0.5) / 10 end

local function errorsLast(sim, agentId, span)
  local from, n = sim.tick * sim.b.tickSeconds - span, 0
  for _, rec in ipairs(sim.records[agentId] or {}) do
    if rec.t_game >= from and DecisionLog.isError(rec) then n += 1 end
  end
  return n
end

-- What the agent runs: the ship it flies or the station it serves.
local function assetOf(sim, id, agent)
  if agent.type == "miner" then
    for _, sid in ipairs(sim.shipOrder) do
      if sim.ships[sid].owner == id then return sid end
    end
  elseif agent.type == "monitor" then
    return "command center (" .. agent.monitorSettings.scope .. ")"
  elseif agent.type == "logistician" then
    local st = sim.stations[agent.station]
    return st and Logistics.label(st) or agent.station
  end
  return "-"
end

-- "agent_idle 2 min ago" for the newest alert of an agent, "-" when it never had one.
local function lastAlert(sim, id)
  for i = #sim.alerts.list, 1, -1 do
    local a = sim.alerts.list[i]
    if a.agent == id then
      return ("%s %ds ago"):format(a.type, math.floor((sim.tick - a.tick) * sim.b.tickSeconds))
    end
  end
  return "-"
end

function View.model(sim)
  local span = sim.compute:span()
  local rows = {}
  for _, id in ipairs(sim.agentOrder) do
    local a = sim.agents[id]
    local stats = DecisionLog.stats(sim, id)
    rows[#rows + 1] = {
      id = id, type = a.type, asset = assetOf(sim, id, a),
      mode = a.mode == "skill" and (a.activeSkill or "skill") or "AI",
      state = a.state, computePerHour = round1(stats.compute_per_hour), netPerHour = math.floor(stats.net_per_hour + 0.5),
      errors = errorsLast(sim, id, span), lastAlert = lastAlert(sim, id), locked = a.monitorLock == true, action = "team.open." .. id,
    }
  end
  local idleShips = {}
  for _, sid in ipairs(sim.shipOrder) do
    if not sim.ships[sid].owner then
      idleShips[#idleShips + 1] = { id = sid, why = Logistics.idleReason(sim, "ship", sid) }
    end
  end
  return { rows = rows, idleShips = idleShips, used = #sim.agentOrder, capacity = sim:commandCapacity() }
end

function View.signature(sim)
  local parts = { tostring(#sim.agentOrder) }
  for _, id in ipairs(sim.agentOrder) do
    local a = sim.agents[id]
    parts[#parts + 1] = id .. a.state .. a.mode .. math.floor(sim.compute:agentRatePerHour(id) * 10) .. lastAlert(sim, id)
  end
  return table.concat(parts, ",")
end

-- "team.open.<id>" -> handled, agentId (nil when the agent does not exist).
function View.act(sim, action)
  if type(action) ~= "string" then return false end
  local id = action:match("^team%.open%.([%w_]+)$")
  if not id then return false end
  return true, sim.agents[id] and id or nil
end

return View
