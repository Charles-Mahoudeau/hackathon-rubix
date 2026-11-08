-- Run from repo root: luau tools/prompt_library_report.luau
-- Measured results of the prompt library (GR5-107): each BAD / OK / GOOD pair on its challenge fixture, on a seeded headless Sim.
-- Everything printed here is measured from the sim; the GDD figures live in config/prompt_library.luau as `specReference`.
local Data = require("@scripts/config/prompt_library")
local Challenges = require("@scripts/sim/prompt_challenges")

local pairs3 = {
  [1] = Data.missions[1].examples,
  [2] = Data.missions[2].examples,
  [3] = { Data.missions[1].examples[3], Data.missions[3].examples[2], Data.missions[3].examples[3] },
  [4] = Data.missions[5].examples,
  [5] = Data.missions[8].examples,
}
local function fmt(v) if type(v) == "number" then return string.format("%.1f", v) end return tostring(v) end

print("| Challenge | Directive | Value | Target | Passed | Credits/min | Compute |")
print("|---|---|---|---|---|---|---|")
for id, list in ipairs(pairs3) do
  local c = Data.challenges[id]
  for _, ex in ipairs(list) do
    local r = Challenges.run(id, ex.text)
    local label = (id == 3 and ex == list[1]) and "AI every trip (mission 1 GOOD)" or ex.grade:upper()
    print(("| %d %s | %s | %s | %d | %s | %s | %s |"):format(id, c.name, label, fmt(r.value), c.target, r.passed and "yes" or "no",
      r.credits_per_min and fmt(r.credits_per_min) or "-", r.compute and fmt(r.compute) or "-"))
  end
end
