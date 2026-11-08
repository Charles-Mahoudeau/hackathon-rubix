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
  ai = {
    delaySecondsMin = 2, delaySecondsMax = 4, vagueErrorRate = 0.5, -- Compute cost per decision: config/ai.luau
    thrashMaxDecisions = 5, thrashWindowSeconds = 30, -- spec §8.3: max decisions per agent per window of game time
  },
  skillSlots = { [1] = 1 }, -- spec D1: skill slots per agent by tier (1 from T1); assignment is GR5-10
  crowding = { perExtraShip = 0.5 }, -- spec §5.1: each ship on a shared vein mines at 1 / (1 + perExtraShip x (n - 1))
  -- spec §8.5: the only free Compute in the game
  bailout = { computeBelow = 2, creditsBelow = 200, grantCompute = 3, cooldownSeconds = 300 },
  freighter = { cargo = 500 }, -- spec §5.2
  warehouse = { capacity = 2000, unlockTier = 3 },
  reputationLevels = { 25000, 75000, 200000, 500000, 1200000 }, -- spec §6.7: lifetime revenue for Rep 1..5
  logMax = 200,
  seed = 1234,
}
