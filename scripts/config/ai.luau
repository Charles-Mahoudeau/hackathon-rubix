-- AI provider layer limits (spec §10.4). The returned table is read-only.
return {
  provider = "stub",         -- "stub" | "rubix" (GR5-15)
  maxConcurrent = 4,         -- in-flight requests per player; the rest queue, Monitor first, then oldest
  tokensPerHour = 400000,    -- per real hour per player; beyond it AI agents go to no_compute
  windowSeconds = 3600,
  budgetMessage = "Server AI budget reached",
}
