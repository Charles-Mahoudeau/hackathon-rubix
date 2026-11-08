-- Missions (spec §15): the tutorial. Numbers and words only; the checks live in sim/missions.luau, keyed by `check`.
-- One mission is active at a time, in order: a mission opens when the previous one is claimed and its `start` holds.
return {
  missions = {
    {
      id = 1, name = "Clear orders", check = "streak", -- starts with the game
      brief = { "Sell three trips in a row.", "Use one vein and fill at least 80%." },
      hint = "Name the ore, vein and return point.",
      trips = 3, holdPct = 80,
      reward = { credits = 300, compute = 5 },
    },
    {
      id = 2, name = "Look before you dig", check = "scout", start = { tier = 2 },
      brief = { "Buy a scanner and scan.", "Sell cargo mined at K4." },
      hint = "Equip scan before choosing a vein.",
      vein = "K4",
      steps = { "Buy the scanner", "Agent calls scan", "Sell cargo mined at K4" },
      reward = { credits = 500 },
    },
    {
      id = 3, name = "Think less, earn more", check = "frugal", -- opens when mission 2 is claimed
      brief = { "Earn 1,000 credits of revenue.", "Spend at most 15 Compute." },
      hint = "A routine can save decisions.",
      revenue = 1000, computeMax = 15,
      reward = { credits = 800 },
    },
    {
      id = 4, name = "Remember", check = "skillcredit", -- opens when mission 3 is claimed
      brief = { "Save a skill.", "Earn 500 credits from skill steps." },
      hint = "Save a successful trip as a skill.",
      credits = 500,
      steps = { "Save a skill", "Earn credits from skill steps" },
      reward = { archiveSlot = 1 },
    },
    {
      id = 5, name = "Better buyers", check = "orbis", start = { upgrades = { "warehouse", "tradingPost" } },
      brief = { "Sell 500 units to Orbis.", "Reach 1.5x the Kessa HMC price." },
      hint = "Enable Orbis prices in context.",
      units = 500, minRatio = 1.5, refPlanet = "kessa",
      reward = { credits = 2000 },
    },
    {
      id = 6, name = "Two pairs of hands", check = "teamwork", start = { ships = 2 },
      brief = { "Each Miner earns 1,000 credits.", "Measure over 10 game minutes.", "Crowding must stay below 10%." },
      hint = "Assign each Miner a different vein.",
      minutes = 10, creditsEach = 1000, crowdMaxPct = 10,
      reward = { credits = 2000 },
    },
    {
      id = 7, name = "Divide the work", check = "divide", start = { logisticians = 2 },
      brief = { "Two Logisticians: two deliveries each.", "Measure over 15 game minutes.", "Avoid stock and freighter errors." },
      hint = "Split stock or destinations.",
      minutes = 15, deliveries = 2, errors = { "not_enough_stock", "no_free_freighter" },
      reward = { freighter = 1 },
    },
    {
      id = 8, name = "Someone to watch over them", check = "watch", start = { upgrades = { "commandCenter" } },
      brief = { "Resolve three alerts with a Monitor.", "Agent acts within 120 seconds.", "Monitor spends at most 10 Compute." },
      hint = "Wake only for relevant alerts.",
      resolve = 3, backSeconds = 120, computeMax = 10,
      reward = { credits = 5000, compute = 20 },
    },
  },
}
