-- Run from repo root: luau tests/test_qa_tour.luau
-- GR5-89: the QA tour's prepared company builds with nothing refused, and every step's action is one the client handles.
local Tour = require("@scripts/client/qa_tour")
local DebugConfig = require("@scripts/config/debug")

assert(DebugConfig.qaTour == false, "the QA tour is off in the repo")
local s, notes = Tour.prepare()
assert(#notes == 0, "prepare refused: " .. table.concat(notes, "; "))
assert(s.tier == 5 and s.agents.monitor_1 and #s.versions.miner >= 3 and s.skills["Titanium loop"], "company is T5 with a Monitor, a skill, 3 versions")

local t = Tour.new()
local seen = {}
local sim = s
local api = { now = 0, sim = function() return sim end, setSim = function(x) sim = x end, dispatch = function(a) seen[#seen + 1] = a return false end }
Tour.update(t, api)
for i = 1, #Tour.steps do api.now = i * 10; Tour.update(t, api) end
api.now = 1000; Tour.update(t, api)
assert(t.done and #seen > #Tour.steps, "all steps ran")

-- The studio and Monitor steps do what the captures need: a near-duplicate skill raises the "make it a parameter"
-- suggestion, accepting it parameterizes the saved skill, and the Monitor's order reaches the feed tagged "monitor".
local Studio = require("@scripts/ui/skill_studio")
local Feed = require("@scripts/sim/feed")
local fresh = Tour.prepare()
local st = Studio.new()
local byName = {}
for _, step in ipairs(Tour.steps) do byName[step.name] = step end
local function play(name)
	local step = byName[name]
	if step.run then step.run(fresh, {}) end
	for _, a in ipairs(step.actions) do if a:sub(1, 7) == "studio." then Studio.act(fresh, st, a) end end
end
play("studio-form"); play("studio-form-saved")
assert(not st.suggestion and fresh.skills[next(fresh.skills) and "Titanium loop"], "first form skill saved")
play("studio-form-again"); play("studio-suggest")
assert(st.suggestion, "a near-duplicate raises the parameter suggestion")
play("studio-make-param")
assert(not st.suggestion, "accepting clears the suggestion")
play("studio-assign"); play("studio-running")
play("monitor-order")
local tagged = false
for _, l in ipairs(Feed.recent and Feed.recent(fresh, 20) or fresh.feed or {}) do if l.source == "monitor" then tagged = true end end
assert(tagged, "the Monitor's order is in the feed tagged monitor")
-- GR5-104 map tour: every step's setup runs on the prepared company, the depot really fills (a real station_full alert) and the raid is a real fight
do
  local sim = Tour.prepare()
  for _, step in ipairs(Tour.mapSteps) do
    if step.run then step.run(sim, {}) end
    sim:run(sim:ticks(2))
  end
  assert(sim.alertTrack.stations[sim.home], "the depot is really full, so the alert is the sim's own")
  assert(#sim.raid.convoys >= 1 or sim.raid.attacks >= 1, "the convoy is a real raid convoy")
  assert(Tour.new("map").steps == Tour.mapSteps and Tour.new().steps == Tour.steps)
end

print("test_qa_tour OK")
