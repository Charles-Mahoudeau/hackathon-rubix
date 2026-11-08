-- GR5-105: the map progression tour only uses real purchases (nothing refused), its reveals match the game's reachability
-- rules step by step, and a loaded sim (the reload case) starts with everything already reachable.
local Tour = require("@scripts/client/map_tour")
local DebugConfig = require("@scripts/config/debug")
local Reveal = require("@scripts/render/vfx/reveal")
local Model = require("@scripts/ui/shell_model")
local World = require("@scripts/config/world")

assert(DebugConfig.mapTour == false and DebugConfig.qaTour == false, "the tours are off in the repo")

local sim
local actions = {}
local api = { now = 0, sim = function() return sim end, setSim = function(s) sim = s end, dispatch = function(a) actions[#actions + 1] = a return false end }
local tour = Tour.new()
local rev, revealed, tiers = Reveal.new(), {}, {}
local function observe()
	local lit = {}
	for _, p in ipairs(Model.map(sim).planets) do lit[p.id] = p.lit end
	for _, id in ipairs(Reveal.observe(rev, lit, World.planetOrder, sim)) do revealed[#revealed + 1] = tour.label .. ":" .. id end
	for _, e in ipairs(sim:drainEvents()) do if e.name == "tier_up" then tiers[#tiers + 1] = tour.label .. ":" .. e.data.tier end end
end
Tour.update(tour, api)
tour.label = "00 setup"
observe()
for i = 1, #Tour.steps + 1 do
	api.now = i * 10
	Tour.update(tour, api)
	observe()
end
assert(tour.done and #tour.notes == 0, "a purchase was refused: " .. table.concat(tour.notes, "; "))
local got = table.concat(revealed, ",")
assert(got == "03 t2-mk2-varn:varn,05 t3-mk3-ashfall:ashfall,07 t4-deepnav-lumen:lumen,10 simul-mk3-ashfall-lumen:ashfall,10 simul-mk3-ashfall-lumen:lumen,13 exit-mk2-reveal-starts:varn", got)
-- the tier cue comes with the warehouse/hub/command center, never with a planet-only unlock
local t = table.concat(tiers, ",")
assert(t:find("t2%-before:2") and t:find("t3%-warehouse%-tier%-cue:3") and t:find("t4%-hub%-tier%-cue:4") and t:find("t5%-command%-center:5"), t)
for _, tag in ipairs({ "mk2-varn", "mk3-ashfall", "deepnav-lumen", "mk3-ashfall-lumen" }) do assert(not t:find(tag), "a planet unlock raised a tier event: " .. tag) end

-- the reload case: everything reachable at the first sight, so the reveal only records
local notes = {}
sim = Tour.loaded(notes)
assert(#notes == 0 and sim.tier >= 4, "loaded sim")
local r2 = Reveal.new()
local lit = {}
for _, p in ipairs(Model.map(sim).planets) do lit[p.id] = p.lit end
assert(#Reveal.observe(r2, lit, World.planetOrder, sim) == 0 and not Reveal.busy(r2) and lit.lumen and lit.ashfall and lit.varn)
print("test_map_tour ok")
