-- Directive examples of the agent editor's "Examples" dropdown (GR5-106; source: GR5-102 directive-library.md).
-- Words only: no balance numbers, no measured results. An example fills the editable directive and nothing else; what it
-- needs (tools, skills, settings, upgrades) is listed as prerequisites and never changed for the player.
--
-- Entry: id, role (agent type), grade ("bad"|"ok"|"good"), directive, hint (max `hintMax` characters), watch (what to look for
-- in the Logs screen; an expectation, never a measured result), stub ("ok" the built-in stub follows the clauses |
-- "partial" it may ignore some), needs (prerequisites), and either `general = true` (a role example, always listed) or
-- `missions = { n, ... }` (listed once one of those missions has started).
-- Prerequisite kinds: { kind = "tool", name } | { kind = "skill", name } | { kind = "setting", key, value, label } |
-- { kind = "upgrade", id, label } | { kind = "monitor_alert", name } | { kind = "monitor_heartbeat_off" }.
local function tool(name) return { kind = "tool", name = name } end
local function skill(name) return { kind = "skill", name = name } end

local K1_GOOD = "Mine titanium at K1 on Kessa to 100%; return to the local depot and sell to HMC."
local SHIP_GOOD = "Ship only cobalt to Halcyon when at least 300 is stocked and a freighter is free; otherwise wait 60 seconds."
local WAREHOUSE = { kind = "upgrade", id = "warehouse", label = "warehouse (stock to ship)" }
local ORBIS_PRICES = { kind = "setting", key = "prices_orbis", value = true, label = "Orbis prices on (Context)" }
local MONITOR_NEEDS = { tool("resume_agent"), tool("assign_skill"), { kind = "monitor_alert", name = "agent_paused" },
  { kind = "monitor_alert", name = "skill_aborted" }, { kind = "monitor_heartbeat_off" } }

