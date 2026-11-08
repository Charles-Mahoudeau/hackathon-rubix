-- The raiding branch (spec §15b.4, B-c): the Privateer, its interceptor, the raid tools, the retaliation / Notoriety alerts and
-- the route / convoy_filter skill parameters, declared as data for sim/branches/registry.luau. The rules (convoys, combat,
-- Notoriety, standing) live in sim/raiding.luau. Numbers: config/branches.luau.
local C = require("@scripts/config/branches").raiding
local World = require("@scripts/config/world")
local Raiding = require("@scripts/sim/raiding")

local function str(desc, extra)
  local s = { type = "string", desc = desc }
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end

local schemas = {
  scan_route = { description = "Scan a freighter route for convoys (takes a few seconds).",
    args = { route = str("orange route", { required = true, enum = C.orangeRoutes }) } },
  intercept = { description = "Fly to a scanned convoy and match speed.",
    args = { convoy = { type = "any", required = true, desc = "convoy id from a scan, or a filter {max_escort, resources}" } } },
  attack = { description = "Attack the convoy you are alongside. Every interceptor alongside it joins.", args = {} },
  retreat = { description = "Break away from the convoy without a fight.", args = {} },
  repair = { description = "Repair the hull at the dock for credits.", args = {} },
}

local tools = {}
for name, tier in pairs(C.toolTiers) do tools[name] = { tier = tier, schema = schemas[name] } end

local function isOrange(v)
  for _, r in ipairs(C.orangeRoutes) do if r == v then return true end end
  return false
end

return {
  id = "raiding",
  name = C.name,
  scope = C.scope,
  unlock = { tier = C.unlock.tier, cost = C.unlock.cost },
  agent = { type = C.agentType, tools = C.agentTools, startTier = C.startTier, toolSlots = C.toolSlots,
    stub = { optimal = Raiding.stubOptimal, directive = Raiding.stubDirective },
    busy = Raiding.busy, skip = Raiding.skip, context = Raiding.context,
    at = function(sim, agent)
      local it = Raiding.interceptorFor(sim, agent.id)
      return it and it.at or sim.home
    end },
  asset = { type = C.assetType, label = C.assetLabel },
  tools = tools,
  alerts = { kinds = C.alertKinds, detect = Raiding.detect },
  paramKinds = {
    route = { check = function(_, name, v)
      if not isOrange(v) then return name .. ": must be an orange route" end
    end },
    convoy_filter = { check = function(_, name, v)
      if type(v) ~= "table" then return name .. ": must be a filter {max_escort, resources}" end
      if v.max_escort ~= nil and (type(v.max_escort) ~= "number" or v.max_escort < 0 or v.max_escort > 2) then
        return name .. ": max_escort must be 0-2"
      end
      if v.resources ~= nil then
        if type(v.resources) ~= "table" then return name .. ": resources must be a list" end
        for _, r in ipairs(v.resources) do
          if not World.ores[r] then return name .. ": unknown resource " .. tostring(r) end
        end
      end
    end },
  },
  onOpen = function(sim)
    sim:addAgent(C.agentType, C.agentType, { tier = sim.tier })
    Raiding.addInterceptor(sim, C.startInterceptor, C.agentType)
    sim.raid.mission.status = "active"
  end,
}
