-- Missions panel view-model (GR5-9, spec §15): the current mission with its brief lines, hint, progress bar and a Claim button,
-- then every mission in order. Pure reads and sim calls, so the whole path is testable headless; the shell only lays it out.
local Missions = require("@scripts/sim/missions")
local Config = require("@scripts/config/missions")
local Raiding = require("@scripts/sim/raiding")
local Refining = require("@scripts/sim/refining")
local Salvage = require("@scripts/sim/salvage")

local View = {}

local function rewardText(r)
  local parts = {}
  if r.credits then parts[#parts + 1] = ("%d cr"):format(r.credits) end
  if r.compute then parts[#parts + 1] = ("%d Compute"):format(r.compute) end
  if r.archiveSlot then parts[#parts + 1] = ("+%d Archive slot"):format(r.archiveSlot) end
  if r.freighter then parts[#parts + 1] = ("+%d freighter"):format(r.freighter) end
  if r.blueprint then parts[#parts + 1] = ("%d blueprint"):format(r.blueprint) end
  return table.concat(parts, " + ")
end

-- The currencies a reward pays, as icon keys (credits, Compute), for the icons drawn before the reward text.
local function rewardIcons(r)
  local out = {}
  if r.credits then out[#out + 1] = "resource.credits" end
  if r.compute then out[#out + 1] = "resource.compute" end
  return out
end

function View.new() return { selected = nil } end

function View.model(sim, view)
  local cur, def, index = Missions.current(sim)
  local rows = {}
  for i, e in ipairs(sim.missions) do
    local d = Missions.def(e.id)
    local state = e.status == "claimed" and "claimed" or e.status
    rows[#rows + 1] = { id = e.id, name = ("%d. %s"):format(i, d.name), state = state, reward = rewardText(d.reward), icons = rewardIcons(d.reward), action = "missions.select." .. e.id }
  end
  local out = { rows = rows, total = #Config.missions, allDone = cur == nil, optional = {} }
  -- The raiding branch's own mission (spec §15b.5, V3): optional, listed under the main path once the first interceptor is owned.
  if Raiding.isOpen(sim) then
    local v = Raiding.mission(sim)
    local state = v.status == "claimed" and "claimed" or (v.status == "locked" and "locked" or "current")
    local progress = v.failed and "Failed" or ("%d / %d wins"):format(v.wins, v.target)
    out.optional[#out.optional + 1] = { id = v.id, name = v.name .. " (optional)", state = state, reward = rewardText({ credits = v.reward }), icons = rewardIcons({ credits = v.reward }),
      brief = v.brief, hint = v.hint, progressText = progress, failed = v.failed,
      claim = v.status == "complete" and ("missions.claim." .. v.id) or nil,
      retry = (v.status == "active" and v.failed) and ("missions.retry." .. v.id) or nil }
  end
  -- The refining branch's mission (spec §15b.5, V1): optional, listed once the refinery stands.
  if Refining.isOpen(sim) then
    local v = Refining.mission(sim)
    local state = v.status == "claimed" and "claimed" or (v.status == "locked" and "locked" or "current")
    out.optional[#out.optional + 1] = { id = v.id, name = v.name .. " (optional)", state = state, reward = rewardText({ credits = v.reward }), icons = rewardIcons({ credits = v.reward }),
      brief = v.brief, progressText = ("%d / %d units"):format(math.min(v.units, v.target), v.target), hint = v.hint,
      claim = v.status == "complete" and ("missions.claim." .. v.id) or nil }
  end
  -- The salvage branch's mission (spec §15b.5, V2): optional, listed once the first salvage ship is owned.
  if Salvage.isOpen(sim) then
    local v = Salvage.mission(sim)
    local state = v.status == "claimed" and "claimed" or (v.status == "locked" and "locked" or "current")
    out.optional[#out.optional + 1] = { id = v.id, name = v.name .. " (optional)", state = state, reward = rewardText({ blueprint = 1 }), icons = {},
      brief = v.brief, hint = v.hint, progressText = v.status == "active" and "not yet" or "done",
      claim = v.status == "complete" and ("missions.claim." .. v.id) or nil }
  end
  for _, row in ipairs(out.optional) do
    row.action = "missions.select." .. row.id
    rows[#rows + 1] = row
    if view and view.selected == row.id then
      out.current = { id = row.id, name = row.name, brief = row.brief, hint = row.hint,
        status = row.state, progressText = row.progressText, lines = {}, rewardText = "Reward: " .. row.reward,
        rewardIcons = row.icons, claim = row.claim, retry = row.retry, locked = row.state == "locked" }
    end
  end
  if out.current then return out end
  if view and view.selected then
    for i, e in ipairs(sim.missions) do
      if e.id == view.selected then cur, def, index = e, Missions.def(e.id), i; break end
    end
  end
  if not cur then return out end
  local p = Missions.progress(sim, cur)
  if cur.status == "locked" and index > 1 and sim.missions[index - 1].status ~= "claimed" then
    p.text = "Claim the previous mission"
  end
  out.current = {
    id = def.id, index = index, name = def.name, brief = def.brief, hint = def.hint, status = cur.status,
    fraction = p.fraction, percent = math.floor(p.fraction * 100), progressText = p.text, lines = p.lines,
    rewardText = "Reward: " .. rewardText(def.reward), rewardIcons = rewardIcons(def.reward),
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
  if Raiding.isOpen(sim) then
    local v = Raiding.mission(sim)
    parts[#parts + 1] = v.id .. v.status .. v.wins .. tostring(v.failed)
  end
  if Refining.isOpen(sim) then
    local v = Refining.mission(sim)
    parts[#parts + 1] = v.id .. v.status .. v.units
  end
  if Salvage.isOpen(sim) then parts[#parts + 1] = "V2" .. Salvage.mission(sim).status end
  return table.concat(parts, ",")
end

-- "missions.claim.<id>" / "missions.retry.<id>" -> handled, ok, err.
function View.act(sim, action, view)
  if type(action) ~= "string" then return false end
  local selected = action:match("^missions%.select%.([%w]+)$")
  if selected and view then view.selected = tonumber(selected) or selected; return true end
  local rverb, rid = action:match("^missions%.(%a+)%.(V%d+)$")
  if rid == Refining.mission(sim).id then
    if rverb == "claim" then return true, Refining.claimMission(sim) end
    return false
  end
  if rid == Salvage.mission(sim).id then
    if rverb == "claim" then return true, Salvage.claimMission(sim) end
    return false
  end
  if rid == Raiding.mission(sim).id then
    if rverb == "claim" then return true, Raiding.claimMission(sim) end
    if rverb == "retry" then return true, Raiding.retryMission(sim) end
  end
  local verb, id = action:match("^missions%.(%a+)%.(%d+)$")
  if verb == "claim" then return true, Missions.claim(sim, tonumber(id)) end
  if verb == "retry" then return true, Missions.retry(sim, tonumber(id)) end
  return false
end

return View