return {
  hintMax = 60,
  grades = { bad = "BAD", ok = "OK", good = "GOOD" },
  roleLabels = { miner = "Miner", logistician = "Logistician", refiner = "Refiner", scavenger = "Salvager", privateer = "Raider", monitor = "Monitor" },
  stubNote = "The built-in stub may not follow every clause; a real AI reads it freely.",
  watchLabel = "Look for in Logs",
  noMeasure = "Expectation, not a measured result.",
  noExamples = "No examples for this agent yet",

  examples = {
    -- Miner
    { id = "miner_bad", role = "miner", grade = "bad", general = true, missions = { 1 }, directive = "Mine stuff.",
      hint = "Name a vein and a return threshold.", stub = "ok", needs = {},
      watch = "Random vein and threshold: trips change target and can miss the hold goal." },
    { id = "miner_ok", role = "miner", grade = "ok", general = true, directive = "Mine titanium on Kessa; return at 80% and sell locally to HMC.",
      hint = "Pin the vein for repeatable trips.", stub = "ok", needs = {},
      watch = "The threshold is explicit but the vein varies; the target changes between trips." },
    { id = "miner_good", role = "miner", grade = "good", general = true, missions = { 1, 4, 6 }, directive = K1_GOOD,
      hint = "Specify target, threshold and buyer.", stub = "ok", needs = {},
      watch = "Each trip shows K1, a full hold, a return and a sale at the local buyer." },
    { id = "miner_m1_ok", role = "miner", grade = "ok", missions = { 1 }, directive = "Mine titanium on Kessa to 80%; sell locally to HMC.",
      hint = "Keep all trips on the same vein.", stub = "ok", needs = {},
      watch = "The threshold meets the check, but a random vein can break the same-vein streak." },
    { id = "miner_m2_bad", role = "miner", grade = "bad", missions = { 2 }, directive = "Mine cobalt.",
      hint = "Ask for a scan first.", stub = "ok", needs = {},
      watch = "No scan call and no K4 choice appear in the Logs." },
    { id = "miner_m2_ok", role = "miner", grade = "ok", missions = { 2 }, directive = "Scan Kessa; mine cobalt to 100%; sell locally to HMC.",
      hint = "Name the scanned vein.", stub = "partial", needs = { tool("scan") },
      watch = "A scan appears, but an unnamed vein need not be K4." },
    { id = "miner_m2_good", role = "miner", grade = "good", missions = { 2 }, directive = "Scan Kessa; mine cobalt at K4 to 100%; return to the local depot and sell to HMC.",
      hint = "Scan, then name the target.", stub = "partial", needs = { tool("scan") },
      watch = "The scan comes first, then a K4 trip and its sale." },
    { id = "miner_m3_bad", role = "miner", grade = "bad", missions = { 3, 4 }, directive = "Report constantly.",
      hint = "Spend decisions on productive actions.", stub = "partial", needs = { tool("report") },
      watch = "Every decision costs Compute and earns nothing: repeated report calls in the Logs." },
    { id = "miner_m3_good", role = "miner", grade = "good", missions = { 3, 4 }, directive = "Use skill K1Loop.",
      hint = "Reuse a saved routine.", stub = "ok", needs = { tool("run_skill"), skill("K1Loop") },
      watch = "Skill steps cost no Compute: sales continue while the decision count stays flat." },
    { id = "miner_m5_bad", role = "miner", grade = "bad", missions = { 5 }, directive = "Sell locally to HMC.",
      hint = "Choose the required buyer.", stub = "ok", needs = {},
      watch = "HMC sales do not count toward the Orbis goal." },
    { id = "miner_m5_ok", role = "miner", grade = "ok", missions = { 5 }, directive = "Mine titanium at K1 on Kessa to 100%; return home and sell to Orbis.",
      hint = "Include a minimum price.", stub = "partial", needs = { ORBIS_PRICES },
      watch = "Orbis sales appear, but the unit price may fall below the required ratio." },
    { id = "miner_m5_good", role = "miner", grade = "good", missions = { 5 },
      directive = "Mine titanium at K1 on Kessa to 100%; return home and sell to Orbis; never sell below 4.5.",
      hint = "Set the buyer and a price floor.", stub = "partial",
      needs = { ORBIS_PRICES, { kind = "upgrade", id = "tradingPost", label = "trading post" }, WAREHOUSE },
      watch = "Orbis sales at or above the floor, or a wait when the price is lower." },
    { id = "miner_m6_bad", role = "miner", grade = "bad", missions = { 6 }, directive = "Both mine titanium at K1 to 100%; sell locally to HMC.",
      hint = "Separate the vein assignments.", stub = "ok", needs = {},
      watch = "Two ships on one vein: crowded_by appears in the Logs." },
    { id = "miner_m6_ok", role = "miner", grade = "ok", missions = { 6 }, directive = "Mine titanium on Kessa to 100%; sell locally to HMC.",
      hint = "Pin each agent to a different vein.", stub = "ok", needs = {},
      watch = "A random vein choice can still put both Miners on the same vein." },
    { id = "miner_m6_good2", role = "miner", grade = "good", missions = { 6 }, directive = "Mine cobalt at K3 on Kessa to 100%; return to the local depot and sell to HMC.",
      hint = "Give each Miner a distinct vein.", stub = "ok", needs = {},
      watch = "Use for the second Miner next to the K1 example: the Logs show distinct veins." },

    -- Logistician
    { id = "logistician_bad", role = "logistician", grade = "bad", general = true, missions = { 7 }, directive = "Ship everything anywhere.",
      hint = "Match each resource to a buyer.", stub = "partial", needs = { tool("ship"), WAREHOUSE },
      watch = "Unspecified stock and buyers lead to not_bought_here or freighter collisions." },
    { id = "logistician_ok", role = "logistician", grade = "ok", general = true, missions = { 7 }, directive = "Ship only cobalt to Halcyon.",
      hint = "Reserve capacity when agents share it.", stub = "partial", needs = { tool("ship"), WAREHOUSE },
      watch = "Ship and arrival lines in the Logs; a second Logistician can still contend for a freighter." },
    { id = "logistician_good", role = "logistician", grade = "good", general = true, missions = { 7 }, directive = SHIP_GOOD,
      hint = "State stock and availability checks.", stub = "partial", needs = { tool("ship"), WAREHOUSE },
      watch = "Dispatches and waits in the Logs; stock and freighter coordination is yours to split." },
    { id = "logistician_m7_bad", role = "logistician", grade = "bad", missions = { 7 }, directive = "Ship everything to every buyer.",
      hint = "Split responsibility and capacity.", stub = "partial", needs = { tool("ship"), WAREHOUSE },
      watch = "Shared stock or freighter conflicts appear in the Logs." },
    { id = "logistician_m7_good2", role = "logistician", grade = "good", missions = { 7 },
      directive = "Ship only iridium to Meridian when at least 300 is stocked and a freighter is free; otherwise wait 60 seconds.",
      hint = "Give the second agent a separate lane.", stub = "partial", needs = { tool("ship"), WAREHOUSE },
      watch = "Use for the second Logistician next to the cobalt example: no shared stock or freighter errors." },

    -- Refiner
    { id = "refiner_bad", role = "refiner", grade = "bad", general = true, directive = "Make anything.",
      hint = "Name a recipe and quantity.", stub = "partial", needs = { tool("refine") },
      watch = "A random recipe or not_enough_input; refining adds stock, not credits." },
    { id = "refiner_ok", role = "refiner", grade = "ok", general = true, directive = "Refine 10 plate.",
      hint = "Check inputs before each batch.", stub = "partial", needs = { tool("refine") },
      watch = "A refine job when titanium is in stock, otherwise not_enough_input." },
    { id = "refiner_good", role = "refiner", grade = "good", general = true, directive = "Refine 10 plate only when at least 30 titanium is in stock; otherwise wait 60 seconds.",
      hint = "Guard the batch by available stock.", stub = "partial", needs = { tool("refine") },
      watch = "Refine or wait lines in the Logs; income needs another agent to sell the plate." },

    -- Salvager (spec: Scavenger)
    { id = "scavenger_bad", role = "scavenger", grade = "bad", general = true, directive = "Grab everything.",
      hint = "Survey before choosing a layer.", stub = "partial", needs = { tool("survey"), tool("salvage") },
      watch = "No survey; layer_locked, hull damage or a disabled ship may show in the Logs." },
    { id = "scavenger_ok", role = "scavenger", grade = "ok", general = true, directive = "Survey first; stop at layer 2.",
      hint = "Add a hull and danger limit.", stub = "partial", needs = { tool("survey"), tool("salvage") },
      watch = "Survey and layer lines appear; unbounded hull damage remains possible." },
    { id = "scavenger_good", role = "scavenger", grade = "good", general = true,
      directive = "Survey first; avoid danger above 1; stop at layer 2; return below 50 hull; repair below 80.",
      hint = "Bound danger, depth and hull.", stub = "partial", needs = { tool("survey"), tool("salvage"), tool("repair") },
      watch = "Survey, layer outcomes, then a return and repair when the hull is low." },

    -- Raider (spec: Privateer)
    { id = "privateer_bad", role = "privateer", grade = "bad", general = true, directive = "Maximize profit.",
      hint = "Limit targets and attack frequency.", stub = "partial", needs = { tool("intercept"), tool("attack") },
      watch = "Attacks on every convoy and rising notoriety; retaliation follows." },
    { id = "privateer_ok", role = "privateer", grade = "ok", general = true, directive = "Only escort 0; only iridium.",
      hint = "Add a rate and hull limit.", stub = "partial", needs = { tool("intercept"), tool("attack") },
      watch = "Targets are filtered, but repeated attacks can still raise notoriety." },
    { id = "privateer_good", role = "privateer", grade = "good", general = true,
      directive = "Only escort 0; only iridium; wait 20 minutes between attacks; retreat if hull below 50.",
      hint = "Constrain targets, pace and hull.", stub = "partial", needs = { tool("intercept"), tool("attack"), tool("retreat") },
      watch = "Target decisions, waits and retreats; profit and notoriety are not guaranteed." },

    -- Monitor
    { id = "monitor_bad", role = "monitor", grade = "bad", general = true, missions = { 8 }, directive = "Manage everyone.",
      hint = "Map each alert to an action.", stub = "partial", needs = { { kind = "monitor_alert", name = "agent_paused" } },
      watch = "Random valid actions; the alerted agent stays stuck." },
    { id = "monitor_ok", role = "monitor", grade = "ok", general = true, missions = { 8 }, directive = "Resume paused agents.",
      hint = "Cover the failures you enable.", stub = "ok", needs = { tool("resume_agent"), { kind = "monitor_alert", name = "agent_paused" } },
      watch = "resume_agent for agent_paused; other alerts stay unresolved." },
    { id = "monitor_good", role = "monitor", grade = "good", general = true, missions = { 8 },
      directive = "Resume paused agents; reassign skill and rotate to the next vein when a skill aborts.",
      hint = "Pair alerts with recovery actions.", stub = "partial", needs = MONITOR_NEEDS,
      watch = "resume_agent or assign_skill after each alert; needs a compatible skill and a free vein." },
  },
}
