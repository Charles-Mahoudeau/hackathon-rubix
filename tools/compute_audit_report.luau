-- Run from the repo root: luau tools/compute_audit_report.luau > docs/COMPUTE_AUDIT.md   (see tools/compute_audit.sh)
local Audit = require("./compute_audit")
local result = Audit.run()
print(result.report)
