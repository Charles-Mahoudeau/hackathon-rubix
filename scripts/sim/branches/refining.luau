-- The refining branch (spec §15b.2, B-b): the Refiner, its refine tool and the recipe skill parameter, declared as data for
-- sim/branches/registry.luau. The rules (refineries, jobs, margins, stub) live in sim/refining.luau. Numbers: config/branches.luau.
local C = require("@scripts/config/branches").refining
local Refining = require("@scripts/sim/refining")

local schemas = {
  refine = { description = "Refine goods from the station stock at your refinery (one job at a time).",
    args = {
      recipe = { type = "string", required = true, desc = "recipe to run", enum = C.recipeOrder },
      qty = { type = "number", required = true, desc = ("output units, %d-%d"):format(C.qtyMin, C.qtyMax) },
    } },
}

local tools = {}
for name, tier in pairs(C.toolTiers) do tools[name] = { tier = tier, schema = schemas[name] } end

return {
  id = "refining",
  name = C.name,
  scope = C.scope,
  unlock = { tier = C.unlock.tier, cost = C.unlock.cost, needs = C.unlock.needs },
  agent = { type = C.agentType, tools = C.agentTools, startTier = C.startTier, toolSlots = C.toolSlots,
    stub = { optimal = Refining.stubOptimal, directive = Refining.stubDirective },
    busy = Refining.busy, skip = Refining.skip, context = Refining.context,
    at = function(sim, agent)
      local ref = Refining.refineryFor(sim, agent.id)
      return ref and ref.station or sim.home
    end },
  asset = { type = C.assetType, label = C.assetLabel },
  tools = tools,
  alerts = { kinds = C.alertKinds, detect = function() end },
  paramKinds = {
    recipe = { check = function(_, name, v)
      if type(v) ~= "string" or not C.recipes[v] then return name .. ": must be a recipe (" .. table.concat(C.recipeOrder, ", ") .. ")" end
    end },
  },
  onOpen = Refining.onOpen,
}
