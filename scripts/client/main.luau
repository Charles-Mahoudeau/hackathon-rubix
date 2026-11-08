-- Client entry (project.luau scripts.client): the UI shell over the system map.
-- The world (background, planets) is spawned once and respawned only when a planet unlocks; the UI layer is rebuilt at
-- most every `refreshSeconds`, and only when something it shows changed. Until the net protocol ([ENGINE], spec §16)
-- replicates the sim, the client runs a local stand-in Sim at 10 Hz so the shell shows real numbers.
local Screens = require("@scripts/config/screens")
local Theme = require("@scripts/config/theme")
local Sim = require("@scripts/sim/sim")
local Shell = require("@scripts/ui/shell")
local Editor = require("@scripts/ui/agent_editor")
local ComputeView = require("@scripts/ui/compute_view")
local UiTheme = require("@scripts/ui/theme")
local Model = require("@scripts/ui/shell_model")
local Background = require("@scripts/client/background")
local SystemMap = require("@scripts/client/system_map")

local state = {
	sim = nil, shell = Shell.new(), ui = nil, world = {}, worldSig = nil, uiSig = nil, lastRefresh = -1e9, lastTime = nil, acc = 0,
	draft = nil, toast = nil, inputs = nil, inputsDirty = true, -- agent editor (GR5-5)
	tab = "editor", -- Agents screen tab: "editor" | "context" (GR5-6)
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
	state.ui, shown = Shell.spawn(commands, state.sim, state.shell.screen, { glitch = glitchFrame, draft = state.draft, toast = state.toast, tab = state.tab })
	state.shell.screen = shown
end

-- The editor's two text inputs live in their own tree so a shell redraw never drops the focus. Respawned only when the
-- draft changes from outside the fields (screen entry, preset, save, clear), never while the player types.
local function syncInputs(commands)
	local editing = state.shell.screen == "agents" and state.tab == "editor"
	if state.inputs and (not editing or state.inputsDirty) then
		commands:despawn(state.inputs)
		state.inputs = nil
	end
	if editing and not state.inputs then
		state.inputs = engine.ui.spawn(commands, Shell.inputsSpec(state.draft, { font = UiTheme.font() }))
	end
	state.inputsDirty = false
end

local function editorClick(action)
	local id = Screens.editor.agent
	if action == "editor.save" then
		local ok, msg = Editor.save(state.sim, id, state.draft)
		state.toast = ok and msg or nil
	elseif action == "editor.clear_order" then
		Editor.clearOrder(state.sim, id, state.draft)
		state.toast, state.inputsDirty = nil, true
	elseif action:sub(1, 11) == "editor.tab." then
		state.tab, state.toast, state.inputsDirty = action:sub(12), nil, true
	elseif action:sub(1, 14) == "editor.preset." then
		Editor.applyPreset(state.sim, state.draft, action:sub(15))
		state.toast, state.inputsDirty = nil, true
	else
		return false
	end
	return true
end

engine.ecs.system("game.Shell", {
	phase = "Update",
	side = "client",
	query = { read = { "rtype.UiText", "rtype.UiTextInput" } },
	events = { read = { "rtype.UiClicked", "rtype.UiTextChanged" } },
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

		state.draft = state.draft or Editor.newDraft(state.sim, Screens.editor.agent)
		-- The typed text is in the input's UiText; the input's `action` says which field it is.
		for _ in ctx.events.read("rtype.UiTextChanged") do
			for _, text, input in ctx.query do
				if input.action == "editor.directive" then state.draft.directive = text.text
				elseif input.action == "editor.order" then state.draft.order = text.text end
			end
			state.toast, changed = nil, true
		end

		for click in ctx.events.read("rtype.UiClicked") do
			if editorClick(click.action) then changed = true end
			if ComputeView.act(state.sim, Screens.editor.agent, click.action) then changed = true end
			local screen = Shell.parseAction(click.action, state.sim.tier)
			if screen and screen ~= state.shell.screen then
				state.shell.screen, state.uiSig, state.worldSig, changed = screen, nil, nil, true
				if screen == "agents" then
					state.draft, state.toast, state.inputsDirty = Editor.newDraft(state.sim, Screens.editor.agent), nil, true
				end
			end
		end

		local worldSig = state.shell.screen .. "|" .. SystemMap.signature(state.sim)
		if worldSig ~= state.worldSig then
			state.worldSig = worldSig
			rebuildWorld(ctx.commands)
		end

		local extra = ""
		if state.shell.screen == "agents" and state.sim.agents[Screens.editor.agent] then
			local m = Editor.model(state.sim, Screens.editor.agent, state.draft)
			local rates = {}
			for _, row in ipairs(ComputeView.agentRows(state.sim)) do rates[#rates + 1] = row.id .. row.computePerHour .. row.state end
			local settings = {}
			for key, value in pairs(state.sim.agents[Screens.editor.agent].contextSettings) do settings[#settings + 1] = key .. "=" .. tostring(value) end
			table.sort(settings)
			extra = table.concat({ state.tab, state.draft.directive, state.draft.order, state.toast or "", m.totalTokens,
				table.concat(rates, ","), table.concat(settings, ",") }, "|")
		end
		local sig = Model.signature(state.sim, state.shell.screen, extra)
		local due = now - state.lastRefresh >= Screens.refreshSeconds
		if glitchFrame or changed or (due and (sig ~= state.uiSig or #state.sim.freighters > 0)) then
			state.uiSig, state.lastRefresh = sig, now
			rebuildUi(ctx.commands, glitchFrame)
		end
		syncInputs(ctx.commands)
	end,
})
