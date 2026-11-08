-- Client entry (project.luau scripts.client): the UI shell over the system map.
-- The world (background, planets) is spawned once and respawned only when a planet unlocks; the UI layer is rebuilt at
-- most every `refreshSeconds`, and only when something it shows changed. Until the net protocol ([ENGINE], spec §16)
-- replicates the sim, the client runs a local stand-in Sim at 10 Hz so the shell shows real numbers.
local Screens = require("@scripts/config/screens")
local Theme = require("@scripts/config/theme")
local Sim = require("@scripts/sim/sim")
local Clock = require("@scripts/sim/clock")
local Shell = require("@scripts/ui/shell")
local Editor = require("@scripts/ui/agent_editor")
local ComputeView = require("@scripts/ui/compute_view")
local LogsView = require("@scripts/ui/logs_view")
local ShopView = require("@scripts/ui/shop_view")
local FleetView = require("@scripts/ui/fleet_view")
local MissionsView = require("@scripts/ui/missions_view")
local AlertsView = require("@scripts/ui/alerts_view")
local BranchesView = require("@scripts/ui/branches_view")
local ArchiveView = require("@scripts/ui/archive_view")
local SkillStudio = require("@scripts/ui/skill_studio")
local TeamView = require("@scripts/ui/team_view")
local OfflineView = require("@scripts/ui/offline_view")
local MarketView = require("@scripts/ui/market_view")
local UiTheme = require("@scripts/ui/theme")
local Model = require("@scripts/ui/shell_model")
local Background = require("@scripts/client/background")
local SystemMap = require("@scripts/client/system_map")
require("@scripts/client/station_fx")
local Audio = require("@scripts/client/audio")
local Sounds = require("@scripts/client/sounds")

