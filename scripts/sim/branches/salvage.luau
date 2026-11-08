-- The salvage branch (spec §15b.3, B-a): the Scavenger, its survey / salvage tools, the site alerts and the site skill
-- parameter, declared as data for sim/branches/registry.luau. The rules (sites, hazards, loot, blueprints, stub) live in
-- sim/salvage.luau. Numbers: config/branches.luau.
local C = require("@scripts/config/branches").salvage
local Salvage = require("@scripts/sim/salvage")

local schemas = {
  survey = { description = "Fly to a salvage site and survey it: type, danger and the loot band of each layer (bands can be off by one step).",
    args = { site = { type = "string", required = true, desc = "site id, e.g. S1" } } },
  salvage = { description = "Fly to a salvage site and strip one layer into the hold. Layer n needs layer n-1 done; a hazard can damage the hull.",
    args = {
      site = { type = "string", required = true, desc = "site id, e.g. S1" },
      layer = { type = "number", required = true, desc = "layer 1-3" },
    } },
}

local tools = {}
for name, tier in pairs(C.toolTiers) do tools[name] = { tier = tier, schema = schemas[name] } end

return {
  id = "salvage",
  name = C.name,
  scope = C.scope,
  unlock = { tier = C.unlock.tier, cost = C.unlock.cost, needs = C.unlock.needs },
  agent = { type = C.agentType, tools = C.agentTools, startTier = C.startTier, toolSlots = C.toolSlots,
    stub = { optimal = Salvage.stubOptimal, directive = Salvage.stubDirective },
    busy = Salvage.busy, skip = Salvage.skip, context = Salvage.context,
    at = function(sim, agent)
      local ship = Salvage.shipFor(sim, agent.id)
      return ship and ship.at or sim.home
    end },
  asset = { type = C.assetType, label = C.assetLabel },
  tools = tools,
  alerts = { kinds = C.alertKinds, detect = Salvage.detect },
  paramKinds = {
    site = { check = function(_, name, v)
      if type(v) ~= "string" or not v:match("^S%d+$") then return name .. ": must be a site id like S1" end
    end },
  },
  onOpen = Salvage.onOpen,
}
