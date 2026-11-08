-- Missions panel view-model (GR5-9, spec §15): the current mission with its goal, hint, progress bar and a Claim button,
-- then every mission in order. Pure reads and sim calls, so the whole path is testable headless; the shell only lays it out.
local Missions = require("@scripts/sim/missions")
local Config = require("@scripts/config/missions")

local View = {}

local function rewardText(r)
  local parts = {}
  if r.credits then parts[#parts + 1] = ("%d cr"):format(r.credits) end
  if r.compute then parts[#parts + 1] = ("%d Compute"):format(r.compute) end
  if r.archiveSlot then parts[#parts + 1] = ("+%d Archive slot"):format(r.archiveSlot) end
  if r.freighter then parts[#parts + 1] = ("+%d freighter"):format(r.freighter) end
  return table.concat(parts, " + ")
end

function View.model(sim)
  local cur, def, index = Missions.current(sim)
  local rows = {}
  for i, e in ipairs(sim.missions) do
    local d = Missions.def(e.id)
    local state = e.status == "claimed" and "claimed" or (e == cur and "current" or "locked")
    rows[#rows + 1] = { id = e.id, name = ("%d. %s"):format(i, d.name), state = state, reward = rewardText(d.reward) }
  end
  local out = { rows = rows, total = #Config.missions, allDone = cur == nil }
  if not cur then return out end
  local p = Missions.progress(sim, cur)
  out.current = {
    id = def.id, index = index, name = def.name, goal = def.goal, hint = def.hint, status = cur.status,
    fraction = p.fraction, percent = math.floor(p.fraction * 100), progressText = p.text, lines = p.lines,
    rewardText = "Reward: " .. rewardText(def.reward),
    claim = cur.status == "complete" and ("missions.claim." .. def.id) or nil,
    retry = (cur.status == "active" and p.failed) and ("missions.retry." .. def.id) or nil,
    locked = cur.status == "locked",
  }
  return out
end

-- One string that changes when what the panel shows changes.
function View.signature(sim)
  local parts = {}
  for _, e in ipairs(sim.missions) do
    local p = Missions.progress(sim, e)
    parts[#parts + 1] = e.id .. e.status .. p.text
  end
  return table.concat(parts, ",")
end

-- "missions.claim.<id>" / "missions.retry.<id>" -> handled, ok, err.
function View.act(sim, action)
  if type(action) ~= "string" then return false end
  local verb, id = action:match("^missions%.(%a+)%.(%d+)$")
  if verb == "claim" then return true, Missions.claim(sim, tonumber(id)) end
  if verb == "retry" then return true, Missions.retry(sim, tonumber(id)) end
  return false
end

return View
