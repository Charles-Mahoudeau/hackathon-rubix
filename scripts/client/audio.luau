-- Audio cues (GR5-23, GR5-99): turns sim events into "play this cue" requests. Pure Luau, no engine calls, so it runs in the
-- headless tests; client/sounds.luau is the only file that talks to the audio plugin. The sim never calls this: it only
-- emits events, the client reads them.
-- Per frame: beginFrame, onEvent for each event (queues), then flush (cooldowns, priority, per-frame cap) -> requests.
local Cfg = require("@scripts/config/audio")

local Audio = {}

function Audio.new()
	return { rng = Cfg.pitchSeed, lastPlayed = {}, latched = {}, pending = {}, seq = 0, now = 0, muted = false, duckEnds = {}, duckLevel = 1, conditions = {} }
end

-- True the first time the client sees `sim` (a boot with its offline catch-up, a load, a reset): the events it carries then are
-- history, not news, so the caller must not turn them into cues.
function Audio.firstSight(state, sim): boolean
	if state.seen == sim then return false end
	state.seen = sim
	return true
end

function Audio.beginFrame(state, now)
	state.now = now
	state.pending = {}
end

-- User mute (the engine's own bus volumes at 0 count as mute too, see Audio.flush's `volumes`).
function Audio.setMuted(state, muted) state.muted = muted == true end

local function nextRand(state): number
	state.rng = (state.rng * 1664525 + 1013904223) % 4294967296
	return state.rng / 4294967296
end

local function cueFor(event)
	local name = Cfg.events[event.name]
	if name then return name end
	local d = event.data or event
	if event.name == "feed_event" and d.update and d.entry and d.entry.kind == "call" and d.entry.status == "ok" then
		return Cfg.tools[d.entry.tool]
	end
	return nil
end

-- ctx = { speed = sim speed, glitch = true when the glitch VFX accepted this event }. Returns the cue name queued, or nil.
function Audio.onEvent(state, event, ctx)
	local name = cueFor(event)
	local cue = name and Cfg.cues[name]
	if not cue then return nil end
	if cue.needsGlitch and not ctx.glitch then return nil end
	if cue.agent and (ctx.speed or 1) > Cfg.agentMaxSpeed then return nil end
	state.seq += 1
	state.pending[#state.pending + 1] = { name = name, cue = cue, seq = state.seq, rank = Cfg.priority[cue.priority] }
	return name
end

-- A cue that latched (low Compute) may play again.
function Audio.rearm(state, name) state.latched[name] = nil end

-- A named boolean condition (e.g. "low_compute"): entering it queues the event of the same name once, leaving it
-- rearms the cue.
function Audio.setCondition(state, name, on, ctx)
	local was = state.conditions[name] == true
	state.conditions[name] = on == true
	if on and not was then Audio.onEvent(state, { name = name }, ctx or { speed = 1 })
	elseif was and not on then Audio.rearm(state, Cfg.events[name] or name) end
end

local function dbGain(db) return 10 ^ (-db / 20) end

-- Resolves this frame's queue: strongest priority first, each cue through its cooldown and latch, at most
-- maxPlaysPerFrame plays. `volumes` ({ master, effects } from the engine's AudioVolumes) at 0 mutes everything without
-- spending cooldowns. Returns a list of { cue, file, volume, pitch }.
function Audio.flush(state, volumes)
	local out, queue = {}, state.pending
	state.pending = {}
	if state.muted or (volumes and ((volumes.master or 1) <= 0 or (volumes.effects or 1) <= 0)) then return out end
	table.sort(queue, function(a, b)
		if a.rank ~= b.rank then return a.rank < b.rank end
		return a.seq < b.seq
	end)
	for _, q in ipairs(queue) do
		if #out >= Cfg.maxPlaysPerFrame then break end
		local cue = q.cue
		local last = state.lastPlayed[q.name]
		if not (last and state.now - last < cue.cooldown) and not state.latched[q.name] then
			state.lastPlayed[q.name] = state.now
			if cue.latch then state.latched[q.name] = true end
			local lo, hi = cue.pitch[1], cue.pitch[2]
			local pitch = lo == hi and lo or lo + nextRand(state) * (hi - lo)
			out[#out + 1] = { cue = q.name, file = cue.file, volume = cue.volume, pitch = pitch }
			if cue.duckDb then
				-- the duck is held while the file plays (longer at a lower pitch), then released
				local ends = state.now + (cue.duration or 0) / pitch
				state.duckEnds[#state.duckEnds + 1] = { gain = dbGain(cue.duckDb), ends = ends }
			end
		end
	end
	return out
end

-- Music-bus multiplier (1 = no duck) after `dt` seconds. Attack and release are linear; overlapping ducks take the
-- deepest one.
function Audio.duck(state, dt)
	local target, live = 1, {}
	for _, d in ipairs(state.duckEnds) do
		if d.ends > state.now then
			live[#live + 1] = d
			if d.gain < target then target = d.gain end
		end
	end
	state.duckEnds = live
	local level = state.duckLevel
	if target < level then
		state.duckDepth = math.max(state.duckDepth or 0, 1 - target)
		level = math.max(target, level - dt / Cfg.duck.attack * (1 - target))
	elseif target > level then
		level = math.min(target, level + dt / Cfg.duck.release * (state.duckDepth or 1))
	end
	if level >= 1 then state.duckDepth = 0 end
	state.duckLevel = level
	return level
end

-- The ambient file for a tier (all tiers share one loop, so a tier change keeps it playing).
function Audio.musicFor(tier)
	local t = math.max(1, math.min(#Cfg.music.tiers, tier or 1))
	return Cfg.music.tiers[t]
end

return Audio
