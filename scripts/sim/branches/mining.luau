-- The mining branch (spec §15b.0, B-0): the Miner, its mining ship, the mining tools, the crowding alert and the vein /
-- resource / pct skill parameters, declared as data for sim/branches/registry.luau. The mining rules themselves (mine,
-- return, sell, store, scan, drilling) run in sim/sim.luau. Numbers: config/branches.luau.
local C = require("@scripts/config/branches").mining
local Refined = require("@scripts/config/branches").refining
local World = require("@scripts/config/world")
local Ai = require("@scripts/sim/ai")

local tools = {}
for name, tier in pairs(C.toolTiers) do tools[name] = { tier = tier } end

-- One alert per vein shared by two or more ships for crowdingSeconds (spec §8.7).
local function detectCrowding(sim, c, raise)
  local tr, byVein = sim.alertTrack.veins, sim:minersByVein()
  for vid, ships in pairs(byVein) do
    if #ships >= 2 then
      local t = tr[vid]
      if not t then t = { since = sim.tick }; tr[vid] = t end
      if not t.raised and sim.tick - t.since >= sim:ticks(c.crowdingSeconds) then
        t.raised = true
        local ids = {}
        for _, s in ipairs(ships) do ids[#ids + 1] = s.id end
        raise(sim, "crowding", ships[1].owner, ("vein %s shared by %s"):format(vid, table.concat(ids, ",")))
      end
    end
  end
  for vid in pairs(tr) do
    if not byVein[vid] or #byVein[vid] < 2 then tr[vid] = nil end
  end
end

return {
  id = "mining",
  name = C.name,
  scope = C.scope,
  unlock = { startsOpen = C.startsOpen },
  agent = { type = C.agentType, tools = C.agentTools, startTier = C.startTier, toolSlots = C.toolSlots,
    stub = { optimal = Ai.minerOptimal, directive = Ai.minerDirective } },
  asset = { type = C.assetType, label = C.assetLabel },
  tools = tools,
  alerts = { kinds = C.alertKinds, detect = detectCrowding },
  paramKinds = {
    vein = { check = function(sim, name, v, decl)
      local f = decl.filter or {}
      local vein = sim.veins[v]
      if not vein then return name .. ": unknown vein" end
      if f.resource and vein.ore ~= f.resource then return name .. ": must be a " .. f.resource .. " vein" end
      if f.planet and vein.planet ~= f.planet then return name .. ": must be a vein on " .. f.planet end
    end },
    resource = { check = function(sim, name, v)
      -- a Logistician skill may also move the refined goods of the refining branch
      if not World.ores[v] and not Refined.recipes[v] then return name .. ": unknown resource" end
    end },
    pct = { check = function(sim, name, v)
      if type(v) ~= "number" or v < 10 or v > 100 then return name .. ": must be 10-100" end
    end },
  },
  onOpen = function(sim)
    sim:addAgent(C.agentType, C.agentType)
    sim:addShip(C.startShip, C.agentType)
  end,
}
