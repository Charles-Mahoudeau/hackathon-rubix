-- Run from repo root: luau tests/test_speed.luau
-- GR5-14 / spec §3, §6.7, §10.4: x1/x4/x16 + pause never change the sim, only how fast it is stepped; the real AI request
-- rate and the hourly token window follow REAL time; the headless pacing report is deterministic and reads the targets.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Clock = require("@scripts/sim/clock")
local Skills = require("@scripts/sim/skills")
local Offline = require("@scripts/sim/offline")
local Persistence = require("@scripts/sim/persistence")
local Json = require("@scripts/sim/json")
local Pacing = require("@scripts/sim/pacing")
local PacingConfig = require("@scripts/config/pacing")
local Model = require("@scripts/ui/shell_model")

local function state(sim) return Json.encode(Persistence.serialize(sim, 0)) end

local function skillTeam(seed)
  local s = Sim.new({ seed = seed or 1 })
  s.tier = 2
  for _, a in pairs(s.agents) do a.tier = 2 end
  s.resources.credits = 50000
  assert(Skills.save(s, { name = "ore-run", agent_type = "miner", params = { vein = { kind = "vein" } }, loop = true,
    steps = { { tool = "mine", args = { vein = "$vein" } }, { tool = "return" }, { tool = "sell" } } }))
  assert(Skills.assign(s, "miner", "ore-run", { vein = "K1" }))
  return s
end

