local Sim = require("@scripts/sim/sim")
local Market = require("@scripts/sim/market")

do
  local s = Sim.new()
  local ship = s.ships.s1
  assert(s:apply("miner", { name = "mine", args = { vein = "K1" } }))
  while ship.state ~= "mining" do s:step() end
  s:run(10)
  local cargo = ship.cargo
  assert(s:apply("miner", { name = "mine", args = { vein = "K2" } }))
  assert(ship.timer == s:ticks(15 * ship.engineMult))
  while ship.state ~= "mining" do s:step() end
  assert(ship.vein.id == "K2" and ship.cargo == cargo)
end

do
  local s = Sim.new()
  local m = s.market
  m.markets.orbis.res.cobalt.d = 1.037
  local unit, total = Market.sell(m, "orbis", "cobalt", 17)
  assert(unit == Market.round1(unit))
  assert(total == math.floor(unit * 17))
  local ok, err = s:validate("miner", { name = "sell", args = { planet = "invalid" } })
  assert(not ok and err == "out_of_range")
end

print("fidelity OK")
