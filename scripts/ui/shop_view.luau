-- Shop screen view-model (GR5-7, spec §6.5): one row per upgrade with its state and the click action that buys it.
-- Pure reads and sim calls, so the whole path is testable headless; the shell only lays the rows out.
local Upgrades = require("@scripts/sim/upgrades")
local Screens = require("@scripts/config/screens")

local View = {}

local BLOCKERS = {
  already_owned = "Owned",
  not_enough_credits = "Not enough credits",
}

local function blockerText(rows, row)
  local blocker: string? = row.blocker
  if not blocker then return nil end
  if blocker == "tier_locked" then return "Reach tier " .. row.tier end
  local rep = blocker:match("^reputation_(%d+)$")
  if rep then return "Needs Reputation " .. rep end
  local previous = blocker:match("^needs_(.+)$")
  if previous then
    for _, r in ipairs(rows) do if r.id == previous then return "Needs " .. r.name end end
  end
  return BLOCKERS[blocker] or blocker
end

function View.model(sim)
  local rows = Upgrades.catalog(sim)
  for _, r in ipairs(rows) do
    r.costText = ("%d cr"):format(r.cost)
    r.action = "shop.buy." .. r.id
    r.note = blockerText(rows, r)
    if r.count and r.max then r.name = ("%s (%d/%d)"):format(r.name, r.count, r.max) end
  end
  local slots = {}
  for _, id in ipairs(sim.agentOrder) do
    local a = sim.agents[id]
    if a.type == "miner" then
      local used, max = sim:toolSlots(id)
      slots[#slots + 1] = { agent = id, used = used, max = max, text = ("%s tools %d/%d"):format(id, used, max) }
    end
  end
  local fleet = {}
  for _, sid in ipairs(sim.shipOrder) do
    local s = sim.ships[sid]
    fleet[#fleet + 1] = { id = sid, owner = s.owner, text = ("%s  drill %g u/s  hold %d  engine x%g"):format(sid, s.drillRate, s.cargoCap, s.engineMult) }
  end
  for _, id in ipairs(sim.interceptorOrder) do
    local it = sim.interceptors[id]
    fleet[#fleet + 1] = { id = id, owner = it.owner, text = ("%s  attack %d  hull %d/%d  hold %d"):format(id, it.attack, it.hull, it.hullMax, it.cap) }
  end
  for _, id in ipairs(sim.salvageOrder) do
    local ship = sim.salvageShips[id]
    fleet[#fleet + 1] = { id = id, owner = ship.owner, text = ("%s  hull %d/%d  hold %d"):format(id, ship.hull, ship.hullMax, ship.cap) }
  end
  return { rows = rows, slots = slots, fleet = fleet, credits = math.floor(sim.resources.credits), tier = sim.tier }
end

-- One string that changes when what the shop shows changes.
function View.signature(sim)
  local parts = {}
  for _, r in ipairs(Upgrades.catalog(sim)) do parts[#parts + 1] = r.id .. r.state .. tostring(r.count or "") end
  return table.concat(parts, ",")
end

-- "shop.buy.<id>" -> handled, ok, err.
function View.act(sim, action)
  if type(action) ~= "string" then return false end
  local id = action:match("^shop%.buy%.([%w_]+)$")
  if not id then return false end
  return true, sim:buyUpgrade(id)
end

return View