-- 1. speed levels, pause, controls
do
  local s = Sim.new()
  assert(s.speed == 1 and not s.paused)
  for _, bad in ipairs({ 0, 2, 3, 32, -1 }) do assert(not Clock.setSpeed(s, bad), "refused " .. bad) end
  assert(not Clock.setSpeed(s, "4") and s.speed == 1)
  assert(Clock.setSpeed(s, 4) and s.speed == 4 and Clock.setSpeed(s, 16) and s.speed == 16)
  local seen = {}
  for _, e in ipairs(s:drainEvents()) do if e.name == "speed_changed" then seen[#seen + 1] = e.data.speed end end
  assert(#seen == 2 and seen[1] == 4 and seen[2] == 16, "speed_changed events")
  Clock.setPaused(s, true)
  assert(Clock.advance(s, 10) == 0 and s.tick == 0, "nothing runs while paused")
  assert(Clock.setSpeed(s, 1) and not s.paused, "picking a speed resumes")
  assert(Clock.advance(s, 1.0) == 10 and s.tick == 10, "x1: 10 steps per real second")
  assert(Clock.advance(s, -1) == 0 and Clock.advance(s, 0 / 0) == 0)
  Clock.setSpeed(s, 16)
  assert(Clock.advance(s, 1.0) == 160, "x16: 160 steps per real second")
  assert(Clock.advance(s, 60) == s.b.speed.maxStepsPerFrame, "a stall is capped")
  assert(Clock.advance(s, 0.05) == 8, "and the next frame is normal again")
  assert(Clock.act(s, "speed.4") and s.speed == 4 and Clock.act(s, "speed.pause") and s.paused and Clock.act(s, "speed.pause") and not s.paused)
  assert(not Clock.act(s, "speed.7") or s.speed == 4, "unknown level ignored")
  assert(not Clock.act(s, "nav.map"))
  local rows = Clock.controls(s)
  assert(#rows == 4 and rows[1].action == "speed.pause" and rows[3].label == "x4" and rows[3].active)
  assert(#Model.topBar(s).speed == 4)
  local before = Model.signature(s, "map")
  Clock.setSpeed(s, 16)
  assert(Model.signature(s, "map") ~= before, "the shell redraws when the speed changes")
end

-- 2. same real time at x4 = x1 over 4x as long; skills and the stub AI are unaffected
do
  local function run(speed, realSeconds)
    local s = skillTeam(3)
    s:setDecider(Ai.decide)
    s:addAgent("miner_b", "miner"); s:addShip("s2", "miner_b")
    s:setDirective("miner_b", "Mine K2 until the hold is 100%")
    Clock.setSpeed(s, speed)
    for _ = 1, realSeconds / 0.25 do Clock.advance(s, 0.25) end
    return s
  end
  local a, b, c = run(1, 1200), run(4, 300), run(16, 75)
  local top = math.max(a.tick, b.tick, c.tick)
  for _, s in ipairs({ a, b, c }) do assert(top - s.tick <= 1, "ticks match") ; while s.tick < top do s:step() end end
  assert(a.resources.credits > 500, "the run earns")
  assert(state(a) == state(b) and state(b) == state(c), "x1 = x4 = x16 state")
end

-- 3. offline math does not depend on the speed
do
  local a, b = skillTeam(5), skillTeam(5)
  Clock.setSpeed(b, 16)
  local ra, rb = Offline.run(a, 7200), Offline.run(b, 7200)
  assert(ra.credits == rb.credits and ra.units == rb.units and ra.credits > 0, "offline report equal")
  assert(state(a) == state(b))
  assert(b.speed == 16, "the player's speed survives an offline catch-up")
end

-- 4. a real provider is paced above x1 so the real request rate never exceeds the x1 thrash-guard rate
do
  local function fakeProvider()
    local p = { n = 0, perAgent = {}, queue = {} }
    function p:request(req)
      self.n += 1
      self.perAgent[req.agent_id] = (self.perAgent[req.agent_id] or 0) + 1
      self.queue[#self.queue + 1] = { id = self.n, ok = true, input_tokens = 100, output_tokens = 10, seconds = 0.1,
        tool_call = { reasoning = "", tool = "wait", args = { seconds = 10 } } }
      return self.n
    end
    function p:drain() local q = self.queue; self.queue = {}; return q end
    return p
  end
  local function requests(speed, realSeconds)
    local s = Sim.new()
    s:setDecider(Ai.decide)
    local p = fakeProvider()
    s:setProvider(p)
    s:setDirective("miner", "mine")
    Clock.setSpeed(s, speed)
    for _ = 1, realSeconds / 0.25 do Clock.advance(s, 0.25) end
    return p.perAgent.miner or 0, s
  end
  local n1 = requests(1, 240)
  local n16, s16 = requests(16, 240)
  local limit = 240 / s16.b.speed.aiMinRealSeconds + 1
  assert(n1 > 0 and n16 > 0, "both decide")
  assert(n16 <= limit, ("x16 request rate bounded: %d <= %d"):format(n16, limit))
  -- without pacing the same x16 run would ask far more often: the guard is what holds it
  local free = Sim.new()
  free:setDecider(Ai.decide)
  local p = fakeProvider(); free:setProvider(p); free:setDirective("miner", "mine")
  Clock.setSpeed(free, 16); free.b = setmetatable({ speed = { levels = { 1, 4, 16 }, default = 1, aiMinRealSeconds = 0, maxStepsPerFrame = 400 } }, { __index = free.b })
  for _ = 1, 960 do Clock.advance(free, 0.25) end
  assert((p.perAgent.miner or 0) > limit, "unpaced x16 would exceed the limit: " .. tostring(p.perAgent.miner))
  -- the stub makes no request, so it is not paced
  local stub = Sim.new(); stub:setDecider(Ai.decide); stub:setDirective("miner", "mine"); Clock.setSpeed(stub, 16)
  assert(stub:paceAllowed(stub.agents.miner) and #stub.logs == 0)
end

-- 5. the hourly token window is a real hour: it follows speed, not game time
do
  local s = Sim.new({ aiConfig = { windowSeconds = 60, tokensPerHour = 1000 } })
  Clock.setSpeed(s, 16)
  local id = assert(s.aiQueue:submit({ agentId = "miner" }))
  s.aiQueue:complete(id, 1000)
  assert(s.aiQueue:budgetReached())
  for _ = 1, 50 / 0.25 do Clock.advance(s, 0.25) end -- 50 real seconds = 800 game seconds
  assert(s.tick == 8000 and s.aiQueue:budgetReached(), "still inside the real window after 800 game-s")
  for _ = 1, 11 / 0.25 do Clock.advance(s, 0.25) end -- 61 real seconds
  assert(not s.aiQueue:budgetReached() and s.aiQueue:tokensUsed() == 0, "released after 60 real seconds")
  local one = Sim.new()
  for _ = 1, 600 do one:step() end
  assert(one.aiQueue.now() == 60, "x1: real clock = game clock")
end

-- 6. headless pacing report
do
  local short = { seconds = 1800, sampleSeconds = 300 }
  local a = Pacing.run({ seed = 1, seconds = short.seconds, sampleSeconds = short.sampleSeconds })
  local b = Pacing.run({ seed = 1, seconds = short.seconds, sampleSeconds = short.sampleSeconds })
  assert(Json.encode(a) == Json.encode(b), "same seed, same report")
  assert(a.tiers[2] and a.tiers[2].at > 0 and a.finalCredits > 0 and #a.samples == 6 and #a.purchases > 0)
  local x16 = Pacing.run({ seed = 1, seconds = short.seconds, sampleSeconds = short.sampleSeconds, speed = 16 })
  assert(x16.finalCredits == a.finalCredits and x16.tiers[2].at == a.tiers[2].at, "speed does not change the economy")
  local md = Pacing.markdown({ a })
  for _, part in ipairs({ "# GRIDMIND pacing report", "## Tier timings", "## Credits per tier", "## Credits timeline", "## Purchases", "## AI load", "| T3 |", "Verdict" }) do
    assert(md:find(part, 1, true), "report has " .. part)
  end
  -- verdicts
  local t = PacingConfig.targets[3]
  assert(Pacing.verdict(3, t, 1e6).status == "ok" and Pacing.verdict(3, t * 1.29, 1e6).status == "ok")
  assert(Pacing.verdict(3, t * 1.31, 1e6).status == "flag" and Pacing.verdict(3, t * 0.69, 1e6).status == "flag")
  assert(Pacing.verdict(3, nil, 1e6).status == "not_reached" and Pacing.verdict(5, nil, 60).status == "beyond_run")
  assert(Pacing.verdict(2, 100, 1e6).status == "no_target")
  -- the shipped balance: T3 lands within tolerance of its target on every seed (T4/T5 need their own sim milestones)
  for _, seed in ipairs(PacingConfig.report.seeds) do
    local r = Pacing.run({ seed = seed, seconds = 2400 })
    assert(r.tiers[3], "T3 reached, seed " .. seed)
    local v = Pacing.verdict(3, r.tiers[3].at, 2400)
    assert(v.status == "ok", ("T3 off target on seed %d: %.1f min vs %.1f"):format(seed, r.tiers[3].at / 60, v.target / 60))
  end
end

print("speed OK")
