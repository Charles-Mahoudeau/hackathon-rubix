-- Audio cues (GR5-23): turns sim events into "play this cue" requests. Pure Luau, no engine calls, so it runs in the
-- headless tests; client/sounds.luau is the only file that talks to the audio plugin. The sim never calls this: it only
-- emits events, the client reads them.
local Cfg = require("@scripts/config/audio")

local Audio = {}

function Audio.new()
	return { rng = Cfg.pitchSeed, lastPlayed = {}, framePlays = 0, now = 0 }
end

-- Call once per frame before the frame's events.
function Audio.beginFrame(state, now)
	state.now, state.framePlays = now, 0
end

local function nextRand(state): number
	state.rng = (state.rng * 1664525 + 1013904223) % 4294967296
	return state.rng / 4294967296
end

local function cueFor(event)
	local name = Cfg.events[event.name]
	if name then return name end
	if event.name == "feed_event" and event.update and event.entry and event.entry.kind == "call" and event.entry.status == "ok" then
		local tool = event.entry.tool
		if Cfg.ignoredTools[tool] then return nil end
		return Cfg.tools[tool] or Cfg.toolDefault
	end
	return nil
end

-- ctx = { speed = sim speed, glitch = true when the glitch VFX accepted this event }.
-- Returns { cue, file, volume, pitch } or nil when nothing plays.
function Audio.onEvent(state, event, ctx)
	local name = cueFor(event)
	local cue = name and Cfg.cues[name]
	if not cue then return nil end
	if cue.needsGlitch and not ctx.glitch then return nil end
	if cue.maxSpeed and (ctx.speed or 1) > cue.maxSpeed then return nil end
	if state.framePlays >= Cfg.maxPlaysPerFrame then return nil end
	local last = state.lastPlayed[name]
	if last and state.now - last < cue.cooldown then return nil end
	state.lastPlayed[name] = state.now
	state.framePlays += 1
	local pitch = 1
	if cue.pitchJitter > 0 then pitch = 1 + (nextRand(state) * 2 - 1) * cue.pitchJitter end
	return { cue = name, file = cue.file, volume = cue.volume, pitch = pitch }
end

return Audio
