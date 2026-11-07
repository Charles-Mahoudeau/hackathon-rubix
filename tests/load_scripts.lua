-- Mimics the AYLO bridge: loads every scripts/**/*.luau in sorted path order, sharing globals. No require.
-- Usage (repo root): lua5.4 -e 'dofile("tests/load_scripts.lua")' ... or via tests/test_headless.luau.
local files = {}
local p = io.popen('find scripts -name "*.luau" ! -path "scripts/main.luau" | LC_ALL=C sort')
for f in p:lines() do files[#files + 1] = f end
p:close()
for _, f in ipairs(files) do assert(loadfile(f))() end
