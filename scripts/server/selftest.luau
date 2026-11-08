-- Engine self-test entry (M0 headless runner): `aylo-runtime . --server --selftest --ticks 600` (tools/run_engine_test.sh).
-- Runs the sim checks inside the real engine, so a module the sandbox refuses to load fails here and not at demo time.
-- Exit code 0 = every check passed; 1 = a check failed (the reason is printed).
local Balance = require("@scripts/config/balance")
local Host = require("@scripts/sim/host")
local World = require("@scripts/config/world")
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Persistence = require("@scripts/sim/persistence")
local Save = require("@scripts/client/save")
local Storage = require("@scripts/client/storage")

local selftestTicks = 3000

local function check(ctx)
	assert(Balance.tickSeconds == 0.1 and Balance.startCredits == 500 and Balance.startCompute == 10, "balance anchors")
	assert(#World.planetOrder == 4 and #World.veins == 12, "world content")

	local a, b = Sim.new(), Sim.new()
	a:setDecider(Ai.decide)
	b:setDecider(Ai.decide)
	a:run(selftestTicks)
	b:run(selftestTicks)
	assert(a.resources.credits > Balance.startCredits, "the stub miner earned nothing in " .. selftestTicks .. " ticks")
	assert(a.resources.credits == b.resources.credits and a.tick == b.tick and #a.logs == #b.logs, "two runs of the same seed differ")

	local storage = Persistence.memoryStorage()
	assert(Persistence.save(a, storage, "save.json", 1700000000), "save failed")
	local loaded = assert(Persistence.load(storage, "save.json"))
	assert(Host.json.encode(Persistence.serialize(loaded, 1700000000)) == storage.files["save.json"], "save round trip differs")

	-- GR5-60: the engine's rtype.Json plugin keeps the contract the sim relies on (ordered maps, sorted objects, tryDecode, JSON renderer).
	local json = Host.json
	assert(json.encode(json.map({ { "z", 1 }, { "a", { 2, 3 } } })) == '{"z":1,"a":[2,3]}', "json: map keeps entry order")
	assert(json.encode({ b = 1, a = 2 }) == '{"a":2,"b":1}' and json.encode({}) == "[]", "json: sorted keys, empty table is an array")
	local decoded, decodeErr = json.tryDecode('{"x":[1,null,2]}')
	assert(decodeErr == nil and #decoded.x == 2 and decoded.x[2] == 2, "json: null array elements are dropped")
	local badValue, badErr = json.tryDecode("{nope")
	assert(badValue == nil and type(badErr) == "string", "json: tryDecode reports bad text without raising")
	local nullValue, nullErr = json.tryDecode("null")
	assert(nullValue == nil and nullErr == nil, "json: a null text is nil with no message")
	local Renderer = require("@scripts/sim/context_renderer")
	local rendered = Renderer.json({ { key = "stock", kind = "map", map = Renderer.map({ { "iron", 3 }, { "list", Renderer.map({ { 1, "miner" } }) } }) } })
	assert(rendered == '{"stock":{"iron":3,"list":{"1":"miner"}}}', "json: renderer output: " .. rendered)

	-- GR5-77: the same save path as the client, on the engine's rtype.Persistence (a throwaway folder, see project.luau).
	local engineStorage = Storage.engine()
	engineStorage.ctx = ctx
	local cfg = { file = "selftest.save", autosaveSeconds = 30 }
	engineStorage.delete(cfg.file)
	local first = Save.new(engineStorage, cfg)
	local fresh = Save.boot(first, 0, 1700000000)
	assert(fresh.tick == 0 and engineStorage.read(cfg.file) ~= nil, "engine save: a new game is written at boot: " .. tostring(first.lastError and first.lastError.message) .. " / " .. tostring(first.saves))
	fresh:setDecider(Ai.decide)
	fresh:run(1200)
	assert(Save.quit(first, fresh, 1700000120), "engine save: quit save failed")
	local second = Save.new(engineStorage, cfg)
	local again, report = Save.boot(second, 0, 1700000140)
	assert(report == nil and again.tick == fresh.tick and again.resources.credits == fresh.resources.credits, "engine save: reload differs")
	local third = Save.new(engineStorage, cfg)
	local away, awayReport = Save.boot(third, 0, 1700000140 + 3600)
	assert(awayReport and awayReport.simulated_seconds == 3600 and away.tick > again.tick, "engine save: no offline catch-up")
	assert(engineStorage.write(cfg.file, '{"schema_version":999,"keep":"me"}'), "engine save: write failed")
	local locked = Save.new(engineStorage, cfg)
	Save.boot(locked, 0, 1700000140)
	assert(locked.blocked and locked.error.code == "unknown_schema" and not Save.quit(locked, fresh, 1700000200), "engine save: unknown schema not refused")
	assert(engineStorage.read(cfg.file) == '{"schema_version":999,"keep":"me"}', "engine save: unknown-schema file was touched")
	engineStorage.delete(cfg.file)
	assert(engineStorage.read(cfg.file) == nil, "engine save: delete failed")
	print(("selftest: %d ticks, credits %d -> %d"):format(a.tick, Balance.startCredits, a.resources.credits))
end

engine.ecs.system("game.SelfTest", {
	phase = "Update",
	query = {},
	events = { send = { "rtype.AppExit" } },
	calls = Storage.calls,
	run = function(ctx)
		local ok, err = pcall(check, ctx)
		if ok then
			print("selftest: PASS")
			ctx.events.send("rtype.AppExit", { code = 0 })
		else
			print("selftest: FAIL " .. tostring(err))
			ctx.events.send("rtype.AppExit", { code = 1 })
		end
	end,
})
