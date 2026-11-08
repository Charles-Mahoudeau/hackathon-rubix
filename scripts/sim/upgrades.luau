-- Shop upgrades (spec §6.5, D22). State lives in `sim.upgrades`; drill/hold/engine are fleet-wide, so every mining ship
-- (also one bought later) gets its stats from here. Pure sim logic: the shop screen only calls buy() and reads catalog().
local Upgrades = {}

function Upgrades.new()
  return { drill = 1, hold = 1, engine = 1, scanner = false, archive = 0, ships = 0, warehouse = false, tradingPost = false,
    hub = false, deepNav = false, commandCenter = false }
end

local function item(sim, id) return sim.b.shop.items[id] end

-- Stats of a mining ship from the base ship table and the marks owned.
function Upgrades.applyToShip(sim, ship)
  local base, up = sim.b.ship, sim.upgrades
  ship.drillRate, ship.cargoCap, ship.engineMult, ship.engineMark = base.drillRate, base.cargoCap, base.engineMult, base.engineMark
  for _, id in ipairs(sim.b.shop.order) do
    local it = item(sim, id)
    if it.mark and up[it.stat] >= it.mark then
      if it.stat == "drill" then ship.drillRate = it.value
      elseif it.stat == "hold" then ship.cargoCap = it.value
      elseif it.stat == "engine" then ship.engineMult, ship.engineMark = it.value, it.mark end
    end
  end
end

function Upgrades.applyToFleet(sim)
  for _, id in ipairs(sim.shipOrder) do Upgrades.applyToShip(sim, sim.ships[id]) end
end

function Upgrades.commandCapacity(sim)
  local c = sim.b.commandCapacity
  return c[math.min(#c, sim:reputationLevel() + 1)]
end

local function owned(sim, it)
  local up = sim.upgrades
  if it.mark then return up[it.stat] >= it.mark end
  if it.stat == "scanner" then return up.scanner end
  if it.stat == "archive" then return up.archive >= it.max end
  if it.stat == "warehouse" then return up.warehouse end
  if it.stat == "tradingPost" then return up.tradingPost end
  if it.stat == "hub" then return up.hub == true end
  if it.stat == "deepNav" then return up.deepNav == true end
  if it.stat == "commandCenter" then return up.commandCenter == true end
  return up.ships >= it.n
end

function Upgrades.owns(sim, id)
  local it = item(sim, id)
  return it ~= nil and owned(sim, it)
end

-- Why `id` cannot be bought now, or nil: tier_locked | already_owned | needs_<previous> | reputation_<n> | not_enough_credits.
function Upgrades.blocker(sim, id)
  local it = item(sim, id)
  if not it then return "unknown_item" end
  if sim.tier < (it.tier or sim.b.shop.tier) then return "tier_locked" end
  if owned(sim, it) then return "already_owned" end
  if it.mark and sim.upgrades[it.stat] < it.mark - 1 then
    for _, other in ipairs(sim.b.shop.order) do
      local o = item(sim, other)
      if o.stat == it.stat and o.mark == it.mark - 1 then return "needs_" .. other end
    end
  end
  if it.needs and not owned(sim, item(sim, it.needs)) then return "needs_" .. it.needs end
  if it.rep and sim:reputationLevel() < it.rep then return "reputation_" .. it.rep end
  if sim.resources.credits < it.cost then return "not_enough_credits" end
  return nil
end

-- One row per shop item, in display order: { id, name, desc, cost, state = "owned"|"available"|"locked"|"unaffordable", blocker, count, max }.
function Upgrades.catalog(sim)
  local rows = {}
  for _, id in ipairs(sim.b.shop.order) do
    local it = item(sim, id)
    local why = Upgrades.blocker(sim, id)
    local state = "available"
    if why == "already_owned" then state = "owned"
    elseif why == "not_enough_credits" then state = "unaffordable"
    elseif why then state = "locked" end
    local count = it.stat == "archive" and sim.upgrades.archive or nil
    rows[#rows + 1] = { id = id, name = it.name, desc = it.desc, cost = it.cost, state = state, blocker = why, count = count, max = it.max,
      tier = it.tier or sim.b.shop.tier }
  end
  return rows
end

-- A Miner agent for a ship nobody commands, when the command capacity has room (spec §5.3).
function Upgrades.claimShips(sim)
  for _, sid in ipairs(sim.shipOrder) do
    local ship = sim.ships[sid]
    if not ship.owner and #sim.agentOrder < Upgrades.commandCapacity(sim) then
      local n = 1
      while sim.agents["miner" .. (n + 1)] do n += 1 end
      local id = "miner" .. (n + 1)
      sim:addAgent(id, "miner", { tier = sim.tier })
      ship.owner = id
      sim:log("INFO", ("%s: new Miner agent for %s (empty directive)"):format(id, sid))
      sim:emit("agent_added", { agent = id, ship = sid })
    end
  end
end

function Upgrades.buy(sim, id)
  local why = Upgrades.blocker(sim, id)
  if why then
    sim:log("ERROR", ("shop: cannot buy %s (%s)"):format(tostring(id), why))
    return false, why
  end
  local it = item(sim, id)
  local up = sim.upgrades
  sim.resources.credits = sim.resources.credits - it.cost
  if it.mark then up[it.stat] = it.mark
  elseif it.stat == "scanner" then up.scanner = true
  elseif it.stat == "archive" then up.archive += 1
  elseif it.stat == "warehouse" then
    up.warehouse = true
    sim:enterTier(3)
  elseif it.stat == "tradingPost" then up.tradingPost = true
  elseif it.stat == "hub" then
    up.hub = true
    sim:enterTier(sim.b.logistics.hubTier)
  elseif it.stat == "commandCenter" then
    up.commandCenter = true
    sim:enterTier(sim.b.monitor.tier)
  elseif it.stat == "deepNav" then
    up.deepNav, sim.deepNav = true, true
  elseif it.stat == "ship" then
    up.ships += 1
    local n = #sim.shipOrder + 1
    sim:addShip("s" .. n, nil)
  end
  Upgrades.applyToFleet(sim)
  Upgrades.claimShips(sim)
  sim:log("INFO", ("shop: bought %s for %d cr"):format(it.name, it.cost))
  sim:emit("upgrade_bought", { id = id })
  return true
end

return Upgrades
