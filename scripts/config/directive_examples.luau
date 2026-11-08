-- UI words of the agent editor's "Examples" dropdown (GR5-106). The examples themselves live in config/prompt_library.luau
-- (GR5-107); this file only labels them. No balance numbers, no measured results.
return {
  grades = { bad = "BAD", ok = "OK", good = "GOOD" },
  roleLabels = { miner = "Miner", logistician = "Logistician", refiner = "Refiner", scavenger = "Salvager", privateer = "Raider", monitor = "Monitor" },
  stubNote = "The built-in stub does not read: ",
  watchLabel = "What to expect",
  noMeasure = "Expectation, not a measured result.",
  noExamples = "No examples for this agent yet",
  secondAgent = "SECOND AGENT (same example, other directive)",
  blockers = {
    tier_locked = "a higher tier",
    tool_not_permitted = "a tool this agent cannot use",
    needs_scanner = "the scanner upgrade",
    unknown_agent_type = "a known agent type",
    branch_locked = "its branch opened",
  },
}
