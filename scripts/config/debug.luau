-- Debug panel numbers (spec §16.4). `enabled` is the only switch: false in release builds, true in debug builds and demo mode.
-- Module: `local DebugConfig = require("@scripts/config/debug")`. The returned table is read-only.
return {
  enabled = true,
  creditBoost = 1000,   -- default for "add credits"
  computeBoost = 20,    -- default for "add Compute"
  maxTier = 5,          -- spec §6.6: T1..T5
  awayHours = 1,        -- default for "simulate N hours away" (the demo button)
  maxAwayHours = 8,     -- spec §14: offline progression is capped at 8 h
  demoMaxCreditBoosts = 1, -- spec §17: the jury demo uses the credit boost at most once
}
