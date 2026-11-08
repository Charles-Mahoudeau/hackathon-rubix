-- Run from the repo root: luau tools/branch_report.luau > docs/BRANCH_PROFIT_REPORT.md   (see tools/branch_report.sh)
local Profit = require("@scripts/sim/branch_profit")
print(Profit.markdown(Profit.run()))
