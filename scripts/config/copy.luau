-- Words of the alerts, errors, notifications and unlocks (GR5-92, microcopy handoff GR5-91). Every static string is at most
-- `maxChars` characters (tests/test_copy.luau). A string is only shown when the sim event or condition it names happens;
-- numbers and names are rendered next to it, never inside it.
return {
  maxChars = 40,

  -- State words shared by the Branches and Monitor screens.
  states = { open = "Active", available = "Available", locked = "Locked" },

  branches = {
    title = "Branches",
    agents = "Agents",
    creditsPerHour = "Credits per hour",
    computePerHour = "Compute per hour",
    noAgents = "No branch agents yet.",
    noData = "No branch data yet.",
    hint = "Buy the first asset to open a branch.",
  },

  monitor = {
    title = "Monitor",
    scope = "Scope",
    heartbeat = "Heartbeat",
    alerts = "Alerts",
    history = "Response history",
    noMonitor = "No Monitor in this scope.",
    noAlerts = "No alerts yet.",
    noActions = "No Monitor actions yet.",
    needsCommandCenter = "Buy the command center first.",
    noCommandSlot = "No free command slot.",
  },

  -- Label of each alert kind (sim/alerts.luau, branches' `alertKinds`). Kinds without an entry show their id.
  alerts = {
    agent_paused = "Agent paused",
    skill_aborted = "Skill aborted",
    no_compute = "Compute depleted",
    agent_idle = "Agent idle",
    losing_money = "Agent losing money",
    crowding = "Vein crowded",
    station_full = "Station nearly full",
    freighter_idle = "Freighter idle",
    site_spawned = "Salvage site found",
    site_expiring = "Salvage site expiring",
    ship_damaged = "Ship damaged",
    retaliation = "Retaliation",
    notoriety_high = "Notoriety high",
  },

  -- Reasons an agent stops or cannot think (sim.luau). They are stored in agent.blockReason, so the Team, Compute and
  -- Monitor views show exactly what the sim decided.
  pause = {
    provider = "Agent paused after provider errors.",
    invalid = "Agent paused after invalid replies.",
    same = "Agent stuck: same action failed twice.",
    monitor = "Agent paused by the Monitor.",
  },
  notEnoughCompute = "Not enough Compute.",

  -- A decision that did not produce a usable call (sim.luau, provider answer).
  provider = {
    failed = "Provider error; decision charged.",
    timeout = "Decision timed out; estimate charged.",
    invalid = "Invalid tool call.",
  },

  -- A call the sim refused, by its error code. Exact codes first, then code prefixes; anything else is an ordinary failed
  -- action and the raw code stays next to it.
  errors = {
    failed = "Action failed; see result.",
    invalidCall = "Invalid tool call.",
    notEquipped = "Tool not equipped.",
    invalidArgs = "Invalid tool arguments.",
    byCode = {
      ["malformed call"] = "Invalid tool call.",
      ["unknown agent"] = "Invalid tool call.",
      ["args must be table"] = "Invalid tool arguments.",
      ["bad qty"] = "Invalid tool arguments.",
      ["bad stop_at_hold_pct"] = "Invalid tool arguments.",
      ["bad dock"] = "Invalid tool arguments.",
      ["bad seconds"] = "Invalid tool arguments.",
      ["bad resource"] = "Invalid tool arguments.",
      ["bad planet"] = "Invalid tool arguments.",
      ["bad depot"] = "Invalid tool arguments.",
      ["bad destination"] = "Invalid tool arguments.",
      bad_args = "Invalid tool arguments.",
      warehouse_full = "Warehouse full.",
      not_enough_stock = "Not enough stock.",
      no_free_freighter = "No free freighter.",
      out_of_scope = "Agent outside Monitor scope.",
      agent_locked = "Agent locked against Monitor changes.",
      too_long = "Order exceeds token limit.",
    },
    byPrefix = {
      { prefix = "unknown or disallowed tool:", text = "Invalid tool call." },
      { prefix = "tool not equipped:", text = "Tool not equipped." },
    },
  },

  editor = {
    directiveOver = "Directive exceeds token limit.",
    orderOver = "Order exceeds token limit.",
  },

  skill = { aborted = "Skill aborted; see reason." },

  -- Emergency advance (spec §8.5): shown only while the sim offers it.
  notice = { emergency = "Emergency Compute available.", claim = "Claim" },

  -- Tier and asset unlocks, pushed to the feed when the sim event fires (sim/feed.luau). Acquisition messages follow the
  -- purchase, not the tier alone.
  unlocks = {
    tier = { [1] = "T1: Mining online.", [2] = "T2 reached.", [3] = "T3 reached.", [4] = "T4 reached.", [5] = "T5 reached." },
    branch = { salvage = "Salvage branch unlocked.", refining = "Refining branch unlocked.", raiding = "Raiding branch unlocked." },
    logistician = "Logistician available at this station.",
    monitor = "Monitor available at command center.",
  },
}
