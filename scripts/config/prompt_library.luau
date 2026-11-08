-- Prompt library (GR5-107, from the GR5-102 directive-library draft): BAD / OK / GOOD directive examples with a coaching hint for
-- every role and for missions 1-8, plus five optional practice challenges. Text and numbers only; the accessors are in
-- sim/prompt_library.luau and the challenge fixtures in sim/prompt_challenges.luau.
--
-- `outcome` is what the keyword-interpreter stub does with the directive (checked by tests/test_prompt_library.luau); it never
-- states a Compute or income figure, because those depend on the seed, the market and the context settings and are measured by
-- tools/prompt_library_report.luau instead. `support` = "stub": the stub reads every clause. "partial": the clauses in `unread`
-- are design intent for a real provider, not behaviour the stub guarantees. `tools` = the tools the directive relies on; they
-- must be equipped and unlocked (tier, and the branch for a branch role) for the example to be shown.
local MINER_GOOD = "Mine titanium at K1 on Kessa to 100%; return to the local depot and sell to HMC."
local SKILL = "Use skill K1Loop."
local MINING = { "mine", "return", "sell" }

return {
  hintMaxChars = 60, -- shown under the editor; the directive limit itself is config/ai.luau editor.directiveMaxTokens
  grades = { "bad", "ok", "good" },

  -- Roles, in the order of the editor's agent list. `branch` = the branch that must be open; nil = always available (by tier).
  roles = {
    {
      id = "miner", label = "Miner", agentType = "miner",
      examples = {
        { grade = "bad", text = "Mine stuff.", tools = MINING, support = "stub",
          outcome = "Ore, vein and hold threshold are picked at random each trip; the reasoning in the Logs says so.",
          hint = "Name a vein and a return threshold." },
        { grade = "ok", text = "Mine titanium on Kessa; return at 80% and sell locally to HMC.", tools = MINING, support = "stub",
          outcome = "Ore, planet, 80% and the depot are read; the titanium vein on Kessa is still picked at random.",
          hint = "Pin the vein for repeatable trips." },
        { grade = "good", text = MINER_GOOD, tools = MINING, support = "stub",
          outcome = "Every trip: mine K1 to 100%, return to the local depot, sell to HMC.",
          hint = "Specify target, threshold and buyer." },
      },
    },
    {
      id = "logistician", label = "Logistician", agentType = "logistician",
      examples = {
        { grade = "bad", text = "Ship everything anywhere.", tools = { "ship" }, support = "stub",
          outcome = "Fullest stock and a random market that buys it; two such Logisticians on one station collide.",
          hint = "Match each resource to a buyer." },
        { grade = "ok", text = "Ship only cobalt to Halcyon.", tools = { "ship" }, support = "stub",
          outcome = "Ships cobalt to Halcyon when a freighter is docked; a second Logistician can still contend for it.",
          hint = "Reserve capacity when agents share it." },
        { grade = "good", text = "Ship only cobalt to Halcyon when at least 300 is stocked and a freighter is free; otherwise wait 60 seconds.",
          tools = { "ship", "wait" }, support = "partial", unread = { "when at least 300 is stocked" },
          outcome = "The stub ships cobalt to Halcyon whenever a freighter is docked and waits otherwise; it does not check the 300.",
          hint = "State stock and availability checks." },
      },
    },
    {
      id = "refiner", label = "Refiner", agentType = "refiner", branch = "refining",
      examples = {
        { grade = "bad", text = "Make anything.", tools = { "refine" }, support = "stub",
          outcome = "A random recipe it has the inputs for, in a random quantity. Refining adds stock, not credits.",
          hint = "Name a recipe and quantity." },
        { grade = "ok", text = "Refine 10 plate.", tools = { "refine" }, support = "stub",
          outcome = "Refines plate, 10 at a time or fewer when the stock allows; waits when none can be made.",
          hint = "Check inputs before each batch." },
        { grade = "good", text = "Refine 10 plate only when at least 30 titanium is in stock; otherwise wait 60 seconds.",
          tools = { "refine", "wait" }, support = "partial", unread = { "only when at least 30 titanium is in stock" },
          outcome = "The stub refines plate whenever it has any input and waits when it has none; it does not check the 30.",
          hint = "Guard the batch by available stock." },
      },
    },
    {
      id = "scavenger", label = "Salvager", agentType = "scavenger", branch = "salvage",
      examples = {
        { grade = "bad", text = "Grab everything.", tools = { "salvage" }, support = "stub",
          outcome = "No survey, no depth or danger limit: layers are stripped at a random depth and the ship can be disabled.",
          hint = "Survey before choosing a layer." },
        { grade = "ok", text = "Survey first; stop at layer 2.", tools = { "survey", "salvage" }, support = "stub",
          outcome = "Surveys each site, never goes below layer 2; danger is not limited.",
          hint = "Add a danger and hull limit." },
        { grade = "good", text = "Survey first; avoid danger 2; stop at layer 2; repair below 60 hull.",
          tools = { "survey", "salvage", "repair", "return" }, support = "stub",
          outcome = "Skips sites of danger 2 or more, stops at layer 2, goes home to repair under 60 hull. One hull threshold.",
          hint = "Bound danger, depth and hull." },
      },
    },
    {
      id = "privateer", label = "Raider", agentType = "privateer", branch = "raiding",
      examples = {
        { grade = "bad", text = "Maximize profit.", tools = { "attack" }, support = "stub",
          outcome = "Says nothing the stub can use: it attacks every convoy it intercepts and Notoriety climbs.",
          hint = "Limit targets and attack frequency." },
        { grade = "ok", text = "Only escort 0; only iridium.", tools = { "intercept", "attack" }, support = "stub",
          outcome = "Only unescorted iridium convoys are taken; there is no pace or hull limit.",
          hint = "Add a pace and a hull limit." },
        { grade = "good", text = "Only escort 0; only iridium; wait 20 minutes between attacks; retreat if hull below 50.",
          tools = { "intercept", "attack", "retreat" }, support = "stub",
          outcome = "Same targets, at least 20 minutes between attacks, retreats under 50 hull. Profit is not guaranteed.",
          hint = "Constrain targets, pace and hull." },
      },
    },
    {
      id = "monitor", label = "Monitor", agentType = "monitor",
      examples = {
        { grade = "bad", text = "Manage everyone.", tools = { "resume_agent" }, support = "stub",
          outcome = "Covers no alert: the stub picks a random valid action, which often fixes nothing.",
          hint = "Map each alert to an action." },
        { grade = "ok", text = "Resume paused agents.", tools = { "resume_agent" }, support = "stub",
          outcome = "Resumes an agent on a paused alert; any other alert gets a random action.",
          hint = "Cover the failures you enable." },
        { grade = "good", text = "Resume paused agents; reassign skill and rotate to the next vein when a skill aborts.",
          tools = { "resume_agent", "assign_skill" }, support = "stub",
          outcome = "Paused: resume. Aborted skill: assign it to a free vein. Needs a skill with a vein parameter.",
          hint = "Pair alerts with recovery actions." },
      },
    },
  },

  -- Missions 1-8, same canonical order as config/missions.luau (ids must match). `role` = the agent that does the mission;
  -- `text2` = the directive of the second agent when the mission needs two.
  missions = {
    { id = 1, role = "miner", needs = "Tier 1", examples = {
      { grade = "bad", text = "Mine stuff.", tools = MINING, support = "stub",
        outcome = "A random vein and threshold each trip; the three-in-a-row streak rarely survives.",
        hint = "Specify one vein and threshold." },
      { grade = "ok", text = "Mine titanium on Kessa to 80%; sell locally to HMC.", tools = MINING, support = "stub",
        outcome = "The threshold qualifies, but the titanium vein is random, so a switch of vein resets the streak.",
        hint = "Keep all trips on the same vein." },
      { grade = "good", text = MINER_GOOD, tools = MINING, support = "stub",
        outcome = "Three K1 sales at a full hold, one after another.",
        hint = "Specify target, threshold and buyer." } } },
    { id = 2, role = "miner", needs = "Tier 2, scanner", examples = {
      { grade = "bad", text = "Mine cobalt.", tools = MINING, support = "stub",
        outcome = "Never scans and picks a random cobalt vein and threshold.",
        hint = "Ask for a scan first." },
      { grade = "ok", text = "Scan Kessa; mine cobalt to 100%; sell locally to HMC.", tools = { "scan", "mine", "sell" }, support = "stub",
        outcome = "Scans Kessa once, then mines a random cobalt vein there, which need not be K4.",
        hint = "Name the scanned vein." },
      { grade = "good", text = "Scan Kessa; mine cobalt at K4 to 100%; return to the local depot and sell to HMC.", tools = { "scan", "mine", "sell" },
        support = "stub", outcome = "Scan Kessa first, then every trip mines K4 and sells at HMC.",
        hint = "Scan, then name the target." } } },
    { id = 3, role = "miner", needs = "Tier 1, saved skill K1Loop for the GOOD example", examples = {
      { grade = "bad", text = "Mine titanium at K1 to 10%; sell locally to HMC.", tools = MINING, support = "stub",
        outcome = "Tiny trips: one decision per few credits, so the Compute pool runs dry before 1,000 cr and the mission stalls.",
        hint = "Fill the hold before you return." },
      { grade = "ok", text = "Mine titanium at K1 to 50%; sell locally to HMC.", tools = MINING, support = "stub",
        outcome = "Pays for one decision per trip; it can stay inside the budget but spends more than a routine would.",
        hint = "Compare Compute against revenue." },
      { grade = "good", text = SKILL, tools = { "run_skill" }, support = "stub",
        outcome = "One decision starts the saved routine; its steps cost no Compute.",
        hint = "Reuse a saved routine." } } },
    { id = 4, role = "miner", needs = "Tier 1, saved skill K1Loop for the GOOD example", examples = {
      { grade = "bad", text = "Mine stuff.", tools = MINING, support = "stub",
        outcome = "Sales made by the AI never count as skill credit, whatever they earn.",
        hint = "Record a successful trip." },
      { grade = "ok", text = "Mine titanium at K1 to 100%; sell locally to HMC.", tools = MINING, support = "stub",
        outcome = "Earns credits, but only from AI decisions, so mission 4 does not move.",
        hint = "Save the successful sequence." },
      { grade = "good", text = SKILL, tools = { "run_skill" }, support = "stub",
        outcome = "The skill's sales are skill credit and cost no Compute per step.",
        hint = "Run the saved trip as a skill." } } },
    { id = 5, role = "miner", needs = "Tier 3, warehouse and trading post", examples = {
      { grade = "bad", text = "Mine titanium at K1 to 100%; sell locally to HMC.", tools = MINING, support = "stub",
        outcome = "HMC sales never count toward the Orbis goal.",
        hint = "Pick the buyer the mission needs." },
      { grade = "ok", text = "Mine titanium at K1 on Kessa to 100%; return home and sell to Orbis.", tools = MINING, support = "stub",
        outcome = "Sells at Orbis whatever its price is that moment, even under 1.5x the HMC price.",
        hint = "Include a minimum price." },
      { grade = "good", text = "Mine titanium at K1 on Kessa to 100%; return home and sell to Orbis; never sell below 4.5.", tools = MINING,
        support = "stub", outcome = "Sells at Orbis only at 4.5 cr/unit or more (1.5x the Kessa HMC titanium price); otherwise it waits.",
        hint = "Set the buyer and a price floor." } } },
    { id = 6, role = "miner", needs = "Tier 3, ship #2 with its Miner", examples = {
      { grade = "bad", text = "Mine titanium at K1 on Kessa to 100%; return to the local depot and sell to HMC.", tools = MINING, support = "stub",
        outcome = "Give this to both Miners: they share K1 and slow each other down.",
        hint = "Separate the vein assignments." },
      { grade = "ok", text = "Mine titanium on Kessa to 100%; sell locally to HMC.", tools = MINING, support = "stub",
        outcome = "Each Miner picks a titanium vein at random, so they can still land on the same one.",
        hint = "Pin each agent to a different vein." },
      { grade = "good", text = MINER_GOOD, text2 = "Mine cobalt at K3 on Kessa to 100%; return to the local depot and sell to HMC.",
        tools = MINING, support = "stub", outcome = "Miner 1 on K1, Miner 2 on K3: no shared vein, so no crowding.",
        hint = "Give each Miner a distinct vein." } } },
    { id = 7, role = "logistician", needs = "Tier 4, hub, two Logisticians, two freighters", examples = {
      { grade = "bad", text = "Ship stuff.", tools = { "ship" }, support = "stub",
        outcome = "Give this to both: they pick the same stock and the same freighter and collide.",
        hint = "Split responsibility and capacity." },
      { grade = "ok", text = "Ship only cobalt to Halcyon.", tools = { "ship" }, support = "stub",
        outcome = "Give this to both: they fight over the same cobalt and freighters.",
        hint = "Give the second agent a separate lane." },
      { grade = "good", text = "Ship only cobalt to Halcyon when at least 300 is stocked and a freighter is free; otherwise wait 60 seconds.",
        text2 = "Ship only titanium to Halcyon when at least 300 is stocked and a freighter is free; otherwise wait 60 seconds.",
        tools = { "ship", "wait" }, support = "partial", unread = { "when at least 300 is stocked" },
        outcome = "One lane per resource, no shared stock. The stub ignores the 300 and relies on two free freighters.",
        hint = "Split stock and freighter capacity." } } },
    { id = 8, role = "monitor", needs = "Tier 5, command center, Monitor; alerts on, heartbeat off", examples = {
      { grade = "bad", text = "Manage everyone.", tools = { "resume_agent" }, support = "stub",
        outcome = "Covers no alert: random valid actions, usually no recovery.",
        hint = "Specify recovery actions." },
      { grade = "ok", text = "Resume paused agents.", tools = { "resume_agent" }, support = "stub",
        outcome = "Brings paused agents back; an aborted skill gets a random action.",
        hint = "Handle aborted skills too." },
      { grade = "good", text = "Resume paused agents; reassign skill and rotate to the next vein when a skill aborts.",
        tools = { "resume_agent", "assign_skill" }, support = "stub",
        outcome = "Paused: resume. Aborted skill: moved to a free vein. Direct income is zero.",
        hint = "Match alerts to recovery actions." } } },
  },

  -- Five optional challenges. Each runs on its own throwaway fixture (seed, window) and never changes the eight missions.
  -- `target` is checked against the metric by sim/prompt_challenges.luau; `specReference` quotes the GDD figures, which are
  -- NOT measured results (the measured ones are in docs/PROMPT_LIBRARY.md).
  challenges = {
    { id = 1, name = "Repeatable orders", fix = "Make a vague mining order repeatable.",
      fixture = "mining_repeatable", seed = 1, windowSeconds = 900, vein = "K1", holdPct = 80,
      metricName = "K1 sales in a row, hold 80% or more", target = 3,
      specReference = "GDD: a full-hold K1 skill trip is 300 cr in 80 s (225 cr/min)." },
    { id = 2, name = "Scan, then aim", fix = "Add a scan and a specific target.",
      fixture = "scan_then_target", seed = 1, windowSeconds = 900, vein = "K4",
      metricName = "scan on Kessa, then a K4 sale (1 = both, in order)", target = 1,
      specReference = "GDD: a full-hold K4 skill trip is 700 cr in 118 s (about 356 cr/min)." },
    { id = 3, name = "Think less", fix = "Reduce repeated thinking.",
      fixture = "think_less", seed = 1, windowSeconds = 600, computeMax = 3,
      metricName = "revenue in the window, within the Compute budget", target = 1000,
      specReference = "GDD: four full K1 sales are 1,200 cr in about 320 s with no Compute for skill steps." },
    { id = 4, name = "Name your buyer", fix = "Make a buyer constraint explicit.",
      fixture = "orbis_floor", seed = 1, windowSeconds = 1200, minUnitPrice = 4.5,
      metricName = "units sold to Orbis at or above the price floor", target = 500,
      specReference = "GDD: Kessa HMC titanium is 3 cr/unit, so 1.5x is 4.5; 500 units at the floor are 2,250 cr." },
    { id = 5, name = "Recover without polling", fix = "Recover a team without polling.",
      fixture = "monitor_recoveries", seed = 1, recoveries = 3, backSeconds = 120, computeMax = 10,
      metricName = "paused Miners back within 120 s, within the Compute budget", target = 3,
      specReference = "GDD: 10 Compute is at most 400 cr at 40 cr/Compute." },
  },
}
