-- Command-center price counterfactual (GR5-63): the scripted player on seeds 1-3 at each price, with and without claiming missions.
-- Run from the repo root: luau tools/price_compare.luau   (see tools/price_compare.sh). Config is never modified: the price is a balance override.
local Sim = require("@scripts/sim/sim")
local Pacing = require("@scripts/sim/pacing")
local Missions = require("@scripts/sim/missions")
local Balance = require("@scripts/config/balance")
local Config = require("@scripts/config/pacing")

local PRICES = { 160000, 15000 }
local VARIANTS = { { name = "no claim", claim = false }, { name = "auto-claim", claim = true } }

local function minutes(s) return s and ("%.1f"):format(s / 60) or "-" end
local function k(n) return (tostring(math.floor(n + 0.5)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")) end

local function runOne(price, seed, claim)
  local b = Sim.deepCopy(Balance)
  b.shop.items.command_center.cost = price
  local doneAt = {}
  local data = Pacing.run({ seed = seed, balance = b, onSecond = function(sim)
    for _, m in ipairs(sim.missions) do
      if m.status == "complete" or m.status == "claimed" then doneAt[m.id] = doneAt[m.id] or sim.tick * sim.b.tickSeconds end
      if claim and m.status == "complete" then Missions.claim(sim, m.id) end
    end
  end })
  data.doneAt = doneAt
  return data
end

local function median(v)
  table.sort(v)
  local n = #v
  return n % 2 == 1 and v[(n + 1) / 2] or (v[n / 2] + v[n / 2 + 1]) / 2
end

print("# Command-center price counterfactual (GR5-63)")
print("")
print(("Scripted player, stub AI, %s game-min, x1. Targets T3 25 / T4 60 / T5 120 min, +/-30%%. Only `shop.items.command_center.cost` differs between rows."):format(minutes(Config.report.seconds)))
for _, variant in ipairs(VARIANTS) do
  print("")
  print(("## Missions: %s"):format(variant.name))
  print("")
  print("| Price | Seed | T3 | T4 | T5 | Rev@T5 | Rep@T5 | Compute billed@T5 (cr) | Compute billed total (cr) | Final rev | Final rep | Missions done (min) |")
  print("|---|---|---|---|---|---|---|---|---|---|---|---|")
  for _, price in ipairs(PRICES) do
    local t3, t4, t5 = {}, {}, {}
    for _, seed in ipairs(Config.report.seeds) do
      local r = runOne(price, seed, variant.claim)
      local T = r.tiers
      if T[3] then t3[#t3 + 1] = T[3].at end
      if T[4] then t4[#t4 + 1] = T[4].at end
      if T[5] then t5[#t5 + 1] = T[5].at end
      local done = {}
      for id = 1, 8 do if r.doneAt[id] then done[#done + 1] = ("%d@%s"):format(id, minutes(r.doneAt[id])) end end
      print(("| %s | %d | %s | %s | %s | %s | %s | %s | %s | %s | %d | %s |"):format(k(price), seed, minutes(T[3] and T[3].at), minutes(T[4] and T[4].at), minutes(T[5] and T[5].at),
        T[5] and k(T[5].revenue) or "-", T[5] and tostring(T[5].rep) or "-", T[5] and k(T[5].compute * 40) or "-", k(r.computeBilled * 40), k(r.finalRevenue), r.finalRep,
        #done > 0 and table.concat(done, " ") or "none"))
      if seed == Config.report.seeds[1] and not variant.claim then
        local parts = {}
        for _, p in ipairs(r.purchases) do parts[#parts + 1] = ("%s@%s"):format(p.id, minutes(p.t)) end
        print(("<!-- seed 1 purchases at %s: %s -->"):format(k(price), table.concat(parts, ", ")))
      end
    end
    print(("| %s | median | %s | %s | %s | | | | | | | |"):format(k(price), minutes(median(t3)), minutes(median(t4)), #t5 == #Config.report.seeds and minutes(median(t5)) or "not reached"))
  end
end

print("")
print("## Sensitivity sweep (no claim, median of seeds)")
print("")
print("| Price | T5 median (min) | vs 120 target | Rep at T5 (seed 1) | Revenue at T5 (seed 1) |")
print("|---|---|---|---|---|")
for _, price in ipairs({ 15000, 40000, 80000, 120000, 160000, 200000 }) do
  local t5, first = {}, nil
  for _, seed in ipairs(Config.report.seeds) do
    local r = runOne(price, seed, false)
    if r.tiers[5] then t5[#t5 + 1] = r.tiers[5].at end
    first = first or r
  end
  local T5 = first.tiers[5]
  local med = #t5 == #Config.report.seeds and median(t5) or nil
  print(("| %s | %s | %s | %s | %s |"):format(k(price), med and minutes(med) or "not reached", med and ("%+.0f%%"):format((med - 7200) / 7200 * 100) or "-",
    T5 and tostring(T5.rep) or "-", T5 and k(T5.revenue) or "-"))
end
