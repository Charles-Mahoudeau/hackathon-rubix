-- Pacing targets and the scripted player of the headless balance report (spec §6.7, M8). Numbers only; logic is sim/pacing.luau.
-- Module: `local PacingConfig = require("@scripts/config/pacing")`. The returned table is read-only.
return {
  -- Game seconds at which each tier should start (spec §6.7); off by more than `tolerance` => tune balance.luau, not logic.
  targets = { [3] = 25 * 60, [4] = 60 * 60, [5] = 120 * 60 },
  tolerance = 0.30,
  -- Report run: game seconds simulated, sampling step of the credits timeline, the seeds (the summary shows their median).
  report = { seconds = 3 * 3600, sampleSeconds = 300, seeds = { 1, 2, 3 }, speed = 1 },
  -- The scripted player: a precise directive for every Miner, and shop items bought as soon as they are affordable,
  -- first match wins each pass. Items missing from the build's shop are skipped.
  player = {
    -- {vein} is replaced by the vein with the best credits per trip-second that still holds a full hold and that no other Miner is on.
    directive = "Mine {vein} until the hold is 100%, then sell at HMC.",
    reserve = 400, -- credits kept back after a purchase (two Compute packs), so the player never buys itself broke
    computeBelow = 3, computePacks = 1, -- buys a pack of Compute whenever the stock falls below this
    buy = { "drill_mk2", "hold_mk2", "engine_mk2", "warehouse", "ship2", "drill_mk3", "hold_mk3", "engine_mk3", "trading_post" },
  },
}
