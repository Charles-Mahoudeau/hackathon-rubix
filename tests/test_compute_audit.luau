-- Run from repo root: luau tests/test_compute_audit.luau
-- GR5-66: Compute billing, the real-hour token cap and the mission 3 / 8 counters, reconciled against the ledger
-- (see tools/compute_audit.luau; the markdown report is docs/COMPUTE_AUDIT.md).
local Audit = require("../tools/compute_audit")

local result = Audit.run()
local failed = {}
for _, c in ipairs(result.checks) do
  if not c.ok then failed[#failed + 1] = c.name .. " (" .. tostring(c.detail) .. ")" end
end
assert(#result.checks >= 40, "the audit lost checks: " .. #result.checks)
assert(#failed == 0, "compute audit failed:\n  " .. table.concat(failed, "\n  "))
print(("compute audit OK, %d checks"):format(#result.checks))
