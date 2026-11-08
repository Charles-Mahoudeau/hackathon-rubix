-- Save/load (spec §16.3): JSON codec, round trip, determinism across a save, schema_version handling.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Json = require("./support/engine_json")
local Persistence = require("@scripts/sim/persistence")

-- JSON codec
local sample = { a = 1, b = { 1, 2.5, -3e-7 }, c = "q\"\\\n\t\1é", d = true, e = {}, f = 0.1 + 0.2 }
local back = Json.decode(Json.encode(sample))
assert(back.a == 1 and back.b[2] == 2.5 and back.b[3] == -3e-7 and back.c == sample.c and back.d == true and back.f == 0.1 + 0.2)
assert(Json.encode({ z = 1, a = 2 }) == '{"a":2,"z":1}', "sorted keys")
assert(Json.decode('{"u":"\\u00e9\\n"}').u == "é\n")
for _, bad in ipairs({ "", "{", '{"a":}', "[1,]", '"abc', "1 2", "nope" }) do
  assert(not pcall(Json.decode, bad), "should reject: " .. bad)
end
assert(not pcall(Json.encode, { 0 / 0 }) and not pcall(Json.encode, { f = function() end }))

local function snapshot(sim) return Json.encode(Persistence.serialize(sim, 0)) end

-- a mid-run game restores exactly, and then evolves exactly like the original (RNG, ships, pending decisions)
local a = Sim.new()
a:setDecider(Ai.decide)
a:run(1500)
local storage = Persistence.memoryStorage()
assert(Persistence.save(a, storage, "s.json", 1700000000))
local b = assert(Persistence.load(storage, "s.json"))
assert(snapshot(a) == snapshot(b), "restored state differs")
b:setDecider(Ai.decide)
a:run(2500); b:run(2500)
assert(snapshot(a) == snapshot(b), "restored game diverged from the original")
assert(a.resources.credits > 500)

-- a ship mid-mining keeps its vein reference
local m = Sim.new()
assert(m:apply("miner", { name = "mine", args = { vein = "K1" } }))
m:run(400)
assert(m.ships.s1.state == "mining")
local m2 = assert(Persistence.load((function() local st = Persistence.memoryStorage(); Persistence.save(m, st, "m", 0); return st end)(), "m"))
assert(m2.ships.s1.vein == m2.veins.K1, "vein reference restored")
m:run(50); m2:run(50)
assert(snapshot(m) == snapshot(m2))

-- unknown schema_version: error, file untouched, and a save will not overwrite it
local st = Persistence.memoryStorage()
local future = '{"schema_version":999,"keep":"me"}'
st.files["f.json"] = future
local sim, e = Persistence.load(st, "f.json")
assert(sim == nil and e.code == "unknown_schema" and e.found == 999)
local sim2, e2 = Persistence.loadOrNew(st, "f.json")
assert(sim2 == nil and e2.code == "unknown_schema" and st.files["f.json"] == future, "load must not touch the file")
local ok, e3 = Persistence.save(Sim.new(), st, "f.json", 0)
assert(ok == false and e3.code == "unknown_schema" and st.files["f.json"] == future, "save must not overwrite")

-- corrupt files and missing files
st.files["bad.json"] = "{not json"
assert(select(2, Persistence.load(st, "bad.json")).code == "corrupt")
st.files["half.json"] = '{"schema_version":1}'
assert(select(2, Persistence.load(st, "half.json")).code == "corrupt")
assert(select(2, Persistence.load(st, "nope.json")).code == "no_file")
assert(Persistence.loadOrNew(st, "nope.json").tick == 0, "no save => new game")

-- reset replaces even an unreadable save, on purpose
local fresh = assert(Persistence.reset(st, "f.json", 5))
assert(fresh.tick == 0 and Persistence.load(st, "f.json").tick == 0)
-- GR5-10: warehouse, skills, params and the market survive a save and evolve identically afterwards
do
  local Skills = require("@scripts/sim/skills")
  local g = Sim.new({ seed = 4 })
  g.tier = 3
  for _, ag in pairs(g.agents) do ag.tier = 3 end
  g.resources.credits = 50000
  g.upgrades.warehouse, g.upgrades.tradingPost = true, true
  g.upgrades.archive = 2
  assert(Skills.save(g, { name = "ore-run", agent_type = "miner", loop = true, params = { vein = { kind = "vein" } },
    steps = { { tool = "mine", args = { vein = "$vein" } }, { tool = "return" }, { tool = "store", args = { resource = "titanium" } } } }))
  assert(Skills.assign(g, "miner", "ore-run", { vein = "K1" }))
  g:run(g:ticks(900))
  assert(g.warehouse.titanium > 0)
  local st2 = Persistence.memoryStorage()
  assert(Persistence.save(g, st2, "g.json", 42))
  local h = assert(Persistence.load(st2, "g.json"))
  assert(h.savedAt == 42 and h.warehouse.titanium == g.warehouse.titanium and h.skills["ore-run"].params.vein.kind == "vein")
  assert(h.agents.miner.mode == "skill" and h.agents.miner.skillParams.vein == "K1")
  assert(snapshot(g) == snapshot(h))
  g:run(g:ticks(1800)); h:run(h:ticks(1800))
  assert(snapshot(g) == snapshot(h), "skill game diverged after load")
end

print("persistence OK")
