-- Run from repo root: luau tests/test_team.luau
-- GR5-79: per-agent home station, set_home_station / rename_agent / dismiss_agent / set_tools and the editor controls.
local Sim = require("@scripts/sim/sim")
local Logistics = require("@scripts/sim/logistics")
local Market = require("@scripts/sim/market")
local Editor = require("@scripts/ui/agent_editor")
local Shell = require("@scripts/ui/shell")

local function game()
  local s = Sim.new()
  s:enterTier(3)
  s.lifetimeRevenue = 30000
  s.resources.credits = 300000
  assert(s:buyUpgrade("warehouse") and s:buyUpgrade("logistics_hub"))
  assert(s:buyUpgrade("engine_mk2") and s:buyUpgrade("engine_mk3"))
  Market.quiet(s.market)
  assert(s:buildOutpost("varn"))
  return s
end

local function veinNear(s, planet)
  for id, v in pairs(s.veins) do if v.planet == planet and not v.hidden then return id end end
end

-- 1. Home defaults to the main station; an outpost can be set; return(home) docks there; store fills that station's stock
do
  local s = game()
  local miner = s.agents.miner
  assert(miner.homeStation == s.home and s:homeOf("miner") == s.home, "default home is the main station")
  local ok, err = s:setHomeStation("miner", "nowhere"); assert(not ok and err == "unknown_station")
  ok, err = s:setHomeStation("ghost", "varn"); assert(not ok and err == "unknown agent")
  assert(s:setHomeStation("miner", "varn") and s:homeOf("miner") == "varn")
  local vein = veinNear(s, "varn")
  assert(vein, "a vein on varn")
  local ok2, why = s:apply("miner", { name = "mine", args = { vein = vein, ship = "s1", to = "home" } })
  assert(ok2 ~= false, tostring(why))
  local ship = s.ships.s1
  for _ = 1, 4000 do if ship.state == "mining" then break end s:step() end
  assert(ship.state == "mining", "mining, got " .. ship.state)
  -- a full hold sends the ship home on its own (the sim issues `return(home)` itself)
  local sawDest
  for _ = 1, 20000 do s:step(); if ship.state == "travel_back" then sawDest = sawDest or ship.dest end if ship.state == "idle" then break end end
  assert(sawDest == "varn", "return(home) goes to the home station: " .. tostring(sawDest))
  assert(ship.state == "idle" and ship.at == "varn", "docked at varn")
  local held, before = ship.cargo, s.stations.varn.stock[ship.ore]
  assert(held > 0)
  local ore = ship.ore
  assert(s:apply("miner", { name = "store", args = { resource = ore, ship = "s1" } }) ~= false)
  assert(s.stations.varn.stock[ore] == before + held, "store fills the outpost stock")
  assert(s.warehouse[ore] == 0, "the main warehouse is untouched")
  -- local_depot still means "where I am"; a removed home falls back to the main station
  s.agents.miner.homeStation = "gone"
  assert(s:homeOf("miner") == s.home)
end

-- 2. rename is display-only
do
  local s = game()
  local ok, err = s:renameAgent("miner", "  "); assert(not ok and err == "bad name")
  ok, err = s:renameAgent("miner", string.rep("x", 40)); assert(not ok and err == "bad name")
  assert(s:renameAgent("miner", " Ada "))
  assert(s:agentName("miner") == "Ada" and s.agents.miner and s.agents.miner.id == "miner" and s.agentOrder[1] == "miner")
  assert(s:validate("miner", { name = "wait", args = { seconds = 10 } }))
end

-- 3. dismiss frees command capacity; the last Miner stays; the ship is left unstaffed
do
  local s = game()
  local ok, err = s:dismissAgent("miner"); assert(not ok and err == "last_miner")
  local _, logi = Logistics.hire(s, "kessa")
  assert(logi and s.agents[logi])
  local n = #s.agentOrder
  assert(s:dismissAgent(logi))
  assert(#s.agentOrder == n - 1 and s.agents[logi] == nil)
  ok, err = s:dismissAgent(logi); assert(not ok and err == "unknown agent")
  -- a second Miner can go; its ship stays with no owner
  s:addAgent("miner_2", "miner")
  s:addShip("s2", "miner_2")
  assert(s:dismissAgent("miner_2") and s.ships.s2.owner == nil)
end

-- 4. set_tools: known tools only, within the slots; wait and run_skill are free
do
  local s = game()
  local ok, err = s:setTools("miner", { "mine", "teleport" }); assert(not ok and err:find("disallowed"))
  assert(s:setTools("miner", { "mine", "return", "wait" }))
  assert(s.agents.miner.tools.mine and not s.agents.miner.tools.sell)
  local ok2, why = s:validate("miner", { name = "sell", args = { ship = "s1" } })
  assert(not ok2, "sell is no longer equipped")
  local all = {}
  for _, t in ipairs(s.registry.agentTypes.miner.tools) do all[#all + 1] = t end
  local _, max = s:toolSlots("miner")
  local many = {}
  for i = 1, max + 1 do many[i] = "t" .. i end
  ok, err = s:setTools("miner", many); assert(not ok)
end

-- 5. The editor: model, controls, save round trip
do
  local s = game()
  local m = Editor.model(s, "miner")
  assert(m.team.home and m.team.home.station == s.home and m.team.name == "miner")
  local handled, ok = Editor.act(s, "miner", "editor.home.cycle")
  assert(handled and ok and s:homeOf("miner") == "varn")
  handled, ok = Editor.act(s, "miner", "editor.home.cycle")
  assert(handled and ok and s:homeOf("miner") == s.home, "cycles back to the main station")
  handled, ok = Editor.act(s, "miner", "editor.tool.sell")
  assert(handled and ok and not s.agents.miner.tools.sell)
  handled, ok = Editor.act(s, "miner", "editor.tool.sell")
  assert(handled and ok and s.agents.miner.tools.sell)
  local draft = Editor.newDraft(s, "miner")
  draft.name = "Ada"
  assert(Editor.model(s, "miner", draft).dirty)
  assert(Editor.save(s, "miner", draft) and s:agentName("miner") == "Ada")
  local f = Shell.editorFields()
  assert(f.name.w > 0)
  handled, ok = Editor.act(s, "miner", "editor.dismiss")
  assert(handled and ok == false, "the last Miner cannot be dismissed")
end

print("test_team: ok")
