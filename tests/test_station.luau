-- GR5-73 gate: the Station screen (spec §6.6 T3, §7) shows the stock, capacity, docked ships, freighters and Logisticians of
-- the main station and of each outpost, from the sim. Headless: view-model and spec tree only.
local Sim = require("@scripts/sim/sim")
local Fit = require("@scripts/ui/fit")
local Theme = require("@scripts/config/theme")
local StationView = require("@scripts/ui/station_view")
local Shell = require("@scripts/ui/shell")

local function texts(node, out)
  out = out or {}
  if node.text and node.text.text then out[#out + 1] = node.text.text end
  for _, c in ipairs(node.children or {}) do texts(c, out) end
  return out
end
local function shows(sim, ui, needle)
  for _, t in ipairs(texts((Shell.spec(sim, "station", { station = ui }))) ) do if t:find(needle, 1, true) then return true end end
  return false
end

-- T3, warehouse bought: the Kessa stock follows a Miner `store`
local s = Sim.new()
s:enterTier(3)
s.resources.credits = 100000
s.lifetimeRevenue = 30000
assert(s:buyUpgrade("warehouse"))
local ui = StationView.new()
local m = StationView.model(s, ui)
assert(m.label == "main@kessa" and m.planet == "Kessa" and not m.showTabs and #m.tabs == 1, "one station, no tabs")
assert(m.used == 0 and m.capacity == 2000 and m.usedText == "0 / 2000" and #m.stock == 4 and m.stock[1].qty == 0, "empty warehouse")
assert(#m.ships == 1 and m.ships[1].id == "s1" and m.ships[1].text:find("hold empty", 1, true), "the Miner is docked")
assert(not m.hub and #m.freighters == 0 and #m.logisticians == 0, "no hub at T3")
assert(shows(s, ui, "0 / 2000") and shows(s, ui, "Build the logistics hub"), "screen at T3")

local sig0 = StationView.signature(s, ui)
assert(s:apply("miner", { name = "mine", args = { vein = "K1" } }))
repeat s:step() until s.ships.s1.state == "idle"
assert(StationView.model(s, ui).ships[1].text:find("100 titanium", 1, true), "docked ship shows its hold")
assert(s:apply("miner", { name = "store", args = { resource = "titanium", qty = 40 } }))
m = StationView.model(s, ui)
assert(m.stock[1].id == "titanium" and m.stock[1].qty == 40 and m.used == 40 and m.percent == 2 and m.usedText == "40 / 2000", "stock after store")
assert(StationView.signature(s, ui) ~= sig0, "the signature moves with the stock")
assert(shows(s, ui, "40 / 2000"), "screen shows the stock")

-- T4: freighters, Logisticians and an outpost tab
s.lifetimeRevenue = 60000
assert(s:buyUpgrade("logistics_hub"))
assert(s:hireLogistician("kessa") and s:buyFreighter("kessa"))
s.warehouse.cobalt = 500
assert(s:apply("logistician", { name = "ship", args = { resource = "cobalt", qty = 500, destination = "halcyon" } }))
m = StationView.model(s, ui)
assert(m.hub and #m.freighters == 1 and m.freighters[1].state == "travelling" and m.freighters[1].text:find("-> halcyon cobalt:500", 1, true), "freighter in transit")
assert(#m.logisticians == 1 and m.logisticians[1].id == "logistician", "Logistician listed")
assert(shows(s, ui, "FREIGHTERS") and shows(s, ui, "LOGISTICIANS  1"), "screen at T4")

assert(s:buyUpgrade("engine_mk2") and s:buyUpgrade("engine_mk3"))
s.resources.credits = 100000
assert(s:buildOutpost("varn"))
s.stations.varn.stock.cobalt = 400
m = StationView.model(s, ui)
assert(m.showTabs and #m.tabs == 2 and m.tabs[1].active and not m.tabs[2].active, "outpost adds a tab")
assert(StationView.act(ui, m.tabs[2].action) and ui.station == "varn")
m = StationView.model(s, ui)
assert(m.label == "outpost@varn" and m.stock[2].qty == 400 and m.capacity == s.b.logistics.outpostStorage and m.tabs[2].active, "outpost stock")
assert(m.ships[1] == nil and #m.logisticians == 0 and m.idleText, "outpost has no ship docked and no Logistician")
assert(shows(s, ui, "outpost@varn"), "outpost tab renders")
assert(not StationView.act(ui, "fleet.hire.varn") and not StationView.act(ui, nil), "foreign actions refused")
ui.station = "gone"
assert(StationView.model(s, ui).id == "kessa", "an unknown tab falls back to home")

-- without the warehouse the screen stays on its empty state
local bare = Sim.new()
bare:enterTier(3)
local empty = texts((Shell.spec(bare, "station", {})))
local found = false
for _, t in ipairs(empty) do if t == "No station" then found = true end end
assert(found, "no warehouse, empty state")

-- layout: every tab of a full T4 game stays inside the view
for _, id in ipairs({ "kessa", "varn" }) do
  ui.station = id
  local bad = Fit.check((Shell.spec(s, "station", { station = ui })), Theme.layout.view)
  assert(#bad == 0, table.concat(bad, "\n"))
end
print("station OK")
