-- Missions (spec §15): the tutorial. Numbers and words only; the checks live in sim/missions.luau, keyed by `check`.
-- One mission is active at a time, in order: a mission opens when the previous one is claimed and its `start` holds.
return {
  missions = {
    {
      id = 1, name = "Clear orders", check = "streak", -- starts with the game
      goal = "Complete 3 trips in a row, each ending in a sale with the hold at 80% or more, all from the same vein.",
      hint = "'Mine' is not an order. Say which ore, which vein, and when to come back.",
      trips = 3, holdPct = 80,
      reward = { credits = 300, compute = 5 },
    },
    {
      id = 2, name = "Look before you dig", check = "scout", start = { tier = 2 },
      goal = "Buy the scanner, have your agent call scan, then sell cargo mined at K4.",
      hint = "Equip `scan` and tell your agent to scan before choosing a vein.",
      vein = "K4",
      steps = { "Buy the scanner", "Agent calls scan", "Sell cargo mined at K4" },
      reward = { credits = 500 },
    },
    {
      id = 3, name = "Think less, earn more", check = "frugal", -- opens when mission 2 is claimed
      goal = "Earn 1,000 credits of revenue while spending 15 Compute or less.",
      hint = "Every decision costs Compute. Can a routine do the same job for free?",
      revenue = 1000, computeMax = 15,
      reward = { credits = 800 },
    },
    {
      id = 4, name = "Remember", check = "skillcredit", -- opens when mission 3 is claimed
      goal = "Save a skill, then earn 500 credits from skill steps (online or offline).",
      hint = "Skill steps cost no Compute. Save a routine that works, run it, and let it earn while you are away.",
      credits = 500,
      steps = { "Save a skill", "Earn credits from skill steps" },
      reward = { archiveSlot = 1 },
    },
    {
      id = 5, name = "Better buyers", check = "orbis", start = { upgrades = { "warehouse", "tradingPost" } },
      goal = "Sell 500 units to Orbis at a unit price of at least 1.5x the Kessa HMC price for that resource.",
      hint = "Turn Orbis prices on in the agent's context (watch the token cost), then tell it who to sell to.",
      units = 500, minRatio = 1.5, refPlanet = "kessa",
      reward = { credits = 2000 },
    },
    {
      id = 6, name = "Two pairs of hands", check = "teamwork", start = { ships = 2 },
      goal = "Over 10 game minutes, every Miner earns 1,000 credits or more and spends less than 10% of its mining time crowding another ship on a vein.",
      hint = "Two ships on one vein dig slower. Give each Miner its own vein, or make the vein a parameter of your skill.",
      minutes = 10, creditsEach = 1000, crowdMaxPct = 10,
      reward = { credits = 2000 },
    },
    {
      id = 7, name = "Divide the work", check = "divide", start = { logisticians = 2 },
      goal = "Over 15 game minutes, the two Logisticians of one station each complete 2 deliveries with no not_enough_stock or no_free_freighter error.",
      hint = "They share the same stock and freighters. Split the work: by resource, by destination, or let them message each other.",
      minutes = 15, deliveries = 2, errors = { "not_enough_stock", "no_free_freighter" },
      reward = { freighter = 1 },
    },
  },
}
