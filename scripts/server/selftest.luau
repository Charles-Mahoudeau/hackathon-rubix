-- Engine self-test entry (M0 headless runner): `aylo-runtime . --server --selftest --ticks 600` (tools/run_engine_test.sh).
-- Runs the sim checks inside the real engine, so a module the sandbox refuses to load fails here and not at demo time.
-- Exit code 0 = every check passed; 1 = a check failed (the reason is printed).
local Balance = require("@scripts/config/balance")
local World = require("@scripts/config/world")
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Json = require("@scripts/sim/json")
local Persistence = require("@scripts/sim/persistence")

local selftestTicks = 3000

local function check()
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
	assert(Json.encode(Persistence.serialize(loaded, 1700000000)) == storage.files["save.json"], "save round trip differs")
	print(("selftest: %d ticks, credits %d -> %d"):format(a.tick, Balance.startCredits, a.resources.credits))
end

engine.ecs.system("game.SelfTest", {
	phase = "Update",
	query = {},
	events = { send = { "rtype.AppExit" } },
	run = function(ctx)
		local ok, err = pcall(check)
		if ok then
			print("selftest: PASS")
			ctx.events.send("rtype.AppExit", { code = 0 })
		else
			print("selftest: FAIL " .. tostring(err))
			ctx.events.send("rtype.AppExit", { code = 1 })
		end
	end,
})
