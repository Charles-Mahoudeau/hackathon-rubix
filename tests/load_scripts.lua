-- Mimics the AYLO bridge for the headless sim: loads scripts/config and scripts/sim in sorted path order,
-- sharing globals. No require. client/, render/ and ui/ need the engine (Luau syntax) and are not loaded here.
local files = {}
local p = io.popen('find scripts/config scripts/sim -name "*.luau" | LC_ALL=C sort')
for f in p:lines() do files[#files + 1] = f end
p:close()
for _, f in ipairs(files) do assert(loadfile(f))() end
