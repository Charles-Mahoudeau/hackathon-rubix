-- Market dynamics numbers (spec §6.3). Baselines per market and resource are in world.luau (§4.4); the rules are in sim/market.luau.
-- Module: `local MarketConfig = require("@scripts/config/market")`. The returned table is read-only.
return {
  satFloor = 0.4,              -- s never drops below this
  satRecoverPerMinute = 0.05,  -- each game second: s += (1 - s) x this / 60
  demandFollowPerMinute = 0.10, -- each game second: d += (t - d) x this / 60
  events = {                   -- short events, one per market, on one resource it buys
    everySeconds = 180, jitterSeconds = 60,
    driftChance = 0.70, shortageChance = 0.20,   -- the rest is a glut
    driftSigma = 0.08, driftMin = 0.8, driftMax = 1.2,
    shortageMult = 1.5, glutMult = 0.7, durationSeconds = 120,
  },
  trends = {                   -- slow changes of the baseline; never on Orbis
    everyMinutes = 15, jitterMinutes = 5, step = 0.25, min = 0.5, max = 1.6, towardChance = 0.6,
    neverOn = { orbis = true },
  },
  rivals = { everySeconds = 90, jitterSeconds = 30, minUnits = 150, maxUnits = 300, convoySeconds = 45 },
  history = { sampleSeconds = 10, keepMinutes = 30 },
  noticesMax = 40,
  streams = { market = 31, events = 131 }, -- rng stream i = seed x this + 7 (config/balance.luau seed)
  -- Trend flavour text (spec §6.3): [market][resource][up|down]. A missing entry falls back to the generic line.
  flavor = {
    halcyon = {
      iridium = { up = "Halcyon switches to iridium-alloy hulls: iridium demand up", down = "Halcyon drops iridium alloys: iridium demand down" },
      titanium = { up = "Halcyon opens a new hull line: titanium demand up", down = "Halcyon yards idle for refit: titanium demand down" },
      cobalt = { up = "Halcyon retools for cobalt plating: cobalt demand up", down = "Halcyon stockpiles are full: cobalt demand down" },
    },
    meridian = {
      crystal = { up = "Meridian starts a new datacenter: crystal demand up", down = "Meridian datacenter build finished: crystal demand down" },
      iridium = { up = "Meridian lab upgrade: iridium demand up", down = "Meridian cancels a lab programme: iridium demand down" },
      titanium = { up = "Meridian builds new labs: titanium demand up", down = "Meridian freezes construction: titanium demand down" },
    },
  },
  trendGeneric = { up = "%s demand for %s is up", down = "%s demand for %s is down" },
}
