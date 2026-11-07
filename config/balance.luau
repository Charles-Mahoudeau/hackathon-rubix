-- ONE tunable balance table. No gameplay number lives anywhere else.
local balance = {
  tickSeconds = 0.1,  -- spec §7: 10 Hz fixed step
  startCredits = 100,
  startCompute = 50,
  startReputation = 0,
  resources = { "credits", "titanium", "cobalt", "compute", "reputation" },
  ores = { "titanium", "cobalt" },
  jumpSeconds = 5,          -- game seconds per jump (converted to ticks by the sim)
  ship = { cargoCap = 20, mineRatePerSecond = 1.0, scanCost = 2, scanSeconds = 3 },
  tiers = {
    -- tools unlocked per equipment tier
    [1] = { "mine", "return", "sell", "report", "run_skill" },
    [2] = { "scan" },
    [3] = { "store" },
    [4] = { "ship" },
  },
  agents = {
    miner = { tools = { "mine", "return", "sell", "report", "scan", "run_skill" }, startTier = 1 },
    logistician = { tools = { "store", "ship", "report", "run_skill" }, startTier = 1 },
  },
  ai = { delaySecondsMin = 2, delaySecondsMax = 4, computePerDecision = 1, vagueErrorRate = 0.5 },
  warehouse = { capacity = 200 },
  logMax = 200,
  seed = 1234,
}
return balance
