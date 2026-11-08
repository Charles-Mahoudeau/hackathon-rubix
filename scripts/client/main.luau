-- Client entry (project.luau scripts.client): the UI shell over the system map.
-- The world (background, planets) is spawned once and respawned only when a planet unlocks; the UI layer is rebuilt at
-- most every `refreshSeconds`, and only when something it shows changed. Until the net protocol ([ENGINE], spec §16)
-- replicates the sim, the client runs a local stand-in Sim at 10 Hz so the shell shows real numbers.
local Screens = require("@scripts/config/screens")
local Theme = require("@scripts/config/theme")
local Sim = require("@scripts/sim/sim")
local Shell = require("@scripts/ui/shell")
local Model = require("@scripts/ui/shell_model")
local Background = require("@scripts/client/background")
local SystemMap = require("@scripts/client/system_map")

local state = {
	sim = nil, shell = Shell.new(), ui = nil, world = {}, worldSig = nil, uiSig = nil, lastRefresh = -1e9, lastTime = nil, acc = 0,
}

local function despawnAll(commands, list)
	for _, e in ipairs(list) do commands:despawn(e) end
end

local function rebuildWorld(commands)
	despawnAll(commands, state.world)
	state.world = {}
	local v = Theme.layout.view
	for _, desc in ipairs(Background.new(Screens.defaultScreen, { x = v.w, y = v.h }, { x = v.w / 2, y = v.h / 2 })) do
		state.world[#state.world + 1] = commands:spawn(desc)
	end
	if state.shell.screen == Screens.defaultScreen then
		for _, desc in ipairs(SystemMap.entities(state.sim)) do state.world[#state.world + 1] = commands:spawn(desc) end
	end
end

local function rebuildUi(commands, glitchFrame)
	if state.ui then commands:despawn(state.ui) end
	local shown
	state.ui, shown = Shell.spawn(commands, state.sim, state.shell.screen, { glitch = glitchFrame })
	state.shell.screen = shown
end

engine.ecs.system("game.Shell", {
	phase = "Update",
	side = "client",
	query = {},
	events = { read = { "rtype.UiClicked" } },
	run = function(ctx)
		local now = ctx.time.elapsed
		state.sim = state.sim or Sim.new()
		local dt = state.lastTime and (now - state.lastTime) or 0
		state.lastTime = now

		state.acc += dt
		local step = state.sim.b.tickSeconds
		while state.acc >= step do
			state.sim:step()
			state.acc -= step
		end
		local changed = false
		for _, event in ipairs(state.sim:drainEvents()) do
			if Shell.onSimEvent(state.shell, event) then changed = true end
		end
		local glitchFrame = Shell.update(state.shell, dt)

		for click in ctx.events.read("rtype.UiClicked") do
			local screen = Shell.parseAction(click.action, state.sim.tier)
			if screen and screen ~= state.shell.screen then
				state.shell.screen, state.uiSig, state.worldSig, changed = screen, nil, nil, true
			end
		end

		local worldSig = state.shell.screen .. "|" .. SystemMap.signature(state.sim)
		if worldSig ~= state.worldSig then
			state.worldSig = worldSig
			rebuildWorld(ctx.commands)
		end

		local sig = Model.signature(state.sim, state.shell.screen)
		local due = now - state.lastRefresh >= Screens.refreshSeconds
		if glitchFrame or changed or (due and (sig ~= state.uiSig or #state.sim.freighters > 0)) then
			state.uiSig, state.lastRefresh = sig, now
			rebuildUi(ctx.commands, glitchFrame)
		end
	end,
})