local state = {
	sim = nil, shell = Shell.new(), ui = nil, world = {}, worldSig = nil, stationLayer = {}, stationSig = nil, uiSig = nil, lastRefresh = -1e9, lastTime = nil,
	draft = nil, toast = nil, inputs = nil, inputsDirty = true, -- agent editor (GR5-5)
	tab = "editor", -- Agents screen tab: "editor" | "context" (GR5-6)
	logs = LogsView.new(), -- Logs screen filters and selection (GR5-8)
	studio = SkillStudio.new(), -- Archive screen: record / form / assign state (GR5-26)
	audio = Audio.new(), musicStarted = false, -- sound cues and the ambient loop (GR5-23)
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

-- The stations are their own layer so a station growing or going active never respawns the background (GR5-52).
local function rebuildStations(commands)
	despawnAll(commands, state.stationLayer)
	state.stationLayer = {}
	if state.shell.screen == Screens.defaultScreen then
		for _, desc in ipairs(SystemMap.stationEntities(state.sim)) do state.stationLayer[#state.stationLayer + 1] = commands:spawn(desc) end
	end
end

-- A UI tree spawned this frame has no computed layout until the next one and is not drawn before then, so despawning the
-- old tree in the same frame leaves a blank frame (the flicker). Old trees live on for a few frames, then go.
local RETIRE_FRAMES = 2
local retired = {}

local function retire(entity)
	if entity then retired[#retired + 1] = { entity = entity, frames = RETIRE_FRAMES } end
end

local function flushRetired(commands)
	local keep = {}
	for _, r in ipairs(retired) do
		r.frames -= 1
		if r.frames <= 0 then commands:despawn(r.entity) else keep[#keep + 1] = r end
	end
	retired = keep
end

local function rebuildUi(commands, glitchFrame)
	retire(state.ui)
	local shown
	state.ui, shown = Shell.spawn(commands, state.sim, state.shell.screen, { glitch = glitchFrame, time = state.lastTime, focus = state.shell.focus, draft = state.draft, toast = state.toast, tab = state.tab, logs = state.logs, studio = state.studio })
	state.shell.screen = shown
end

-- The editor's two text inputs live in their own tree so a shell redraw never drops the focus. Respawned only when the
-- draft changes from outside the fields (screen entry, preset, save, clear), never while the player types.
local function syncInputs(commands)
	local editing = state.shell.screen == "agents" and state.tab == "editor"
	if state.inputs and (not editing or state.inputsDirty) then
		-- Not retired like the shell tree: two live fields with the same action would both feed UiTextChanged.
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
	elseif action == "editor.lock" then
		local a = state.sim.agents[id]
		state.sim:setMonitorLock(id, not (a and a.monitorLock))
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
	events = { read = { "rtype.UiClicked", "rtype.UiTextChanged" }, send = { "rtype.PlayMusic" } },
	calls = { "rtype.audio.playSound" },
	run = function(ctx)
		local now = ctx.time.elapsed
		state.sim = state.sim or Sim.new()
		local dt = state.lastTime and (now - state.lastTime) or 0
		state.lastTime = now

		Clock.advance(state.sim, dt)
		local changed = false
		if not state.musicStarted then
			state.musicStarted = true
			Sounds.startMusic(ctx)
		end
		Audio.beginFrame(state.audio, now)
		for _, event in ipairs(state.sim:drainEvents()) do
			-- The AI-error sound plays only when the glitch accepted the same event, so sound and flicker stay one trigger.
			local glitched = Shell.onSimEvent(state.shell, event)
			if glitched then changed = true end
			local play = Audio.onEvent(state.audio, event, { speed = state.sim.speed, glitch = glitched })
			if play then Sounds.play(ctx, play) end
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
			if Shell.act(state.shell, click.action) then changed = true end
			if ComputeView.act(state.sim, Screens.editor.agent, click.action) then changed = true end
			if LogsView.act(state.logs, click.action) then changed = true end
			if ShopView.act(state.sim, click.action) then changed = true end
			if FleetView.act(state.sim, click.action) then changed = true end
			if MissionsView.act(state.sim, click.action) then changed = true end
			if AlertsView.act(state.sim, click.action) then changed = true end
			if BranchesView.act(state.sim, click.action) then changed = true end
			if ArchiveView.act(state.sim, click.action) then changed = true end
			local handled, openScreen = SkillStudio.act(state.sim, state.studio, click.action)
			if handled then changed = true end
			if openScreen and openScreen ~= state.shell.screen then
				state.shell.screen, state.uiSig, state.worldSig = openScreen, nil, nil
			end
			if OfflineView.act(state.sim, click.action) then changed = true end
			if Clock.act(state.sim, click.action) then changed = true end
			local teamHandled, teamAgent = TeamView.act(state.sim, click.action)
			if teamHandled and teamAgent then
				Screens.editor.agent = teamAgent
				click = { action = "nav.agents" }
				state.draft, state.toast, state.inputsDirty = Editor.newDraft(state.sim, teamAgent), nil, true
			end
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

		local stationSig = state.shell.screen .. "|" .. SystemMap.stationSignature(state.sim)
		if stationSig ~= state.stationSig then
			state.stationSig = stationSig
			rebuildStations(ctx.commands)
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
		if state.shell.screen == "logs" then extra = LogsView.signature(state.sim, state.logs) end
		if state.shell.screen == "shop" then extra = ShopView.signature(state.sim) end
		if state.shell.screen == "fleet" then extra = FleetView.signature(state.sim) end
		if state.shell.screen == "team" then extra = TeamView.signature(state.sim) end
		if state.shell.screen == "alerts" then extra = AlertsView.signature(state.sim) end
		if state.shell.screen == "branches" then extra = BranchesView.signature(state.sim) end
		if state.shell.screen == "missions" then extra = MissionsView.signature(state.sim) end
		if state.shell.screen == "archive" then extra = ArchiveView.signature(state.sim) .. "|" .. SkillStudio.signature(state.sim, state.studio) end
		if state.shell.screen == Screens.defaultScreen then extra = tostring(state.shell.focus) end
		if state.shell.screen == "market" then extra = MarketView.signature(state.sim) end
		local sig = Model.signature(state.sim, state.shell.screen, extra)
		-- The map animates (planet pulse, moving route dashes), so it redraws on its own faster beat.
		local onMap = state.shell.screen == Screens.defaultScreen
		local due = now - state.lastRefresh >= (onMap and Screens.map.animSeconds or Screens.refreshSeconds)
		if glitchFrame or changed or (due and (onMap or sig ~= state.uiSig or #state.sim.freighters > 0)) then
			state.uiSig, state.lastRefresh = sig, now
			rebuildUi(ctx.commands, glitchFrame)
		end
		syncInputs(ctx.commands)
		flushRetired(ctx.commands)
	end,
})
