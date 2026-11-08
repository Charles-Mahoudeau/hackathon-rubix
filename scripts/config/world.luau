-- World data (spec §4, §5.2): ores, harvest planets, veins, markets, routes. Adding a planet = adding a table here.
-- Module: `local World = require("@scripts/config/world")`. The returned table is read-only.
return {
  homePlanet = "kessa",   -- Kessa depot is the home dock until the warehouse exists
  jumpSeconds = 15,       -- per jump, spec §5.1 travel formula
  minVeinHopSeconds = 5,

  ores = {
    titanium = { name = "Titanium",      basePrice = 10,  hardness = 1.0 },
    cobalt   = { name = "Cobalt",        basePrice = 24,  hardness = 1.0 },
    iridium  = { name = "Iridium",       basePrice = 60,  hardness = 0.5 },
    crystal  = { name = "Data crystals", basePrice = 150, hardness = 0.25 },
  },
  oreOrder = { "titanium", "cobalt", "iridium", "crystal" },

  -- depotRate: HMC corporate depot pays rate x base price, fixed. engineMark: minimum engine to reach.
  planets = {
    kessa   = { name = "Kessa",       depotRate = 0.30, engineMark = 1 },
    varn    = { name = "Varn",        depotRate = 0.25, engineMark = 2 },
    ashfall = { name = "Ashfall",     depotRate = 0.20, engineMark = 3 },
    lumen   = { name = "Lumen Rift",  depotRate = 0.15, engineMark = 3, needsDeepNav = true },
  },
  planetOrder = { "kessa", "varn", "ashfall", "lumen" },

  -- Planet-to-planet travel for the base engine, game seconds (spec §4.2).
  travel = {
    kessa   = { kessa = 0,   varn = 60,  ashfall = 120, lumen = 180 },
    varn    = { kessa = 60,  varn = 0,   ashfall = 80,  lumen = 150 },
    ashfall = { kessa = 120, varn = 80,  ashfall = 0,   lumen = 90 },
    lumen   = { kessa = 180, varn = 150, ashfall = 90,  lumen = 0 },
  },

  -- Veins (spec §4.3). hidden = not visible until `scan`. reserve = max reserve.
  veins = {
    { id = "K1", planet = "kessa",   ore = "titanium", richness = 1.0, jumps = 1, reserve = 3000 },
    { id = "K2", planet = "kessa",   ore = "titanium", richness = 1.4, jumps = 2, reserve = 2500 },
    { id = "K3", planet = "kessa",   ore = "cobalt",   richness = 1.0, jumps = 2, reserve = 2000 },
    { id = "K4", planet = "kessa",   ore = "cobalt",   richness = 1.8, jumps = 3, reserve = 4000, hidden = true },
    { id = "V1", planet = "varn",    ore = "cobalt",   richness = 1.6, jumps = 1, reserve = 3000 },
    { id = "V2", planet = "varn",    ore = "cobalt",   richness = 2.2, jumps = 3, reserve = 5000, hidden = true },
    { id = "V3", planet = "varn",    ore = "iridium",  richness = 0.8, jumps = 2, reserve = 1500 },
    { id = "A1", planet = "ashfall", ore = "iridium",  richness = 1.4, jumps = 2, reserve = 3000 },
    { id = "A2", planet = "ashfall", ore = "iridium",  richness = 2.0, jumps = 3, reserve = 2500, hidden = true },
    { id = "A3", planet = "ashfall", ore = "titanium", richness = 2.5, jumps = 1, reserve = 6000 },
    { id = "L1", planet = "lumen",   ore = "crystal",  richness = 1.0, jumps = 2, reserve = 800 },
    { id = "L2", planet = "lumen",   ore = "crystal",  richness = 1.6, jumps = 3, reserve = 600, hidden = true },
  },
  richnessBands = { mediumFrom = 1.2, highFrom = 1.8 }, -- low < 1.2 <= medium < 1.8 <= high
  reserveRegenPerMinute = 0.01,                          -- fraction of max reserve per game minute

  -- Trade markets (spec §4.4). demand = baseline multiplier per ore; absent ore = not bought.
  -- unlockTier: tier at which the market's prices become available. Dynamics (§6.3) are added with the market milestone.
  markets = {
    orbis    = { name = "Orbis Exchange",    demand = { titanium = 0.6, cobalt = 0.6, iridium = 0.6, crystal = 0.6 }, depth = 4000, unlockTier = 3 },
    halcyon  = { name = "Halcyon Shipyards", demand = { titanium = 1.3, cobalt = 1.2, iridium = 0.9 },               depth = 8000, unlockTier = 4 },
    meridian = { name = "Meridian Institute", demand = { titanium = 0.6, iridium = 1.3, crystal = 1.4 },             depth = 5000, unlockTier = 4 },
  },
  marketOrder = { "orbis", "halcyon", "meridian" },

  -- Freighter one-way travel from a station planet to each market (spec §5.2).
  freighterRoutes = {
    kessa   = { orbis = 60,  halcyon = 240, meridian = 300 },
    varn    = { orbis = 100, halcyon = 200, meridian = 320 },
    ashfall = { orbis = 160, halcyon = 260, meridian = 200 },
    lumen   = { orbis = 240, halcyon = 340, meridian = 140 },
  },
}
