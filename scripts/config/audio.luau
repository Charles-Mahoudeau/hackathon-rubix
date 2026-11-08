-- Audio (GR5-23, GR5-99): which sound plays for what, and how loud. Numbers and file names only; the sounds themselves are
-- synthesised by tools/build_audio.py (original work, CC0, no third-party pack). No logic lives here.
-- Source of truth: the final GRIDMIND cue sheet (GR5-98 `cue-sheet-final.md`).
return {
	-- Bus volumes handed to engine.settings.audio.volume (project.luau, keep in step). music = the ambient loop's gain.
	volume = { master = 0.8, music = 0.22, effects = 1.0 },
	-- Hard limits so a busy sim never turns into noise: at most this many new SFX a frame, highest priority first.
	maxPlaysPerFrame = 3,
	pitchSeed = 23023, -- LCG seed of the small pitch variation (client side only, never the sim's RNG)
	-- Agent tool sounds (cues with `agent = true`) drop out above this sim speed; player actions and alerts never do.
	agentMaxSpeed = 4,

	-- Priority classes, lowest number wins when more than maxPlaysPerFrame cues compete in one frame.
	priority = { emergency = 1, error = 2, unlock = 3, transaction = 4, agent = 5, ui = 6 },

	-- Music ducking: a cue with `duckDb` pulls the music bus down by that many dB while it plays. Overlaps take the
	-- strongest duck, never the sum. The release starts when the last ducking cue has ended.
	duck = { attack = 0.05, release = 0.8 },

	-- The ambient loop. One file for every tier (the sheet's closest owned fallback): a tier change never restarts it.
	music = {
		crossfade = 2.0, -- seconds of fade-in at start
		tiers = {
			[1] = "audio/music_ambient.ogg", [2] = "audio/music_ambient.ogg", [3] = "audio/music_ambient.ogg",
			[4] = "audio/music_ambient.ogg", [5] = "audio/music_ambient.ogg",
		},
	},

	-- One entry per sound.
	--   volume: linear gain on the effects bus. pitch: { low, high } playback rate, picked per play (equal = fixed).
	--   cooldown: real seconds before the same cue may play again. priority: a key of `priority`.
	--   agent: an agent tool sound (muted above agentMaxSpeed). needsGlitch: only plays when the glitch VFX accepted
	--   its trigger, so the AI-error sound and the flicker (config/vfx.luau glitch) can never come apart.
	--   latch: after playing, blocked until Audio.rearm (low Compute rearms when Compute recovers).
	--   duckDb / duration: music duck depth and the file's length in seconds (the duck is held that long).
	cues = {
		click = { file = "audio/sfx_click.ogg", volume = 0.35, pitch = { 0.98, 1.02 }, cooldown = 0.08, priority = "ui" },
		hover = { file = "audio/sfx_click.ogg", volume = 0.088, pitch = { 1.26, 1.26 }, cooldown = 0.25, priority = "ui" },
		denied = { file = "audio/sfx_error.ogg", volume = 0.35, pitch = { 1, 1 }, cooldown = 0.75, priority = "error" },
		buy = { file = "audio/sfx_purchase.ogg", volume = 0.50, pitch = { 0.98, 1.02 }, cooldown = 0.3, priority = "transaction" },
		claim = { file = "audio/sfx_mission.ogg", volume = 0.60, pitch = { 1, 1 }, cooldown = 1.0, priority = "unlock", duckDb = 3, duration = 1.1 },
		tier_up = { file = "audio/sfx_tier_up.ogg", volume = 0.65, pitch = { 1, 1 }, cooldown = 2.0, priority = "unlock", duckDb = 3, duration = 1.72 },
		mine = { file = "audio/sfx_mine.ogg", volume = 0.25, pitch = { 0.96, 1.04 }, cooldown = 1.5, priority = "agent", agent = true },
		refine = { file = "audio/sfx_mine.ogg", volume = 0.20, pitch = { 0.90, 0.94 }, cooldown = 2.0, priority = "agent", agent = true },
		haul = { file = "audio/sfx_sell.ogg", volume = 0.20, pitch = { 0.90, 0.94 }, cooldown = 2.0, priority = "agent", agent = true },
		raid = { file = "audio/sfx_raid.ogg", volume = 0.30, pitch = { 0.96, 1.04 }, cooldown = 1.5, priority = "agent", agent = true },
		scan = { file = "audio/sfx_scan.ogg", volume = 0.25, pitch = { 0.96, 1.04 }, cooldown = 1.5, priority = "agent", agent = true },
		low_compute = { file = "audio/sfx_alert.ogg", volume = 0.45, pitch = { 1, 1 }, cooldown = 10, priority = "error", latch = true },
		emergency = { file = "audio/sfx_alert.ogg", volume = 0.65, pitch = { 0.85, 0.85 }, cooldown = 10, priority = "emergency", duckDb = 6, duration = 0.46 },
		accepted = { file = "audio/sfx_confirm.ogg", volume = 0.20, pitch = { 0.98, 1.02 }, cooldown = 1.0, priority = "agent", agent = true },
		ai_error = { file = "audio/sfx_error.ogg", volume = 0.55, pitch = { 1, 1 }, cooldown = 1.0, priority = "error", needsGlitch = true, duckDb = 6, duration = 0.35 },
	},

	-- A finished tool call (a feed entry going "ok") plays its tool's cue; any tool not listed is silent (a validated AI
	-- decision already plays `accepted`, a skill step plays nothing).
	tools = {
		mine = "mine", dig = "mine", salvage = "mine",
		refine = "refine",
		sell = "haul", store = "haul", ship = "haul",
		scan = "scan", scan_route = "scan", survey = "scan",
		intercept = "raid", attack = "raid",
	},

	-- Sim / client events that play a cue. ui_click / ui_denied are not sim events: client/main.luau raises them for every
	-- button press and every refused purchase or claim. ui_hover is reserved: the UI plugin has no hover event yet, so
	-- nothing raises it and hover stays silent. mission_complete is deliberately absent: only the claim sounds.
	events = {
		ui_click = "click",
		ui_hover = "hover",
		ui_denied = "denied",
		upgrade_bought = "buy",
		freighter_bought = "buy",
		hangar_bought = "buy",
		outpost_built = "buy",
		branch_opened = "buy",
		mission_claimed = "claim",
		tier_up = "tier_up",
		freighter_delivered = "haul",
		raid_attack = "raid",
		refined = "refine",
		agent_no_compute = "low_compute",
		low_compute = "low_compute",
		emergency_advance_offered = "emergency",
		decision_accepted = "accepted",
		agent_paused_error = "ai_error",
	},
}
