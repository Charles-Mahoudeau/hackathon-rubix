-- Offline progression (spec §14, D12): on load the game simulates the time the player was away, headless, at most
-- balance.offline.maxHours. Only skill-mode agents work (and the markets, rivals, regen and freighters run); AI-mode
-- agents and the Monitor do nothing, no AI is called and no Compute is spent. A skill that aborts stays aborted.
local Offline = {}

-- Game seconds that will be simulated for an absence of `awaySeconds` real seconds (0 = ignored). -> seconds, capped
function Offline.simulated(sim, awaySeconds)
  local cfg = sim.b.offline
  if type(awaySeconds) ~= "number" or awaySeconds ~= awaySeconds or awaySeconds < cfg.minAwaySeconds then return 0, false end
  local cap = cfg.maxHours * 3600
  if awaySeconds > cap then return cap, true end
  return awaySeconds, false
end

-- Simulates the absence and returns the "While you were away" report (nil when the absence is ignored).
-- { away_seconds, simulated_seconds, capped, credits, units, agents = { { id, mode, credits, units } }, aborted = { { agent, skill, reason, at } } }
function Offline.run(sim, awaySeconds)
  local seconds, capped = Offline.simulated(sim, awaySeconds)
  if seconds <= 0 then return nil end
  local decide, provider = sim.decide, sim.provider
  local startCredits = sim.resources.credits
  sim.decide, sim.provider, sim.offline = nil, nil, true
  sim.tally = { credits = {}, units = {}, aborted = {}, startTick = sim.tick }
  local ticks = math.floor(seconds / sim.b.tickSeconds + 0.5)
  local ok, err = pcall(function() for _ = 1, ticks do sim:step() end end)
  local tally = sim.tally
  sim.decide, sim.provider, sim.offline, sim.tally = decide, provider, nil, nil
  if not ok then error(err, 0) end
  local report = { away_seconds = awaySeconds, simulated_seconds = seconds, capped = capped,
    credits = sim.resources.credits - startCredits, units = 0, agents = {}, aborted = tally.aborted }
  for _, id in ipairs(sim.agentOrder) do
    local agent = sim.agents[id]
    local units = math.floor((tally.units[id] or 0) + 1e-9)
    report.units += units
    report.agents[#report.agents + 1] = { id = id, mode = agent.mode, skill = agent.activeSkill,
      credits = tally.credits[id] or 0, units = units }
  end
  sim:log("INFO", ("offline: %d s simulated, %+d cr"):format(seconds, report.credits))
  sim:emit("offline_report", report)
  sim.lastOfflineReport = report
  return report
end

-- Text lines for the "While you were away" panel (no layout here: the shell draws them).
function Offline.lines(report)
  local function dur(s)
    local h, m = math.floor(s / 3600), math.floor(s % 3600 / 60)
    if h > 0 then return ("%d h %02d min"):format(h, m) end
    return ("%d min"):format(m)
  end
  local out = { ("Away %s%s"):format(dur(report.simulated_seconds), report.capped and " (capped)" or "") }
  out[#out + 1] = ("%+d cr, %d units mined"):format(report.credits, report.units)
  for _, a in ipairs(report.agents) do
    if a.mode == "skill" then out[#out + 1] = ("%s (%s): %+d cr, %d units"):format(a.id, a.skill or "skill", a.credits, a.units) end
  end
  for _, ab in ipairs(report.aborted) do
    out[#out + 1] = ("%s: skill '%s' %s %s"):format(ab.agent, ab.skill, ab.completed and "completed" or "aborted:", ab.completed and "" or ab.reason)
  end
  return out
end

return Offline
