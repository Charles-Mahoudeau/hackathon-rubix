-- World layout (spec §4/§16.1): planets, veins, markets. Tunable data only.
local world = {
  startBuyer = "meridian",
  veinCount = 4,
  veinRichnessMin = 0.5,
  veinRichnessMax = 1.5,
  planets = {
    { id = "meridian", name = "Meridian Base", kind = "trade", jumps = 0, tier = 1,
      prices = { titanium = 10, cobalt = 14 } },
    { id = "kessel", name = "Kessel", kind = "harvest", jumps = 2, tier = 1, ore = "titanium", oreBonus = 1.3 },
    { id = "vanta", name = "Vanta", kind = "harvest", jumps = 4, tier = 1, ore = "cobalt", oreBonus = 1.3 },
    { id = "halcyon", name = "Halcyon Port", kind = "trade", jumps = 5, tier = 4,
      prices = { titanium = 14, cobalt = 20 } },
  },
}
return world
