-- ONE tunable balance table. No gameplay number lives anywhere else (world data is in world.luau).
-- Module: `local Balance = require("@scripts/config/balance")`. The returned table is read-only.
return {
  tickSeconds = 0.1,  -- spec §3: 10 Hz fixed step
  startCredits = 500, -- spec §6.1
  startCompute = 10,  -- spec §6.1
  startReputation = 0,
  resources = { "credits", "titanium", "cobalt", "iridium", "crystal", "compute", "reputation" },
  ores = { "titanium", "cobalt", "iridium", "crystal" },
  -- Base mining ship (spec §5.1): drill units/s at richness 1.0, hold in units, engine travel multiplier.
  ship = { drillRate = 2, cargoCap = 100, engineMult = 1.0, engineMark = 1, scanSeconds = 10 },
  waitMinSeconds = 10,
  waitMaxSeconds = 300,
  tiers = {
    -- tools unlocked per equipment tier
    [1] = { "mine", "return", "sell", "report", "wait", "run_skill" },
    [2] = { "scan" },
    [3] = { "store" },
    [4] = { "ship" },
  },
  agents = {
    miner = { tools = { "mine", "return", "sell", "report", "wait", "scan", "run_skill" }, startTier = 1 },
    logistician = { tools = { "store", "ship", "sell", "report", "wait", "run_skill" }, startTier = 1 },
  },
  ai = { delaySecondsMin = 2, delaySecondsMax = 4, vagueErrorRate = 0.5 }, -- Compute cost per decision: config/ai.luau
  warehouse = { capacity = 2000, unlockTier = 3 },
  logMax = 200,
  seed = 1234,
}
