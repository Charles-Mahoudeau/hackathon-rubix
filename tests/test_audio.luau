-- GR5-23 gate: events become the right sound cues, rate-limited, and the AI-error sound is tied to the glitch trigger.
-- Headless: the engine's sound loader is stubbed, so this checks the wiring, not the audio.
local Cfg = require("@scripts/config/audio")
local Audio = require("@scripts/client/audio")
local Sounds = require("@scripts/client/sounds")
local Shell = require("@scripts/ui/shell")

local function call(entry, update) return { name = "feed_event", entry = entry, update = update ~= false } end
local function tool(name, status) return call({ kind = "call", tool = name, status = status or "ok" }) end

local s = Audio.new()
Audio.beginFrame(s, 0)
local ok = { speed = 1 }

-- tool calls: only a finished (ok) call plays, each tool its own cue
assert(Audio.onEvent(s, tool("mine"), ok).cue == "mine")
assert(Audio.onEvent(s, tool("sell"), ok).cue == "sell")
assert(Audio.onEvent(s, tool("scan"), ok).cue == "scan")
Audio.beginFrame(s, 10)
assert(Audio.onEvent(s, tool("store"), ok).cue == "confirm", "unlisted tool falls back to toolDefault")
Audio.beginFrame(s, 20)
assert(Audio.onEvent(s, tool("mine", "failed"), ok) == nil, "a failed call is the error path, not a confirmation")
assert(Audio.onEvent(s, tool("wait"), ok) == nil and Audio.onEvent(s, tool("report"), ok) == nil, "chatty tools are silent")
assert(Audio.onEvent(s, call({ kind = "call", tool = "mine", status = "ok" }, false), ok) == nil, "a call that has only started is silent")
assert(Audio.onEvent(s, { name = "speed_changed", speed = 4 }, ok) == nil, "an unmapped event is silent")

-- the per-frame cap and the per-cue cooldown
local capped = Audio.new()
Audio.beginFrame(capped, 100)
local played = 0
for _, name in { "mine", "sell", "scan", "store" } do
	if Audio.onEvent(capped, tool(name), ok) then played += 1 end
end
assert(played == Cfg.maxPlaysPerFrame, "no more than maxPlaysPerFrame sounds in one frame")
Audio.beginFrame(capped, 100 + Cfg.cues.sell.cooldown / 2)
assert(Audio.onEvent(capped, tool("sell"), ok) == nil, "same cue inside its cooldown is dropped")
Audio.beginFrame(capped, 100 + Cfg.cues.sell.cooldown + 0.01)
assert(Audio.onEvent(capped, tool("sell"), ok), "and plays again after it")

-- fast-forward: tool cues drop out above their maxSpeed, milestone cues stay
local fast = Audio.new()
Audio.beginFrame(fast, 0)
assert(Audio.onEvent(fast, tool("mine"), { speed = 16 }) == nil, "no mining ticks at x16")
assert(Audio.onEvent(fast, { name = "mission_complete", id = "m1" }, { speed = 16 }).cue == "mission")
assert(Audio.onEvent(fast, { name = "tier_up", tier = 2 }, { speed = 16 }).cue == "tier_up")

-- purchases, missions, alerts
local m = Audio.new()
Audio.beginFrame(m, 0)
assert(Audio.onEvent(m, { name = "upgrade_bought", id = "x" }, ok).cue == "purchase")
assert(Audio.onEvent(m, { name = "alert_raised" }, ok).cue == "alert")
assert(Audio.onEvent(m, { name = "agent_added", agent = "a" }, ok) == nil, "agent_added rides on a purchase that already sounds")

-- AI error: plays only when the glitch accepted the same event
local e = Audio.new()
Audio.beginFrame(e, 0)
local event = { name = "agent_paused_error", agent = "miner_1" }
assert(Audio.onEvent(e, event, { speed = 1, glitch = false }) == nil, "no error sound without the glitch")
local shell = Shell.new()
local glitched = Shell.onSimEvent(shell, event)
assert(glitched == true, "the shell glitches on agent_paused_error")
local play = Audio.onEvent(e, event, { speed = 1, glitch = glitched })
assert(play and play.cue == "error", "the error sound follows the glitch trigger")
Audio.beginFrame(e, 5)
assert(Audio.onEvent(e, event, { speed = 16, glitch = true }), "the error sound is audible at any speed, like the glitch")

-- pitch variation is deterministic and inside its band
local a, b = Audio.new(), Audio.new()
Audio.beginFrame(a, 0)
Audio.beginFrame(b, 0)
local pa, pb = Audio.onEvent(a, tool("mine"), ok), Audio.onEvent(b, tool("mine"), ok)
assert(pa.pitch == pb.pitch, "same seed, same pitch")
assert(math.abs(pa.pitch - 1) <= Cfg.cues.mine.pitchJitter + 1e-9)
assert(Audio.onEvent(a, { name = "mission_complete" }, ok).pitch == 1, "fixed-pitch cues are not varied")

-- config: every route points at a defined cue, every cue at a file
for event_name, cue in pairs(Cfg.events) do assert(Cfg.cues[cue], event_name .. " -> unknown cue " .. cue) end
for tool_name, cue in pairs(Cfg.tools) do assert(Cfg.cues[cue], tool_name .. " -> unknown cue " .. cue) end
assert(Cfg.cues[Cfg.toolDefault])
for name, cue in pairs(Cfg.cues) do assert(cue.file and cue.volume > 0 and cue.volume <= 1 and cue.cooldown >= 0, name) end
-- the sounds the spec lists each have a cue
for _, name in { "mine", "sell", "scan", "error", "purchase", "mission", "alert" } do assert(Cfg.cues[name], "missing cue " .. name) end

-- the engine bridge asks for each file once, streams only the music
local loaded, sent, called = {}, {}, {}
Sounds.assets = { sound = function(path, opts) loaded[#loaded + 1] = { path = path, stream = opts.stream }; return "snd:" .. path end }
local ctx = {
	call = function(name, args) called[#called + 1] = { name = name, args = args } end,
	events = { send = function(name, args) sent[#sent + 1] = { name = name, args = args } end },
}
Sounds.startMusic(ctx)
assert(#sent == 1 and sent[1].name == "rtype.PlayMusic" and sent[1].args.sound == "snd:" .. Cfg.music.file)
assert(loaded[1].stream == true, "the music is streamed")
Sounds.play(ctx, play)
Sounds.play(ctx, play)
assert(#called == 2 and called[1].name == "rtype.audio.playSound" and called[1].args.sound == "snd:" .. Cfg.cues.error.file)
assert(#loaded == 2 and loaded[2].stream == false, "an effect is loaded once, not streamed")

print("audio tests passed")
