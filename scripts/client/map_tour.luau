-- Map progression tour (GR5-105): a scripted T1 -> T5 run for capturing the planet reveal in the real runtime, where nothing can click.
-- Off unless config/debug.luau `mapTour` is true. Setup is controlled: credits and lifetime revenue are granted (debug), everything else
-- is a real purchase through sim:buyUpgrade, so each reveal follows from the game's own reachability rules. Same interface as qa_tour.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Market = require("@scripts/sim/market")

local Tour = {}

local function fresh(opts)
	local s = Sim.new()
	Market.quiet(s.market)
	s:setDecider(Ai.decide)
	s.resources.credits = 400000
	if opts and opts.deepNav then s.deepNav = true end
	return s
end

local function buy(notes, sim, id)
	local ok, err = sim:buyUpgrade(id)
	if not ok then notes[#notes + 1] = "buy " .. id .. ": " .. tostring(err) end
	return ok
end

-- A sim that already owns what the full progression buys, as a loaded save would: nothing may be revealed or sounded for it.
function Tour.loaded(notes)
	local s = fresh()
	s.lifetimeRevenue = s.b.reputationLevels[3]
	s:updateTier()
	for _, id in ipairs({ "engine_mk2", "warehouse", "engine_mk3", "logistics_hub", "deep_nav" }) do buy(notes, s, id) end
	s:run(s:ticks(60))
	return s
end

-- Steps: { name, run = function(sim, api, notes), actions = { ... }, hold = seconds }. `api.setSim(sim)` swaps in a prepared sim.
Tour.steps = {
	{ name = "t1-start", actions = { "nav.map" }, hold = 3 },
	{ name = "t2-before", run = function(s) s.lifetimeRevenue = s.b.tierRevenue[2]; s:updateTier() end, hold = 3 },
	{ name = "t2-mk2-varn", run = function(s, _, n) buy(n, s, "engine_mk2") end, hold = 4 },
	{ name = "t3-warehouse-tier-cue", run = function(s, _, n) s.lifetimeRevenue = s.b.reputationLevels[2]; buy(n, s, "warehouse") end, hold = 3 },
	{ name = "t3-mk3-ashfall", run = function(s, _, n) buy(n, s, "engine_mk3") end, hold = 4 },
	{ name = "t4-hub-tier-cue", run = function(s, _, n) buy(n, s, "logistics_hub") end, hold = 3 },
	{ name = "t4-deepnav-lumen", run = function(s, _, n) buy(n, s, "deep_nav") end, hold = 4 },
	{ name = "t5-command-center", run = function(s, _, n) s.lifetimeRevenue = s.b.reputationLevels[3]; buy(n, s, "command_center") end, hold = 4 },
	{ name = "simul-before", run = function(s, api, n)
		local sim = fresh({ deepNav = true })
		sim.lifetimeRevenue = sim.b.reputationLevels[2]
		sim:updateTier(); buy(n, sim, "engine_mk2"); buy(n, sim, "warehouse")
		api.setSim(sim)
	end, actions = { "nav.map" }, hold = 3 },
	{ name = "simul-mk3-ashfall-lumen", run = function(s, _, n) buy(n, s, "engine_mk3") end, hold = 6 },
	{ name = "reload-hydration", run = function(_, api, n) api.setSim(Tour.loaded(n)) end, actions = { "nav.map" }, hold = 4 },
	{ name = "exit-before", run = function(_, api, n)
		local sim = fresh()
		sim.lifetimeRevenue = sim.b.tierRevenue[2]
		sim:updateTier()
		api.setSim(sim)
	end, actions = { "nav.map" }, hold = 3 },
	{ name = "exit-mk2-reveal-starts", run = function(s, _, n) buy(n, s, "engine_mk2") end, hold = 0.8 },
	{ name = "exit-left-for-agents", actions = { "nav.agents" }, hold = 3 },
	{ name = "exit-back-on-map", actions = { "nav.map" }, hold = 4 },
}

function Tour.new() return { index = 0, nextAt = 0, done = false, notes = {} } end

function Tour.update(tour, api)
	if tour.done or api.now < tour.nextAt then return false end
	if tour.index == 0 then
		api.setSim(fresh())
		tour.index, tour.nextAt = 1, api.now + 3
		return true
	end
	local step = Tour.steps[tour.index]
	if not step then
		tour.done = true
		return false
	end
	if step.run then step.run(api.sim(), api, tour.notes) end
	for _, action in ipairs(step.actions or {}) do api.dispatch(action) end
	tour.label = ("%02d %s"):format(tour.index, step.name)
	tour.index += 1
	tour.nextAt = api.now + (step.hold or 3)
	return true
end

return Tour
