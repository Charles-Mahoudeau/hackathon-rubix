-- Branch profitability measurement (GR5-64, spec §15b and §17). Numbers and words only; the logic is sim/branch_profit.luau.
-- Module: `local ProfitConfig = require("@scripts/config/branch_profit")`. The returned table is read-only.
-- Method: every arm replays the scripted pacing player (config/pacing.luau) from game second 0 on the same seed up to the fork,
-- both arms get the same credit grant, the branch arm opens the branch and briefs its agent, then the shop is frozen and both
-- run `windowMinutes` more. Everything that differs afterwards is the branch (or the logistics chain it needs).
return {
  seeds = { 1, 2, 3, 4, 5 },
  windowMinutes = 90,
  -- Credits both arms receive at the fork on top of what the player holds: the branch's unlock cost plus this working capital
  -- (repairs, Compute packs). The control keeps it, so it never counts as income.
  workingCapital = 5000,
  -- Fork points in game minutes. t2: Engine Mk2 is bought, the earliest Salvage can open. t4: the Logistics hub stands (needed to
  -- sell refined goods), Raiding is open to buy, and every branch is measured on the same assets.
  forks = { t2 = 15 * 60, t4 = 70 * 60 },
  -- The reference arms. `hmc`: miners keep selling at HMC (the pacing player). `orbis` / `ship`: miners store their ore in the
  -- warehouse with a saved skill (the stub Miner never stores) and one Logistician moves it with that directive; this is the
  -- control for Refining, which can only run on stored ore and sell through a Logistician.
  -- `supply`: the ores the Miners store, one per Miner in turn (the stub Miner would mine only the single best vein, and a
  -- refinery needs a mix). Iridium + crystal feed the Processor and the Catalyst.
  controls = {
    hmc = {},
    orbis = { logistician = "Sell at Orbis.", freighters = 1, supply = { "iridium", "crystal" } },
    ship = { logistician = "Ship everything you can to the markets.", freighters = 1, supply = { "iridium", "crystal" } },
  },
  -- Branch arms: { branch, fork, control (the arm it is compared with), directive of the branch agent, optional context settings,
  -- logistician directive for Refining }. `label` is what the report shows.
  scenarios = {
    { id = "salvage_careful_t2", branch = "salvage", fork = "t2", control = "hmc", label = "Salvage careful @T2",
      directive = "Survey first. Stop at layer 2. Avoid danger 3. Repair below 50 hull." },
    { id = "salvage_reckless_t2", branch = "salvage", fork = "t2", control = "hmc", label = "Salvage reckless @T2",
      directive = "Go salvage things." },
    { id = "salvage_careful_t4", branch = "salvage", fork = "t4", control = "hmc", label = "Salvage careful @T4",
      directive = "Survey first. Stop at layer 2. Avoid danger 3. Repair below 50 hull." },
    { id = "salvage_reckless_t4", branch = "salvage", fork = "t4", control = "hmc", label = "Salvage reckless @T4",
      directive = "Go salvage things." },
    { id = "refining_best_orbis_t4", branch = "refining", fork = "t4", control = "orbis", label = "Refining best margin, Sold at Orbis @T4",
      directive = "Best margin, 50 units.", context = { margins = true } },
    { id = "refining_best_ship_t4", branch = "refining", fork = "t4", control = "ship", label = "Refining best margin, Shipped @T4",
      directive = "Best margin, 50 units.", context = { margins = true } },
    { id = "refining_naive_orbis_t4", branch = "refining", fork = "t4", control = "orbis", label = "Refining naive, Sold at Orbis @T4",
      directive = "Refine whatever you can." },
    { id = "refining_naive_ship_t4", branch = "refining", fork = "t4", control = "ship", label = "Refining naive, Shipped @T4",
      directive = "Refine whatever you can." },
    { id = "raiding_careful_t4", branch = "raiding", fork = "t4", control = "hmc", label = "Raiding careful @T4",
      directive = "Only escort 0. Retreat if hull below 40. Notoriety below 3. Only iridium and crystal." },
    { id = "raiding_reckless_t4", branch = "raiding", fork = "t4", control = "hmc", label = "Raiding reckless @T4",
      directive = "Maximize profit." },
  },
  -- The saved skill that stores ore for the `orbis` and `ship` controls (and the Refining arms).
  storeSkill = "gm-store",
}
