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
}
