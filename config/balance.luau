-- ONE tunable balance table. No gameplay number lives anywhere else.
local balance = {
  tickSeconds = 1,
  startCredits = 100,
  startCompute = 50,
  startReputation = 0,
  resources = { "credits", "titanium", "cobalt", "compute", "reputation" },
  ores = { "titanium", "cobalt" },
  jumpTicks = 5,            -- ticks per jump
  veinCount = 4,
  veinRichnessMin = 0.5,
  veinRichnessMax = 1.5,
  planets = {
    { id = "meridian", name = "Meridian Base", kind = "trade", jumps = 0, tier = 1,
      prices = { titanium = 10, cobalt = 14 } },
    { id = "kessel", name = "Kessel", kind = "harvest", jumps = 2, tier = 1, ore = "titanium", oreBonus = 1.3 },
    { id = "vanta", name = "Vanta", kind = "harvest", jumps = 4, tier = 1, ore = "cobalt", oreBonus = 1.3 },
    { id = "halcyon", name = "Halcyon Port", kind = "trade", jumps = 5, tier = 4,
      prices = { titanium = 14, cobalt = 20 } },
  },
  startBuyer = "meridian",
  ship = { cargoCap = 20, mineRate = 1.0, scanCost = 2, scanTicks = 3 },
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
  ai = { delayMin = 2, delayMax = 4, computePerDecision = 1, vagueErrorRate = 0.5 },
  warehouse = { capacity = 200 },
  logMax = 200,
  seed = 1234,
}
return balance
