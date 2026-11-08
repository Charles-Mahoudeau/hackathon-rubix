-- Run from the repo root: luau tools/balance_report.luau > docs/BALANCE_REPORT.md   (see tools/balance_report.sh)
local Pacing = require("@scripts/sim/pacing")
print(Pacing.report())
