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
  },
}
