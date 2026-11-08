-- QA tour (GR5-89): a scripted walk through every screen on a prepared T5 company, for capturing the real runtime where
-- nothing can click. Off unless config/debug.luau `qaTour` is true. Each step sends the same action strings the buttons
-- send (client/main.luau `dispatch`) and shows "[QA <n> <name>]" in the feed header (stdout is not captured by the runtime); tools/qa_capture.sh shoots on a timer.
-- Pure Lua, so the preparation is checked headless by tests/test_qa_tour.luau.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Market = require("@scripts/sim/market")
local Skills = require("@scripts/sim/skills")

local Tour = {}

-- A T5 company: command center, Monitor, a Logistician, a saved loop, three prompt versions, errors in the log, an
-- offline report ready to show. Returns the sim and the notes of anything that could not be set up.
function Tour.prepare()
	local notes = {}
	local function try(what, ok, err)
		if not ok then notes[#notes + 1] = what .. ": " .. tostring(err) end
		return ok
	end
	local s = Sim.new()
	s.tier = 5
	for _, a in pairs(s.agents) do a.tier = 5 end
	s.lifetimeRevenue = s.b.reputationLevels[2]
	s.resources.credits = 400000
	s.resources.compute = 300
	Market.quiet(s.market)
	s:setDecider(Ai.decide)
	for _, up in ipairs({ "scanner", "archive", "ship2", "engine_mk2", "engine_mk3", "warehouse", "trading_post", "logistics_hub", "command_center" }) do
		try("buy " .. up, s:buyUpgrade(up))
	end
	try("hire Logistician", s:hireLogistician("kessa"))
	try("open salvage", s:openBranch("salvage"))
	try("hire Monitor", s:hireMonitor())
	try("save loop", Skills.save(s, { name = "Titanium loop", agent_type = "miner", loop = true,
		params = { vein = { kind = "vein", filter = { resource = "titanium" } } },
		steps = { { tool = "mine", args = { vein = "$vein" } }, { tool = "return" }, { tool = "sell" } } }))
	-- three versions of the Miner's prompt, each active long enough (>= 3 game min) except the last
	s:setDirective("miner", "Mine titanium on K1 until the hold is 90%, then sell at HMC.")
	s:run(s:ticks(600))
	s:setDirective("miner", "Mine cobalt on K3 until the hold is 100%, then sell at HMC. Scan first.")
	s:run(s:ticks(600))
	s:setDirective("miner", "Mine titanium on K1, sell at HMC. Keep the hold at 80%.")
	s:run(s:ticks(60))
	return s, notes
end

-- Steps: { name, actions = { ... }, run = function(sim, api), hold = seconds }. `api.sim()` is the live sim.
Tour.steps = {
	{ name = "map", actions = { "nav.map" } },
	{ name = "agents-editor", actions = { "nav.agents", "editor.tab.editor" } },
	{ name = "agents-examples", actions = { "editor.examples.toggle", "editor.example.pick.miner_good" } },
	{ name = "agents-examples-used", actions = { "editor.example.use.miner_good" } },
	{ name = "agents-context", actions = { "editor.tab.context" } },
	{ name = "agents-context-format-json", actions = { "context.format.2" } },
	{ name = "team", actions = { "nav.team" } },
	{ name = "logs", actions = { "nav.logs" } },
	{ name = "logs-filter-miner", actions = { "logs.agent.miner" } },
	{ name = "logs-filter-skill", actions = { "logs.agent.all", "logs.source.skill" } },
	{ name = "logs-errors", actions = { "logs.source.all", "logs.errors" } },
	{ name = "logs-select", actions = { "logs.errors", "@select-first-record" } },
	{ name = "logs-compare", actions = { "logs.compare" } },
	{ name = "logs-compare-pick", actions = { "@compare-pick" } },
	{ name = "archive-list", actions = { "logs.compare", "nav.archive", "studio.mode.list" } },
	{ name = "studio-record", actions = { "studio.mode.record" } },
	{ name = "studio-form", actions = { "studio.mode.form", "studio.form.add.mine", "studio.form.add.return", "studio.form.add.sell", "studio.form.guard.3" } },
	{ name = "studio-form-saved", actions = { "studio.form.save" } },
	{ name = "studio-form-again", actions = { "studio.mode.form", "studio.form.add.mine", "studio.form.arg.1.vein", "studio.form.add.return", "studio.form.add.sell" } },
	{ name = "studio-suggest", actions = { "studio.form.save" } },
	{ name = "studio-make-param", actions = { "studio.sug.accept" } },
	{ name = "studio-assign", actions = { "studio.mode.list", "studio.assign.Titanium loop.miner" } },
	{ name = "studio-running", actions = { "studio.assign.start" }, hold = 4 },
	{ name = "monitor-order", run = function(sim)
		sim:apply("monitor", { name = "set_order", args = { agent = "miner2", text = "Sell your cobalt at HMC when the hold is full." } })
	end, actions = { "nav.map" }, hold = 4 },
	{ name = "alerts", actions = { "nav.alerts" } },
	{ name = "alerts-toggles", actions = { "alerts.type.agent_idle", "alerts.heartbeat.down", "alerts.heartbeat.down" } },
	{ name = "alerts-heartbeat-off", actions = { "alerts.heartbeat.off" } },
	{ name = "branches", actions = { "nav.branches" } },
	{ name = "offline", actions = { "nav.archive", "studio.mode.list", "archive.away" }, hold = 5 },
	{ name = "station", actions = { "offline.dismiss", "nav.station" } },
	{ name = "market", actions = { "nav.market" } },
	{ name = "fleet", actions = { "nav.fleet" } },
	{ name = "missions", actions = { "nav.missions" } },
	{ name = "map-feed", actions = { "nav.map" }, hold = 4 },
}

function Tour.new() return { index = 0, nextAt = 0, done = false } end

local function firstRecordId(sim)
	local list = sim.records.miner or {}
	return list[#list] and list[#list].id
end

-- Called every frame. `api` = { dispatch = fn(action) -> changed, sim = fn() -> sim, setSim = fn(sim), now = seconds }.
-- Returns true when the UI must redraw.
function Tour.update(tour, api)
	if tour.done or api.now < tour.nextAt then return false end
	if tour.index == 0 then
		local sim, notes = Tour.prepare()
		api.setSim(sim)
		tour.notes = notes
		tour.index, tour.nextAt = 1, api.now + 3
		return true
	end
	local step = Tour.steps[tour.index]
	if not step then
		tour.done = true
		return false
	end
	local sim = api.sim()
	if step.run then step.run(sim, api) end
	for _, action in ipairs(step.actions) do
		if action == "@select-first-record" then
			local id = firstRecordId(sim)
			if id then api.dispatch("logs.select." .. id) end
		elseif action == "@compare-pick" then
			local list = sim.versions.miner or {}
			if #list >= 2 then
				api.dispatch("logs.cmpagent.miner")
				api.dispatch("logs.cmpa." .. list[1].id)
				api.dispatch("logs.cmpb." .. list[#list].id)
			end
		else
			api.dispatch(action)
		end
	end
	tour.label = ("%02d %s"):format(tour.index, step.name)
	tour.index += 1
	tour.nextAt = api.now + (step.hold or 3)
	return true
end

return Tour
