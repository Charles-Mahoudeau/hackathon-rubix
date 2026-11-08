-- ContextBuilder (spec §9.2 step 1): the data an agent sees, filtered by its context settings (§9.3).
-- Reads the sim, never writes it. Output goes to ContextRenderer (see context_renderer.luau for the data shape).
local World = require("@scripts/config/world")
local Ai = require("@scripts/config/ai")
local Renderer = require("./context_renderer")
local Market = require("./market")
local Logistics = require("./logistics")

local Builder = {}

local map = Renderer.map

local function clock(sim)
  local s = math.floor(sim.tick * sim.b.tickSeconds)
  return ("%02d:%02d:%02d"):format(s // 3600, (s // 60) % 60, s % 60)
end

local function round1(x) return math.floor(x * 10 + 0.5) / 10 end

local function oreMap(prices)
  local pairs_ = {}
  for _, ore in ipairs(World.oreOrder) do
    if prices[ore] then pairs_[#pairs_ + 1] = { ore, prices[ore] } end
  end
  return map(pairs_)
end

local function sortedPairs(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do
    local v = t[k]
    if type(v) == "table" then v = sortedPairs(v) end
    out[#out + 1] = { k, v }
  end
  return map(out)
end

local function shipSection(sim, ship)
  local hold = {}
  if ship.cargo > 0 and ship.ore then hold[1] = { ship.ore, ship.cargo } end
  local range = {}
  for _, id in ipairs(World.planetOrder) do
    if sim:inRange(ship, id) then range[#range + 1] = id end
  end
  local at = ship.vein and (ship.vein.id .. "@" .. ship.at) or ship.at
  return { key = "ship", kind = "object", fields = {
    { "at", at }, { "hold", map(hold) }, { "cap", ship.cargoCap },
    { "hold%", math.floor(ship.cargo * 100 / ship.cargoCap) },
    { "drill", ship.drillRate }, { "engine", ship.engineMult }, { "range", range } } }
end

local function veinRows(sim, ship, mode)
  local rows = {}
  local function add(v)
    local known = (not v.hidden) or v.scanned
    if not known then return end
    local rich = v.scanned and ("%.1f"):format(v.richness) or sim:richnessBand(v.richness)
    local pct = v.scanned and math.floor(v.reserve * 100 / v.max) or nil
    local travel = math.floor((World.travel[ship.at][v.planet] + World.jumpSeconds * v.jumps) * ship.engineMult + 0.5)
    rows[#rows + 1] = { v.id, v.planet, v.ore, rich, v.jumps, pct, travel }
  end
  if mode == "vein" then
    if ship.vein then add(ship.vein) end
  elseif mode == "planet" then
    for _, v in ipairs(sim.planets[ship.at].veins) do add(v) end
  else
    for _, pid in ipairs(World.planetOrder) do
      if sim:inRange(ship, pid) then for _, v in ipairs(sim.planets[pid].veins) do add(v) end end
    end
  end
  return rows
end

-- `ship` may be nil (a station agent): its own planet then stands for the current location.
local function priceSubs(sim, ship, s, planet)
  local subs = {}
  if s.prices_hmc ~= "off" then
    for _, pid in ipairs(World.planetOrder) do
      if (s.prices_hmc == "all" and (not ship or sim:inRange(ship, pid))) or (s.prices_hmc == "current" and pid == (ship and ship.at or planet)) then
        local p = {}
        for _, ore in ipairs(World.oreOrder) do p[ore] = round1(World.planets[pid].depotRate * World.ores[ore].basePrice) end
        subs[#subs + 1] = { "hmc@" .. pid, oreMap(p) }
      end
    end
  end
  local wanted = { orbis = s.prices_orbis, halcyon = s.prices_halcyon, meridian = s.prices_meridian }
  for _, mid in ipairs(World.marketOrder) do
    if wanted[mid] and sim:marketUnlocked(mid) then
      local p = {}
      for ore in pairs(World.markets[mid].demand) do
        local price = round1(Market.price(sim.market, mid, ore))
        -- Price trends add the usual price next to the price so the agent can tell a spike from a trend.
        p[ore] = s.price_trends and ("%s~%s"):format(Renderer.fmtNum(price), Renderer.fmtNum(round1(Market.usual(sim.market, mid, ore)))) or price
      end
      subs[#subs + 1] = { mid, oreMap(p) }
    end
  end
  return subs
end

local function recentRows(agent, n)
  local rows, h = {}, agent.history
  for i = math.max(1, #h - n + 1), #h do
    local e = h[i]
    rows[#rows + 1] = { e.tool, sortedPairs(e.args or {}), e.ok, sortedPairs(e.result or {}) }
  end
  return rows
end

local builders = {}

local function inboxList(agent, s)
  local inbox = {}
  if s.inbox then
    for i = math.max(1, #agent.inbox - Ai.inboxMax + 1), #agent.inbox do inbox[#inbox + 1] = agent.inbox[i] end
  end
  return inbox
end

function builders.miner(sim, agent, s)
  local ship = sim:ownedShip(agent.id)
  local data = {
    { key = "time", kind = "scalar", value = clock(sim) },
    shipSection(sim, ship),
    { key = "veins", kind = "table", cols = { "id", "planet", "res", "rich", "jumps", "res%", "travel_s" },
      rows = veinRows(sim, ship, s.veins) },
    { key = "prices", kind = "maps", subs = priceSubs(sim, ship, s) },
  }
  local warehouseOn = s.warehouse and sim:hasWarehouse()
  if warehouseOn then
    data[#data + 1] = { key = "station", kind = "object",
      fields = { { "id", "main@" .. sim.home }, { "cap", sim.b.warehouse.capacity } } }
    local stock = {}
    for _, ore in ipairs(World.oreOrder) do
      if sim.warehouse[ore] > 0 then stock[#stock + 1] = { ore, sim.warehouse[ore] } end
    end
    table.sort(stock, function(a, b) return a[1] < b[1] end)
    data[#data + 1] = { key = "stock", kind = "map", map = map(stock) }
  end
  data[#data + 1] = { key = "recent", kind = "table", cols = { "tool", "args", "ok", "result" },
    rows = recentRows(agent, s.recent_results) }
  data[#data + 1] = { key = "inbox", kind = "strings", items = inboxList(agent, s) }
  data[#data + 1] = { key = "credits", kind = "scalar", value = sim.resources.credits }
  data[#data + 1] = { key = "compute", kind = "scalar", value = round1(sim.resources.compute) }
  return data
end

-- Spec §9.2.3: time, station, stock, freighters, others_here, prices, recent, inbox, credits, compute.
function builders.logistician(sim, agent, s)
  local st = sim.stations[agent.station]
  local stock = {}
  for _, ore in ipairs(World.oreOrder) do
    if st.stock[ore] > 0 then stock[#stock + 1] = { ore, st.stock[ore] } end
  end
  local rows = {}
  for _, r in ipairs(Logistics.freighterRows(sim, st.id)) do
    rows[#rows + 1] = { r.id, r.state, r.cargo or "-", r.dest or "-", r.eta or "-" }
  end
  local others = {}
  for _, id in ipairs(Logistics.logisticiansAt(sim, st.id)) do if id ~= agent.id then others[#others + 1] = id end end
  local subs = priceSubs(sim, nil, { prices_hmc = "off", prices_orbis = s.prices_orbis, prices_halcyon = s.prices_halcyon,
    prices_meridian = s.prices_meridian, price_trends = s.price_trends }, st.planet)
  return {
    { key = "time", kind = "scalar", value = clock(sim) },
    { key = "station", kind = "object", fields = { { "id", Logistics.label(st) }, { "cap", Logistics.storageCap(sim, st) } } },
    { key = "stock", kind = "map", map = map(stock) },
    { key = "freighters", kind = "table", cols = { "id", "state", "cargo", "dest", "eta_s" }, rows = rows },
    { key = "others_here", kind = "scalar", value = others },
    { key = "prices", kind = "maps", subs = subs },
    { key = "recent", kind = "table", cols = { "tool", "args", "ok", "result" }, rows = recentRows(agent, s.recent_results) },
    { key = "inbox", kind = "strings", items = inboxList(agent, s) },
    { key = "credits", kind = "scalar", value = sim.resources.credits },
    { key = "compute", kind = "scalar", value = round1(sim.resources.compute) },
  }
end

-- -> ordered context data for `agentId` under `settings` (defaults to the agent's own settings).
function Builder.build(sim, agentId, settings)
  local agent = sim.agents[agentId]
  local build = builders[agent and agent.type or agentId]
  if not agent or not build then return {} end
  return build(sim, agent, settings or agent.contextSettings)
end

return Builder
