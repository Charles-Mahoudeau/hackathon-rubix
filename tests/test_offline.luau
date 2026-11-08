-- Run from repo root: luau tests/test_offline.luau
-- GR5-10 / spec §14 (D12): offline progression is the same sim run headless; only skill-mode agents work.
local Sim = require("@scripts/sim/sim")
local Skills = require("@scripts/sim/skills")
local Offline = require("@scripts/sim/offline")
local Debug = require("@scripts/sim/debug")
local Persistence = require("@scripts/sim/persistence")
local Json = require("@scripts/sim/json")

local function loop(name, vein)
  return { name = name, agent_type = "miner", params = { vein = { kind = "vein" } }, loop = true,
    steps = { { tool = "mine", args = { vein = "$vein" } }, { tool = "return" }, { tool = "sell" } } }
end

-- Three miners on skills (K1, K2, K3) and one AI-mode logistician with a directive.
local function team(seed)
  local s = Sim.new({ seed = seed or 1 })
  s.tier = 2
  for _, a in pairs(s.agents) do a.tier = s.tier end
  s.resources.credits = 50000
  s.upgrades.archive = 3
  assert(Skills.save(s, loop("ore-run")))
  s:addAgent("miner_b", "miner"); s:addShip("s2", "miner_b")
  s:addAgent("miner_c", "miner"); s:addShip("s3", "miner_c")
  assert(Skills.assign(s, "miner", "ore-run", { vein = "K1" }))
  assert(Skills.assign(s, "miner_b", "ore-run", { vein = "K2" }))
  assert(Skills.assign(s, "miner_c", "ore-run", { vein = "K3" }))
  s.agents.logistician.directive = "move cobalt to Halcyon"
  s.agents.logistician.mode = "ai"
  return s
end

-- 1. short absences are ignored; long ones are capped at 8 h
do
  local s = team()
  assert(Offline.run(s, 59) == nil and s.tick == 0, "< 60 s is ignored")
  assert(select(1, Offline.simulated(s, 3600)) == 3600)
  local secs, capped = Offline.simulated(s, 30 * 3600)
  assert(secs == 8 * 3600 and capped)
  assert(Offline.simulated(s, -5) == 0 and Offline.simulated(s, 0 / 0) == 0)
end

-- 2. the report matches an ordinary sim run over the same time; AI-mode agents earn nothing; no Compute spent
do
  local a, b = team(2), team(2)
  local compute = a.resources.compute
  local c0 = a.resources.credits
  local report = Offline.run(a, 3600)
  assert(report and report.simulated_seconds == 3600 and not report.capped)
  -- reference: the same hour, stepped by hand with the AI side off
  b.offline = true
  for _ = 1, 36000 do b:step() end
  b.offline = nil
  assert(a.resources.credits == b.resources.credits, "offline = same sim: " .. a.resources.credits .. " vs " .. b.resources.credits)
  assert(report.credits == a.resources.credits - c0 and report.credits > 0)
  assert(a.resources.compute == compute, "no Compute spent offline")
  local sum, units = 0, 0
  for _, ag in ipairs(report.agents) do
    sum += ag.credits; units += ag.units
    if ag.id == "logistician" then assert(ag.credits == 0 and ag.units == 0 and ag.mode == "ai", "AI-mode agent earns nothing") end
    if ag.mode == "skill" then assert(ag.credits > 0 and ag.units > 0 and ag.skill == "ore-run", ag.id) end
  end
  assert(sum == report.credits and units == report.units, "per-agent figures add up")
  assert(a.offline == nil and a.tally == nil, "offline state cleared")
  assert(#report.aborted == 0)
  local lines = Offline.lines(report)
  assert(lines[1]:find("Away 1 h") and #lines >= 5)
  assert(a.lastOfflineReport == report)
  local found = false
  for _, e in ipairs(a:drainEvents()) do if e.name == "offline_report" then found = true end end
  assert(found, "the report leaves as an event")
end

-- 3. the demo button: same code path as a real load
do
  local a, b = team(3), team(3)
  local ok, res = Debug.run(a, "simulateAway", { hours = 1 })
  assert(ok, tostring(res))
  local report = Offline.run(b, 3600)
  assert(res.credits == report.credits and a.resources.credits == b.resources.credits and a.tick == b.tick, "button = load")
  assert(not Debug.run(a, "simulateAway", { hours = 100 }))
end

-- 4. aborted skills stay aborted and are reported with the reason
do
  local s = team(4)
  s.upgrades.archive = 4
  assert(Skills.save(s, { name = "broken", agent_type = "miner", params = {}, loop = true,
    steps = { { tool = "mine", args = { vein = "K4" } }, { tool = "return" } } }))
  s:addAgent("miner_d", "miner"); s:addShip("s4", "miner_d")
  assert(Skills.assign(s, "miner_d", "broken", {}))
  local report = Offline.run(s, 1800)
  assert(#report.aborted == 1 and report.aborted[1].agent == "miner_d" and report.aborted[1].skill == "broken" and report.aborted[1].reason == "unknown vein")
  assert(s.agents.miner_d.skillRun.aborted and s.agents.miner_d.mode == "skill", "no AI called, stays aborted")
  local text = table.concat(Offline.lines(report), "\n")
  assert(text:find("aborted") and text:find("unknown vein"))
  local again = Offline.run(s, 1800)
  assert(#again.aborted == 0, "the abort is not repeated")
end

-- 5. a save written before an absence restores and catches up the same way
do
  local a = team(5)
  a:run(a:ticks(300))
  local storage = Persistence.memoryStorage()
  assert(Persistence.save(a, storage, "o.json", 0))
  local b = assert(Persistence.load(storage, "o.json"))
  Offline.run(a, 7200); Offline.run(b, 7200)
  assert(Json.encode(Persistence.serialize(a, 0)) == Json.encode(Persistence.serialize(b, 0)), "restored game catches up identically")
end

-- 6. M5: 8 h offline for 3 agents under 2 s; markets/rivals run too; growth stays bounded
do
  local s = team(6)
  local t0 = os.clock()
  local report = Offline.run(s, 8 * 3600)
  local dt = os.clock() - t0
  assert(report.simulated_seconds == 8 * 3600)
  assert(dt < 2, ("8 h offline took %.2f s"):format(dt))
  assert(s.market.sec >= 8 * 3600, "markets ran")
  assert(#s.feed < 2000 and #s.logs < 5000, "feed/logs bounded: " .. #s.feed .. "/" .. #s.logs)
  print(("8 h offline: %.2f s, %+d cr"):format(dt, report.credits))
end

-- 7. catching up after a load uses the saved_at stamp
do
  local a = team(7)
  local storage = Persistence.memoryStorage()
  assert(Persistence.save(a, storage, "c.json", 1000))
  local b = assert(Persistence.load(storage, "c.json"))
  assert(Persistence.catchUp(b, 1030) == nil, "30 s away is ignored")
  local report = Persistence.catchUp(b, 1000 + 1800)
  assert(report and report.simulated_seconds == 1800 and report.credits > 0)
  local c = assert(Persistence.load(storage, "c.json"))
  assert(Persistence.catchUp(c, 1000 + 20 * 3600).capped)
end

print("offline OK")
