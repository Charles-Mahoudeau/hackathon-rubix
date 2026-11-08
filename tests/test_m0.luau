-- M0 gate (spec §17): the project boots, balance.luau loads, an empty save round-trips, a headless runner exists.
-- Run from anywhere: luau tests/test_m0.luau   (tools/run_tests.sh runs every test)
local Balance = require("@scripts/config/balance")
local World = require("@scripts/config/world")
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Json = require("@scripts/sim/json")
local Persistence = require("@scripts/sim/persistence")
local Debug = require("@scripts/sim/debug")
local DebugPanel = require("@scripts/ui/debug")

-- boots: every foundation module returned a table/function
for name, m in { Balance = Balance, World = World, Sim = Sim, Ai = Ai, Json = Json, Persistence = Persistence, Debug = Debug, DebugPanel = DebugPanel } do
  assert(type(m) == "table", name .. " did not load")
end
assert(type(Sim.new) == "function")

-- balance loads with the spec's anchor values and a complete world
assert(Balance.tickSeconds == 0.1 and Balance.startCredits == 500 and Balance.startCompute == 10, "balance anchors")
assert(#World.planetOrder == 4 and #World.marketOrder == 3 and #World.veins == 12, "world content")

-- an empty save is written and read back identically
local storage = Persistence.memoryStorage()
local fresh = Sim.new()
assert(Persistence.save(fresh, storage, "save.json", 1700000000))
local loaded = assert(Persistence.load(storage, "save.json"))
assert(Json.encode(Persistence.serialize(loaded, 1700000000)) == storage.files["save.json"], "empty save round trip")
assert(loaded.resources.credits == 500 and loaded.tick == 0)

-- the headless runner: a new game ticks at 10 Hz of game time
local g = Sim.new()
g:run(100)
assert(g.tick == 100 and math.abs(g.tick * Balance.tickSeconds - 10) < 1e-9)
print("M0 OK")
