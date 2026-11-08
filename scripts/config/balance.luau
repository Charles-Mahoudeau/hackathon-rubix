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
  -- Tier 2 is entered when lifetime revenue reaches this (spec §6.6); other tiers come from their own purchases.
  tierRevenue = { [2] = 1500 },
  -- Tool slots per agent type (spec §8.1). `wait` and `run_skill` are free; every other equipped tool takes one slot.
  toolSlots = { miner = 5, logistician = 5 },
  freeTools = { wait = true, run_skill = true },
  -- Command capacity (spec §6.5): agents at once, all types, by Reputation level 0, 1, 2, ... (the last value holds above).
  commandCapacity = { 2, 5, 8, 12, 16 },
  -- Agents that exist from the start; the others (Logistician, ...) are hired once their building stands.
  startAgents = { "miner" },
  inboxKeep = 20, -- messages an agent's inbox keeps (its context shows the last Ai.inboxMax)
  -- Shop (spec §6.5, D22): costs in cr. `mark` upgrades are bought in order and apply to every mining ship.
  -- stat: drill (units/s at richness 1), hold (units), engine (travel multiplier; the mark sets range), scanner, archive, ship.
  -- `tier` on an item overrides the shop's; `needs` is another item that must be owned; `rep` a Reputation level.
  shop = {
    tier = 2,
    order = { "drill_mk2", "drill_mk3", "hold_mk2", "hold_mk3", "engine_mk2", "engine_mk3", "scanner", "archive", "ship2",
      "warehouse", "trading_post", "logistics_hub", "deep_nav", "ship3", "ship4" },
    items = {
      drill_mk2 = { name = "Drill Mk2", stat = "drill", mark = 2, cost = 1200, value = 3, desc = "Drill 2 -> 3 u/s" },
      drill_mk3 = { name = "Drill Mk3", stat = "drill", mark = 3, cost = 4000, value = 5, desc = "Drill 3 -> 5 u/s" },
      hold_mk2 = { name = "Hold Mk2", stat = "hold", mark = 2, cost = 1500, value = 200, desc = "Hold 100 -> 200" },
      hold_mk3 = { name = "Hold Mk3", stat = "hold", mark = 3, cost = 5000, value = 400, desc = "Hold 200 -> 400" },
      engine_mk2 = { name = "Engine Mk2", stat = "engine", mark = 2, cost = 1000, value = 0.7, desc = "Travel x0.7, reaches Varn" },
      engine_mk3 = { name = "Engine Mk3", stat = "engine", mark = 3, cost = 3500, value = 0.5, desc = "Travel x0.5, reaches Ashfall" },
      scanner = { name = "Scanner", stat = "scanner", cost = 800, desc = "Unlocks the scan tool (takes 1 tool slot)" },
      archive = { name = "Archive slot", stat = "archive", cost = 1000, max = 3, desc = "+1 skill slot per agent" },
      ship2 = { name = "Mining ship #2", stat = "ship", cost = 6000, n = 1, desc = "+1 ship and an empty Miner agent" },
      ship3 = { name = "Mining ship #3", stat = "ship", cost = 15000, n = 2, tier = 3, needs = "ship2", desc = "+1 ship and an empty Miner agent" },
      ship4 = { name = "Mining ship #4", stat = "ship", cost = 35000, n = 3, tier = 4, needs = "ship3", desc = "+1 ship and an empty Miner agent" },
      -- spec §6.5: the warehouse is bought at T2 and starts T3; the trading post needs it.
      warehouse = { name = "Warehouse", stat = "warehouse", cost = 10000, desc = "Home dock, storage 2,000, store tool, +2 skill slots" },
      trading_post = { name = "Trading post", stat = "tradingPost", cost = 4000, needs = "warehouse", desc = "Sell to Orbis, Orbis prices in context" },
      -- spec §6.5: Warehouse + Reputation 1; enters T4 (freighters, `ship`, Logistician, Halcyon and Meridian).
      logistics_hub = { name = "Logistics hub", stat = "hub", cost = 20000, needs = "warehouse", rep = 1, desc = "Tier 4: freighters, ship tool, Logistician, Halcyon, Meridian" },
      deep_nav = { name = "Deep-range nav", stat = "deepNav", cost = 8000, tier = 4, needs = "engine_mk3", desc = "Reach Lumen Rift" },
    },
  },
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
    miner = { tools = { "mine", "return", "sell", "store", "report", "wait", "scan", "run_skill" }, startTier = 1 },
    logistician = { tools = { "ship", "sell", "report", "wait", "run_skill" }, startTier = 1 },
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
  -- Stations and freighters (spec §5.2, §6.5, §7, D21). A station hosts `freighters` freighters (+hangarSlots per hangar
  -- extension) and up to `logisticiansPerStation` Logisticians. The main station gets its freighter room from the hub.
  logistics = {
    hubTier = 4,
    freighterCost = 6000, hangarCost = 8000, hangarSlots = 2,
    mainFreighters = 2,
    outpostCost = 12000, outpostStorage = 1000, outpostFreighters = 2, outpostTier = 4,
    logisticiansPerStation = 2,
    cooldownSeconds = 10, -- a Logistician decides again this long after any call but `wait`
    stub = { minStock = 300, waitSeconds = 60 }, -- spec §10.5: the stub ships once a stock reaches this
  },
  warehouse = { capacity = 2000, unlockTier = 3, extraSkillSlots = 2 },
  -- Skills (spec §13): name length, recording length, steps per skill, the shortest loop and the Compute needed to wake the AI.
  skills = { nameMax = 24, recordMin = 2, recordMax = 8, stepsMax = 12, minLoopSeconds = 5, wakeMinCompute = 1,
    -- Values the skill form cycles through for number-like args (spec §13.3: dropdowns and number fields, no free text).
    form = { pctOptions = { 50, 70, 90, 100 }, qtyOptions = { "all", 50, 100, 500 }, waitOptions = { 10, 30, 60, 120 }, guardPrices = { 8, 12, 20, 30, 60 } } },
  -- Offline progress (spec §14): at most maxHours simulated, an absence under minAwaySeconds is ignored.
  offline = { maxHours = 8, minAwaySeconds = 60 },
  reputationLevels = { 25000, 75000, 200000, 500000, 1200000 }, -- spec §6.7: lifetime revenue for Rep 1..5
  -- Game speed (spec §3). `aiMinRealSeconds`: above x1 a real AI provider may not get a new request from the same agent
  -- sooner than this many real seconds (the x1 steady state of the thrashing guard: 30 s / 5 decisions), so x16 cannot
  -- raise the real request rate. `maxStepsPerFrame` bounds the catch-up after a stall (the excess game time is dropped).
  speed = { levels = { 1, 4, 16 }, default = 1, aiMinRealSeconds = 6, maxStepsPerFrame = 400 },
  logMax = 200,
  seed = 1234,
}
