-- Numbers and words of the branches (spec §15b.0, B-0). A branch's structure (agent type, tools, alerts, parameter kinds) is
-- declared in sim/branches/<id>.luau; what it costs, when it opens and how it reads on screen is here, keyed by branch id.
return {
  -- Scopes that are not a branch. The Monitor can watch the whole company, one branch, or the logistics chain.
  scopes = {
    company = { label = "Company", first = true },
    logistics = { label = "Logistics" },
  },
  -- Branch state words of the Branches panel.
  states = { open = "open", available = "available", locked = "locked" },
  reasons = {
    tier_locked = "needs a higher tier",
    reputation = "needs Reputation %d",
    needs = "needs %s",
    not_enough_credits = "not enough credits",
  },

  -- Mining: the first branch, open from the start (spec §15b.0). toolTiers = the tier at which each mining-only tool unlocks.
  mining = {
    name = "Mining",
    scope = "mining",
    startsOpen = true,
    agentType = "miner",
    assetType = "ship",
    assetLabel = "mining ship",
    startTier = 1,
    toolSlots = 5,
    toolTiers = { mine = 1, ["return"] = 1, scan = 2, store = 3 },
    agentTools = { "mine", "return", "sell", "store", "report", "wait", "scan", "run_skill" },
    alertKinds = { crowding = { after = "losing_money" } },
    paramKinds = { "vein", "resource", "pct" },
    startShip = "s1",
  },
  -- Raiding (spec §15b.4, B-c): the third branch, opened by buying the first interceptor at T4. `ladder` = the price of
  -- interceptor #1, #2, #3 (#2 and #3 are shop items, config/balance.luau). Rival convoys travel the freighter routes from
  -- the home planet; only the orange ones (`orangeRoutes`, by destination market) can be raided.
  raiding = {
    name = "Raiding",
    scope = "raiding",
    agentType = "privateer",
    assetType = "interceptor",
    assetLabel = "interceptor",
    startTier = 4,
    toolSlots = 7,
    unlock = { tier = 4, cost = 20000 },
    ladder = { 20000, 15000, 25000 },
    toolTiers = { scan_route = 4, intercept = 4, attack = 4, retreat = 4, repair = 4 },
    agentTools = { "scan_route", "intercept", "attack", "retreat", "return", "repair", "sell", "store", "report", "wait", "run_skill" },
    alertKinds = { retaliation = {}, notoriety_high = {} },
    paramKinds = { "route", "convoy_filter" },
    startInterceptor = "i1",
    orangeRoutes = { "halcyon", "meridian" },
    blueRoutes = { "orbis" },
    interceptor = {
      hold = 200, hull = 80, attack = 10,
      repairCreditsPerHull = 10, repairSecondsPer10 = 5,
      scanSeconds = 10, attackSeconds = 15,
      chaseSpeed = 2,        -- interceptor speed relative to a convoy: the catch-up takes (convoy elapsed s) / (speed - 1)
      minChaseSeconds = 10,
      returnSeconds = 30,    -- from open space (after an attack or a retreat) back to the dock
      disabledSeconds = 300, towedHull = 1,
    },
    convoy = {
      corporations = { "korvax", "helion", "dunmere" },
      names = { korvax = "Korvax Freight", helion = "Helion Haulers", dunmere = "Dunmere Cartel" },
      orangeShare = 0.70,
      qtyMin = 150, qtyMax = 300,
      escortWeights = { 0.50, 0.35, 0.15 }, -- level 0, 1, 2
      escortPower = { [0] = 0, 8, 16, 24 },  -- level 3 only for a corporation that is hostile to the player
      escortBands = { [0] = "none", "light", "heavy", "heavy" },
      qtyBands = { { upTo = 199, name = "small" }, { upTo = 249, name = "medium" }, { upTo = math.huge, name = "large" } },
      scanKeepSeconds = 120, -- how long a scan result stays in the Privateer's context
    },
    combat = {
      winBase = 0.5, scale = 40, minChance = 0.10, maxChance = 0.95,
      lootMin = 0.30, lootMax = 0.60,
      winDamageMin = 0, winDamageMax = 20, lossDamageMin = 40, lossDamageMax = 80,
    },
    notoriety = {
      max = 5, decayMinutes = 20, blacklistAt = 3, blacklistPenalty = 0.20,
      retaliationAt = 3, retaliationChancePerLevel = 0.10, retaliationLoss = 0.30,
    },
    standing = { perAttack = -1, hostileAt = -3, escortBonus = 1 },
    -- Mission V3 "Rules of engagement" (spec §15b.5). Optional, outside the linear tutorial.
    mission = { id = "V3", name = "Rules of engagement", wins = 3, reward = 5000,
      goal = "Win 3 attacks while Notoriety never reaches 3.",
      hint = "Tell your Privateer what it must not attack, not only what it should." },
    -- Stub Privateer (spec §15b.6).
    stub = { waitSeconds = 30, repairBelow = 40, scanReuseSeconds = 90 },
    streams = { convoy = 53, combat = 59 }, -- rng stream i = seed x this + 7
  },
}
