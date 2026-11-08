-- Debug panel numbers (spec §16.4). `enabled` is the only switch: false in release builds, true in debug builds and demo mode.
-- Module: `local DebugConfig = require("@scripts/config/debug")`. The returned table is read-only.
return {
  enabled = true,
  qaTour = false,       -- GR5-89: walk every screen on a prepared T5 company (client/qa_tour.luau); for screenshots only
  mapTour = false,      -- GR5-105: a scripted T1-T5 planet-reveal run (client/map_tour.luau); for screenshots only
  creditBoost = 1000,   -- default for "add credits"
  computeBoost = 20,    -- default for "add Compute"
  maxTier = 5,          -- spec §6.6: T1..T5
  awayHours = 1,        -- default for "simulate N hours away" (the demo button)
  awayChoices = { 1, 4, 8 }, -- hours offered by the panel's away buttons (each <= maxAwayHours)
  shortage = { market = "orbis", ore = "cobalt" }, -- what the panel's "Shortage" button starts (the demo's Orbis cobalt)
  maxAwayHours = 8,     -- spec §14: offline progression is capped at 8 h
  demoMaxCreditBoosts = 1, -- spec §17: the jury demo uses the credit boost at most once
}
