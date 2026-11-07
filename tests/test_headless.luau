-- Run from repo root: lua5.4 -e 'package.path="?.luau;"..package.path' tests/test_headless.luau
local Sim = require("sim.sim")
local Ai = require("sim.ai")

local s = Sim.new()
s:setDecider(Ai.decide)
local start = s.resources.credits
s:run(3000)
assert(s.resources.credits > start, "credits should increase")
print("credits", start, "->", s.resources.credits)

-- invalid calls rejected, no crash
local s2 = Sim.new()
local n = 0
for _, c in ipairs({ { name = "dig" }, { name = "scan", args = { planet = "kessel" } }, { name = "mine", args = { planet = "kessel", vein = 99 } }, "junk" }) do
  local ok = s2:apply("miner", c); assert(not ok); n = n + 1
end
assert(#s2.logs == n and s2.logs[1].level == "ERROR")

-- vague mode: runs without crashing, logs errors
Ai.mode = "vague"
local s3 = Sim.new(); s3:setDecider(Ai.decide); s3:run(3000)
local errs = 0; for _, l in ipairs(s3.logs) do if l.level == "ERROR" then errs = errs + 1 end end
assert(errs > 0)
print("vague errors logged", errs, "credits", s3.resources.credits)
print("OK")
