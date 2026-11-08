-- Audio (GR5-23): which sound plays for what, and how loud. Numbers and file names only; the sounds themselves are
-- synthesised by tools/build_audio.py (original work, CC0, no third-party pack). No logic lives here.
return {
	-- Bus volumes handed to engine.settings.audio.volume (project.luau).
	volume = { master = 0.8, music = 0.45, effects = 1.0 },
	-- Hard limits so a busy sim never turns into noise.
	maxPlaysPerFrame = 3,
	pitchSeed = 23023, -- LCG seed of the small pitch variation (client side only, never the sim's RNG)

	music = {
		file = "audio/music_ambient.ogg", -- a 40 s seamless loop
		crossfade = 2.0, -- seconds of fade-in at start
	},

	-- One entry per sound. volume: 0..1 on the effects bus. pitchJitter: +/- fraction, 0 for a fixed pitch.
	-- cooldown: real seconds before the same cue may play again. maxSpeed: not played above this sim speed (x16 would
	-- turn every tool call into a buzz). needsGlitch: only plays when the glitch VFX accepted its trigger, so the AI-error
	-- sound and the flicker (config/vfx.luau glitch) can never come apart.
	cues = {
		mine = { file = "audio/sfx_mine.ogg", volume = 0.45, pitchJitter = 0.06, cooldown = 0.35, maxSpeed = 4 },
		sell = { file = "audio/sfx_sell.ogg", volume = 0.7, pitchJitter = 0.03, cooldown = 0.25, maxSpeed = 4 },
		scan = { file = "audio/sfx_scan.ogg", volume = 0.6, pitchJitter = 0, cooldown = 0.5, maxSpeed = 4 },
		click = { file = "audio/sfx_click.ogg", volume = 0.4, pitchJitter = 0.03, cooldown = 0.04 },
		confirm = { file = "audio/sfx_confirm.ogg", volume = 0.5, pitchJitter = 0.04, cooldown = 0.15, maxSpeed = 4 },
		error = { file = "audio/sfx_error.ogg", volume = 0.85, pitchJitter = 0, cooldown = 0.4, needsGlitch = true },
		purchase = { file = "audio/sfx_purchase.ogg", volume = 0.75, pitchJitter = 0, cooldown = 0.2 },
		mission = { file = "audio/sfx_mission.ogg", volume = 0.8, pitchJitter = 0, cooldown = 1.0 },
		tier_up = { file = "audio/sfx_tier_up.ogg", volume = 0.9, pitchJitter = 0, cooldown = 2.0 },
		alert = { file = "audio/sfx_alert.ogg", volume = 0.7, pitchJitter = 0, cooldown = 1.0 },
		raid = { file = "audio/sfx_raid.ogg", volume = 0.8, pitchJitter = 0.05, cooldown = 0.3, maxSpeed = 4 },
	},

	-- A finished tool call (a feed entry going "ok") plays its tool's cue; any other tool plays `toolDefault`.
	tools = { mine = "mine", sell = "sell", scan = "scan", scan_route = "scan", intercept = "raid", attack = "raid" },
	toolDefault = "confirm",
	ignoredTools = { wait = true, report = true, ["return"] = true }, -- no sound: they happen all the time and say nothing new

	-- Sim events that play a cue. agent_paused_error is the AI-error sound (needsGlitch).
	events = {
		ui_click = "click", -- not a sim event: client/main.luau raises it for every button press (UiClicked)
		agent_paused_error = "error",
		agent_no_compute = "alert",
		alert_raised = "alert",
		retaliation = "alert",
		upgrade_bought = "purchase",
		freighter_bought = "purchase",
		hangar_bought = "purchase",
		outpost_built = "purchase",
		branch_opened = "purchase",
		skill_saved = "confirm",
		mission_complete = "mission",
		tier_up = "tier_up",
		freighter_delivered = "sell",
		raid_attack = "raid",
	},
}
