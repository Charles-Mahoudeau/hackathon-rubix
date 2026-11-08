-- Run from repo root: luau tests/test_branch_profit.luau
-- GR5-64: the branch profitability harness is deterministic, its control is the mining-only game, and the report is well formed.
-- Short window and two seeds so it stays fast; tools/branch_report.sh runs the full 90 minutes on five seeds.
local Profit = require("@scripts/sim/branch_profit")
local Cfg = require("@scripts/config/branch_profit")

assert(#Cfg.seeds >= 3, "at least three seeds")
for _, sc in ipairs(Cfg.scenarios) do
  assert(Cfg.forks[sc.fork] and Cfg.controls[sc.control], sc.id)
end

local opts = { seeds = { 1, 2 }, windowMinutes = 10, scenarios = {
  { id = "salvage_careful_t2", branch = "salvage", fork = "t2", control = "hmc", label = "Salvage", directive = "Survey first. Stop at layer 2." },
  { id = "raiding_careful_t4", branch = "raiding", fork = "t4", control = "hmc", label = "Raiding", directive = "Only escort 0. Retreat if hull below 40." },
} }

local a = Profit.run(opts)
local b = Profit.run(opts)
assert(#a.runs == 4)
for i, run in ipairs(a.runs) do
  local other = b.runs[i]
  assert(run.arm.netWorthDelta == other.arm.netWorthDelta, "same seed, same net worth")
  assert(run.arm.branchGross == other.arm.branchGross, "same seed, same gross")
  assert(run.control.netWorthDelta == other.control.netWorthDelta, "same seed, same control")
  local m = Profit.marginal(run)
  assert(not m.error, tostring(m.error))
  assert(math.abs(m.net - (run.arm.netWorthDelta - run.control.netWorthDelta)) < 1e-6)
end

-- by the T4 fork the seeds have diverged (the early game is the same script on every seed)
assert(a.controls["t4:hmc"][1].netWorthDelta ~= a.controls["t4:hmc"][2].netWorthDelta)

local md = Profit.markdown(a, opts)
assert(md:find("Per seed", 1, true) and md:find("salvage_careful_t2", 1, true) and md:find("raiding_careful_t4", 1, true))
assert(md:find("unreachable buyers", 1, true))
print("branch profit OK")
