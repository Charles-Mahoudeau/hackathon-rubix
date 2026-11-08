-- GR5-23 / GR5-99 gate: events become the cues of the final cue sheet, with its gains, pitch, cooldowns, priority, ducking,
-- mute and fast-forward rules; the AI-error sound is tied to the glitch trigger. Headless: the engine's sound loader and
-- the AudioVolumes resource are stubbed, so this checks the wiring, not the audio.
local Cfg = require("@scripts/config/audio")
local Audio = require("@scripts/client/audio")
local Sounds = require("@scripts/client/sounds")
local Shell = require("@scripts/ui/shell")
local Sim = require("@scripts/sim/sim")

-- sim events reach the client as { tick, name, data }; feed entries live in data
local function call(entry, update) return { name = "feed_event", data = { entry = entry, update = update ~= false } } end
local function tool(name, status) return call({ kind = "call", tool = name, status = status or "ok" }) end
local ok1 = { speed = 1 }

-- one event in a fresh frame at time `t`: returns the plays
local function play(s, t, event, ctx)
	Audio.beginFrame(s, t)
	Audio.onEvent(s, event, ctx or ok1)
	return Audio.flush(s)
end
local function names(plays) local o = {} for _, p in ipairs(plays) do o[#o + 1] = p.cue end return table.concat(o, ",") end

-- ---- the mapping: every event of the sheet gets its row's file, gain and pitch band -------------------------------------
local sheet = {
	{ { name = "ui_click" }, "click", "audio/sfx_click.ogg", 0.35, 0.98, 1.02 },
	{ { name = "ui_hover" }, "hover", "audio/sfx_click.ogg", 0.088, 1.26, 1.26 },
	{ { name = "ui_denied" }, "denied", "audio/sfx_error.ogg", 0.35, 1, 1 },
	{ { name = "upgrade_bought" }, "buy", "audio/sfx_purchase.ogg", 0.50, 0.98, 1.02 },
	{ { name = "mission_claimed" }, "claim", "audio/sfx_mission.ogg", 0.60, 1, 1 },
	{ { name = "tier_up" }, "tier_up", "audio/sfx_tier_up.ogg", 0.65, 1, 1 },
	{ tool("mine"), "mine", "audio/sfx_mine.ogg", 0.25, 0.96, 1.04 },
	{ tool("refine"), "refine", "audio/sfx_mine.ogg", 0.20, 0.90, 0.94 },
	{ tool("ship"), "haul", "audio/sfx_sell.ogg", 0.20, 0.90, 0.94 },
	{ tool("intercept"), "raid", "audio/sfx_raid.ogg", 0.30, 0.96, 1.04 },
	{ tool("scan"), "scan", "audio/sfx_scan.ogg", 0.25, 0.96, 1.04 },
	{ { name = "agent_no_compute" }, "low_compute", "audio/sfx_alert.ogg", 0.45, 1, 1 },
	{ { name = "emergency_advance_offered" }, "emergency", "audio/sfx_alert.ogg", 0.65, 0.85, 0.85 },
	{ { name = "decision_accepted" }, "accepted", "audio/sfx_confirm.ogg", 0.20, 0.98, 1.02 },
}
for _, row in ipairs(sheet) do
	local event, cue, file, gain, lo, hi = table.unpack(row)
	local out = play(Audio.new(), 0, event)
	assert(#out == 1 and out[1].cue == cue, cue .. ": got " .. names(out))
	assert(out[1].file == file and math.abs(out[1].volume - gain) < 1e-9, cue .. " file/gain")
	assert(out[1].pitch >= lo - 1e-9 and out[1].pitch <= hi + 1e-9, cue .. " pitch " .. out[1].pitch)
end
assert(#play(Audio.new(), 0, { name = "ai_probe" }) == 0, "an unmapped event is silent")
assert(#play(Audio.new(), 0, { name = "speed_changed", data = { speed = 4 } }) == 0)
assert(#play(Audio.new(), 0, tool("store")) == 1 and #play(Audio.new(), 0, tool("wait")) == 0 and #play(Audio.new(), 0, tool("report")) == 0, "wait and report are silent")
assert(#play(Audio.new(), 0, tool("mine", "failed")) == 0, "a failed call is the error path, not an agent sound")
assert(#play(Audio.new(), 0, call({ kind = "call", tool = "mine", status = "ok" }, false)) == 0, "a call that has only started is silent")
assert(#play(Audio.new(), 0, tool("some_new_tool")) == 0, "an unlisted tool is silent: decision_accepted covers it")
assert(#play(Audio.new(), 0, { name = "skill_saved" }) == 0 and #play(Audio.new(), 0, { name = "alert_raised" }) == 0, "not in the sheet: silent")

-- claim and completion are distinct: only the claim sounds
assert(#play(Audio.new(), 0, { name = "mission_complete", data = { id = 1 } }) == 0, "completing a mission is silent")
assert(names(play(Audio.new(), 0, { name = "mission_claimed", data = { id = 1 } })) == "claim")

-- the sim emits the events the sheet needs, in the shape the client reads
local sim = Sim.new()
sim:enterTier(2)
local sawTier = false
for _, e in ipairs(sim:drainEvents()) do
	if e.name == "tier_up" then sawTier = true; assert(#play(Audio.new(), 0, e) == 1) end
end
assert(sawTier)
-- a validated AI decision (the stub here) emits decision_accepted, and its feed line a finished tool call
local Ai = require("@scripts/sim/ai")
local run = Sim.new()
run:setDecider(Ai.decide)
local accepted, finished = 0, 0
for _ = 1, 1500 do
	run:step()
	for _, e in ipairs(run:drainEvents()) do
		if e.name == "decision_accepted" then accepted += 1 end
		if e.name == "feed_event" and e.data.update and e.data.entry.status == "ok" and #play(Audio.new(), 0, e) == 1 then finished += 1 end
	end
end
assert(accepted > 0, "the sim announces validated AI decisions")
assert(finished > 0, "a finished tool call, as the real sim emits it, reaches a cue")

-- ---- cooldowns ----------------------------------------------------------------------------------------------------
local s = Audio.new()
assert(#play(s, 0, { name = "ui_click" }) == 1)
assert(#play(s, 0.05, { name = "ui_click" }) == 0, "click inside 80 ms is dropped")
assert(#play(s, 0.09, { name = "ui_click" }) == 1, "and plays after it")
assert(#play(s, 1, tool("mine")) == 1 and #play(s, 2, tool("mine")) == 0 and #play(s, 2.6, tool("mine")) == 1, "mining: 1.5 s")
assert(#play(s, 1, tool("refine")) == 1 and #play(s, 2.9, tool("refine")) == 0 and #play(s, 3.1, tool("refine")) == 1, "refining: 2 s")
assert(#play(s, 5, { name = "tier_up" }) == 1 and #play(s, 6.9, { name = "tier_up" }) == 0 and #play(s, 7.1, { name = "tier_up" }) == 1, "tier: 2 s")
assert(#play(s, 10, { name = "mission_claimed" }) == 1 and #play(s, 10.9, { name = "mission_claimed" }) == 0 and #play(s, 11.1, { name = "mission_claimed" }) == 1)
assert(#play(s, 20, { name = "ui_denied" }) == 1 and #play(s, 20.7, { name = "ui_denied" }) == 0 and #play(s, 20.8, { name = "ui_denied" }) == 1)
assert(#play(s, 30, { name = "emergency_advance_offered" }) == 1 and #play(s, 39, { name = "emergency_advance_offered" }) == 0 and #play(s, 40.1, { name = "emergency_advance_offered" }) == 1)
-- the same cue twice in one frame plays once
Audio.beginFrame(s, 100)
Audio.onEvent(s, tool("scan"), ok1)
Audio.onEvent(s, tool("scan_route"), ok1)
assert(#Audio.flush(s) == 1, "two scans in one frame play one sound")
-- a cue the cap or the cooldown dropped does not spend the cooldown of the others
local rolling = Audio.new()
for i = 0, 40 do
	local plays = play(rolling, i * 0.1, tool("mine"))
	assert(#plays <= 1)
end

-- ---- priority and the per-frame cap -------------------------------------------------------------------------------
local p = Audio.new()
Audio.beginFrame(p, 0)
for _, e in ipairs({ { name = "ui_click" }, tool("mine"), { name = "upgrade_bought" }, { name = "mission_claimed" }, { name = "emergency_advance_offered" }, tool("scan"), { name = "agent_paused_error" }, { name = "tier_up" } }) do
	Audio.onEvent(p, e, { speed = 1, glitch = true })
end
local out = Audio.flush(p)
assert(#out == Cfg.maxPlaysPerFrame and names(out) == "emergency,ai_error,claim", "emergency > error > unlock/claim: " .. names(out))
Audio.beginFrame(p, 5)
for _, e in ipairs({ { name = "ui_click" }, tool("mine"), tool("scan"), { name = "upgrade_bought" }, tool("refine") }) do Audio.onEvent(p, e, ok1) end
assert(names(Audio.flush(p)) == "buy,mine,scan", "transaction > agent > UI, then arrival order: " .. names(Audio.flush(p)))
-- dropped by the cap, not by a cooldown: it plays next frame
Audio.beginFrame(p, 6)
Audio.onEvent(p, { name = "ui_click" }, ok1)
assert(names(Audio.flush(p)) == "click", "a cue the cap dropped is free to play later")
-- a burst of 200 events in one frame stays bounded
local burst = Audio.new()
Audio.beginFrame(burst, 0)
for i = 1, 200 do Audio.onEvent(burst, i % 2 == 0 and tool("mine") or { name = "freighter_delivered" }, ok1) end
assert(#Audio.flush(burst) <= Cfg.maxPlaysPerFrame)

-- ---- fast-forward: agent tool sounds drop out above 4x, player actions and alerts stay -------------------------------
local fast = Audio.new()
local x16 = { speed = 16 }
assert(#play(fast, 0, tool("mine"), { speed = 4 }) == 1, "x4 still plays")
assert(#play(fast, 10, tool("mine"), x16) == 0 and #play(fast, 10, tool("scan"), x16) == 0 and #play(fast, 10, { name = "decision_accepted" }, x16) == 0, "no agent sounds at x16")
assert(#play(fast, 10, { name = "mission_claimed" }, x16) == 1 and #play(fast, 10, { name = "tier_up" }, x16) == 1, "milestones stay")
assert(#play(fast, 10, { name = "emergency_advance_offered" }, x16) == 1 and #play(fast, 10, { name = "ui_click" }, x16) == 1, "alerts and clicks stay")

-- ---- mute and the user's volumes ----------------------------------------------------------------------------------
local m = Audio.new()
Audio.setMuted(m, true)
assert(#play(m, 0, { name = "ui_click" }) == 0 and #play(m, 0, { name = "agent_paused_error" }, { speed = 1, glitch = true }) == 0, "muted: nothing plays")
Audio.setMuted(m, false)
assert(#play(m, 0, { name = "ui_click" }) == 1, "and unmuting does not eat the cooldown")
Audio.beginFrame(m, 5)
Audio.onEvent(m, { name = "ui_click" }, ok1)
assert(#Audio.flush(m, { master = 0, effects = 1 }) == 0 and #(function() Audio.onEvent(m, { name = "ui_click" }, ok1) return Audio.flush(m, { master = 0.8, effects = 0 }) end)() == 0, "a bus at 0 is a mute")
Audio.onEvent(m, { name = "ui_click" }, ok1)
assert(#Audio.flush(m, { master = 0.8, effects = 1 }) == 1, "volume above 0 plays; the engine applies the level itself")

-- ---- AI error: plays only when the glitch accepted the same event ---------------------------------------------------
local e = Audio.new()
local event = { name = "agent_paused_error", data = { agent = "miner_1" } }
assert(#play(e, 0, event, { speed = 1, glitch = false }) == 0, "no error sound without the glitch")
local shell = Shell.new()
local glitched = Shell.onSimEvent(shell, event)
assert(glitched == true, "the shell glitches on agent_paused_error")
local err = play(e, 5, event, { speed = 1, glitch = glitched })
assert(#err == 1 and err[1].cue == "ai_error", "the error sound follows the glitch trigger")
assert(#play(e, 10, event, { speed = 16, glitch = true }) == 1, "the error sound is audible at any speed, like the glitch")

-- ---- low Compute: once on entry, rearmed by recovery ---------------------------------------------------------------
local lc = Audio.new()
Audio.beginFrame(lc, 0)
Audio.setCondition(lc, "low_compute", true)
assert(names(Audio.flush(lc)) == "low_compute", "warning entry plays")
Audio.beginFrame(lc, 20)
Audio.onEvent(lc, { name = "agent_no_compute" }, ok1)
Audio.setCondition(lc, "low_compute", true)
assert(#Audio.flush(lc) == 0, "still low: latched, even past the cooldown")
Audio.beginFrame(lc, 30)
Audio.setCondition(lc, "low_compute", false)
assert(#Audio.flush(lc) == 0)
Audio.beginFrame(lc, 31)
Audio.setCondition(lc, "low_compute", true)
assert(names(Audio.flush(lc)) == "low_compute", "after recovery the next warning plays again")
Audio.beginFrame(lc, 32)
Audio.setCondition(lc, "low_compute", false)
Audio.flush(lc)
Audio.beginFrame(lc, 33)
Audio.setCondition(lc, "low_compute", true)
assert(#Audio.flush(lc) == 0, "but never faster than the 10 s cooldown")

-- ---- ducking ---------------------------------------------------------------------------------------------------------
local function db(gain) return -20 * math.log10(gain) end
local d = Audio.new()
play(d, 0, { name = "agent_paused_error" }, { speed = 1, glitch = true })
local level = 1
for _ = 1, 4 do level = Audio.duck(d, 0.0125) end -- 50 ms attack
assert(math.abs(db(level) - 6) < 0.05, "AI error ducks 6 dB within the 50 ms attack: " .. db(level))
d.now = 0.2
assert(Audio.duck(d, 0.1) < 0.51, "held while the cue plays (0.35 s)")
d.now = 0.5
local released = Audio.duck(d, 0.4)
assert(released > 0.5 and released < 1, "release is gradual: " .. released)
assert(Audio.duck(d, 0.5) == 1, "fully released 800 ms after the cue ended")
-- overlap takes the strongest, never the sum
local o = Audio.new()
Audio.beginFrame(o, 0)
Audio.onEvent(o, { name = "agent_paused_error" }, { speed = 1, glitch = true })
Audio.onEvent(o, { name = "mission_claimed" }, ok1)
Audio.onEvent(o, { name = "tier_up" }, ok1)
Audio.flush(o)
local deep = 1
for _ = 1, 10 do deep = Audio.duck(o, 0.02) end
assert(math.abs(db(deep) - 6) < 0.05, "overlapping ducks do not add: " .. db(deep))
-- 3 dB for unlock and claim; other cues do not duck
local u = Audio.new()
play(u, 0, { name = "tier_up" })
local ul = 1
for _ = 1, 10 do ul = Audio.duck(u, 0.02) end
assert(math.abs(db(ul) - 3) < 0.05, "unlock ducks 3 dB: " .. db(ul))
local quiet = Audio.new()
play(quiet, 0, { name = "upgrade_bought" })
play(quiet, 0, tool("mine"))
play(quiet, 0, { name = "ui_click" })
assert(Audio.duck(quiet, 1) == 1, "other cues do not duck")
-- the emergency duck is held for the pitched-down file
local em = Audio.new()
play(em, 0, { name = "emergency_advance_offered" })
em.now = 0.5
local still = 1
for _ = 1, 5 do still = Audio.duck(em, 0.02) end
assert(still < 0.51, "0.46 s file at 0.85 pitch lasts 0.54 s")

-- ---- the bus: the duck rides on the user's music volume, never fights it --------------------------------------------------
Sounds.bus = { master = 1, effects = 1, supported = true }
local vol = { master = 0.8, music = 0.22, effects = 1 }
assert(Sounds.applyBus(vol, 1) and vol.music == 0.22)
Sounds.applyBus(vol, 0.5)
assert(math.abs(vol.music - 0.11) < 1e-9, "duck multiplies the base")
vol.music = 0.4 -- the user moves the music slider during a duck
Sounds.applyBus(vol, 0.5)
assert(math.abs(vol.music - 0.2) < 1e-9 and Sounds.bus.base == 0.4, "the new volume becomes the base")
Sounds.applyBus(vol, 1)
assert(math.abs(vol.music - 0.4) < 1e-9, "released duck restores the user's volume")
vol.music = 0 -- user mutes music
Sounds.applyBus(vol, 0.5)
assert(vol.music == 0, "a muted music bus stays muted")
Sounds.bus = { master = 1, effects = 1, supported = true }
assert(Sounds.applyBus(setmetatable({}, { __newindex = function() error("read-only resource") end, __index = function() return 0.2 end }), 0.5) == false and Sounds.bus.supported == false, "an unwritable resource turns the duck off without error")

-- ---- ambient: one loop for T1..T5, a tier change never restarts it ------------------------------------------------------------
assert(Cfg.volume.music == 0.22, "ambient bus gain 0.22")
for tier = 1, 5 do assert(Audio.musicFor(tier) == "audio/music_ambient.ogg", "tier " .. tier) end
local loaded, sent, called = {}, {}, {}
Sounds.assets = { sound = function(path, opts) loaded[#loaded + 1] = { path = path, stream = opts.stream }; return "snd:" .. path end }
local ctx = {
	call = function(name, args) called[#called + 1] = { name = name, args = args } end,
	events = { send = function(name, args) sent[#sent + 1] = { name = name, args = args } end },
}
local music = {}
for tier = 1, 5 do
	Sounds.syncMusic(ctx, music, Audio.musicFor(tier))
	Sounds.syncMusic(ctx, music, Audio.musicFor(tier))
end
assert(#sent == 1 and sent[1].name == "rtype.PlayMusic" and sent[1].args.sound == "snd:audio/music_ambient.ogg", "T1..T5 start the loop once")
assert(loaded[1].stream == true, "the music is streamed")

-- ---- config: every route points at a defined cue, every cue at a file ------------------------------------------------------------
for event_name, cue in pairs(Cfg.events) do assert(Cfg.cues[cue], event_name .. " -> unknown cue " .. cue) end
for tool_name, cue in pairs(Cfg.tools) do assert(Cfg.cues[cue], tool_name .. " -> unknown cue " .. cue) end
for name, cue in pairs(Cfg.cues) do
	assert(cue.file and cue.volume > 0 and cue.volume <= 1 and cue.cooldown >= 0 and Cfg.priority[cue.priority], name)
	assert(cue.pitch[1] > 0 and cue.pitch[1] <= cue.pitch[2], name .. " pitch")
	assert(not cue.duckDb or cue.duration, name .. " ducks without a duration")
end
-- (asset resolution: tools/check_audio.sh checks every file named in config/audio.luau exists and is non-empty)

-- ---- the engine bridge asks for each file once, streams only the music --------------------------------------------------------------
local request = { file = Cfg.cues.ai_error.file, volume = 0.55, pitch = 1 }
Sounds.play(ctx, request)
Sounds.play(ctx, request)
assert(#called == 2 and called[1].name == "rtype.audio.playSound" and called[1].args.sound == "snd:" .. Cfg.cues.ai_error.file)
assert(called[1].args.pitch == 1 and called[1].args.volume == 0.55, "pitch and gain reach the engine call")
assert(#loaded == 2 and loaded[2].stream == false, "an effect is loaded once, not streamed")

print("audio tests passed")
