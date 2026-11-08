-- Run from repo root: luau tests/test_headless.luau   (needs the .luaurc `@scripts` alias at the repo root)
-- Uses the same require() paths as the game.
local Balance = require("@scripts/config/balance")
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")

-- The engine freezes what a module returns (shallow); do the same here so a write to a module table fails the tests too.
for _, m in { Balance, Sim, Ai } do table.freeze(m) end

-- spec §6.1 starting state and §4.1 ores
local s = Sim.new()
assert(s.resources.credits == 500 and s.resources.compute == 10, "start credits/compute")
for _, ore in ipairs({ "titanium", "cobalt", "iridium", "crystal" }) do assert(s.resources[ore] == 0, ore) end
assert(s.agents.miner.tools.wait, "miner has wait")

-- spec §5.1 reference trip: K1 titanium -> Kessa depot = 15 + 50 + 15 s, 300 cr
assert(s:apply("miner", { name = "mine", args = { vein = "K1" } }))
local ticks = 0
while s.ships.s1.state ~= "idle" or ticks == 0 do s:step(); ticks = ticks + 1; assert(ticks < 2000) end
assert(math.abs(ticks * Balance.tickSeconds - 80) < 0.5, "K1 trip duration " .. ticks * Balance.tickSeconds)
assert(s.resources.credits == 500 + 300, "K1 trip revenue")

-- headless run: stub miner mines/sells, credits grow
local s1 = Sim.new()
s1:setDecider(Ai.decide)
s1:run(3000)
assert(s1.resources.credits > 500, "credits should increase")
print("credits", 500, "->", s1.resources.credits)

-- determinism: same seed => same state
local a, b = Sim.new(), Sim.new()
a:setDecider(Ai.decide); b:setDecider(Ai.decide)
a:run(2000); b:run(2000)
assert(a.resources.credits == b.resources.credits and a.tick == b.tick and #a.logs == #b.logs)

-- invalid calls rejected, no crash
local s2 = Sim.new()
local n = 0
for _, c in ipairs({ { name = "dig" }, { name = "scan", args = { planet = "kessa" } }, { name = "mine", args = { vein = "K99" } },
    { name = "mine", args = { vein = "K4" } }, -- hidden until scanned
    { name = "mine", args = { vein = "V1" } }, -- out of range with the base engine
    { name = "wait", args = { seconds = 1 } }, "junk" }) do
  local ok = s2:apply("miner", c); assert(not ok); n = n + 1
end
assert(#s2.logs == n and s2.logs[1].level == "ERROR")

-- bug 1: a sale empties the hold AND its accumulator, so mining never resurrects sold cargo
local s4 = Sim.new()
local ship = s4.ships.s1
ship.state, ship.cargo, ship.cargoF, ship.ore = "idle", 30, 30.7, "titanium"
assert(s4:apply("miner", { name = "sell", args = { ship = "s1" } }))
assert(ship.cargo == 0 and ship.cargoF == 0 and ship.ore == nil, "sell resets cargo, cargoF, ore")
assert(s4:apply("miner", { name = "mine", args = { vein = "K1" } }))
s4:run(200)
assert(ship.cargo <= math.floor((200 - 150) * Balance.tickSeconds * 2) + 1, "cargo restarted from zero after a sale")

-- bug 2: context is a detached snapshot; mutating it cannot touch the live sim
local s5 = Sim.new()
local ctx = s5:context("miner")
ctx.resources.credits = 1e9
ctx.ship.cargo = 99
ctx.planets.kessa.veins[1].reserve = -5
ctx.planets.kessa.depotRate = 99
assert(s5.resources.credits == 500 and s5.ships.s1.cargo == 0, "snapshot mutation leaked")
assert(s5.veins.K1.reserve == 3000 and s5.planets.kessa.depotRate == 0.30, "snapshot mutation leaked (nested)")
for id, p in pairs(ctx.planets) do for _, v in ipairs(p.veins) do assert(v.id ~= "K4", "hidden vein leaked into context") end end
local live = {}
local function collect(t) for _, v in pairs(t) do if type(v) == "table" then live[v] = true; collect(v) end end end
collect(s5.resources); collect(s5.ships); collect(s5.planets); collect(s5.veins)
local function assertDetached(t) for _, v in pairs(t) do if type(v) == "table" then assert(not live[v], "shared table"); assertDetached(v) end end end
assertDetached(s5:context("miner"))

-- late decision: validated against the state at arrival, stale ones dropped
local s6 = Sim.new()
local old = s6:context("miner")
assert(s6:apply("miner", { name = "mine", args = { vein = "K1" } })) -- world moved on while the answer was in flight
local ok, err = s6:resolveDecision("miner", { name = "mine", args = { vein = "K2" } }, old)
assert(not ok and err == "stale" and s6.logs[#s6.logs].level == "WARN")
local s7 = Sim.new()
s7.veins.K1.reserve = 0 -- depleted meanwhile: re-validation against live state catches it
local ok7, err7 = s7:resolveDecision("miner", { name = "mine", args = { vein = "K1" } }, s7:context("miner"))
assert(not ok7 and err7 == "vein_depleted")

-- vague mode: runs without crashing, logs errors
Ai.setMode("vague")
local s3 = Sim.new(); s3:setDecider(Ai.decide); s3:run(3000)
local errs = 0; for _, l in ipairs(s3.logs) do if l.level == "ERROR" then errs = errs + 1 end end
assert(errs > 0)
print("vague errors logged", errs, "credits", s3.resources.credits)
print("OK")
