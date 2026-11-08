-- The bridge to the engine's audio plugin (rtype.audio): loads the sounds once, plays a cue, keeps the ambient loop and
-- ducks the music bus. The system that owns the ctx (game.Shell in client/main.luau) declares
-- `calls = { "rtype.audio.playSound" }` and `events = { send = { "rtype.PlayMusic" } }`; game.AudioBus owns the volumes.
-- Which cue plays for what is client/audio.luau.
local Cfg = require("@scripts/config/audio")

local Sounds = {}

-- Replaced by the headless tests; the engine's loader otherwise.
Sounds.assets = { sound = function(path, opts) return engine.assets.sound(path, opts) end }

local ids = {}

local function load(path, stream)
	local id = ids[path]
	if id == nil then
		id = Sounds.assets.sound(path, { stream = stream })
		ids[path] = id
	end
	return id
end

-- Plays the request returned by Audio.flush.
function Sounds.play(ctx, request)
	ctx.call("rtype.audio.playSound", { sound = load(request.file, false), volume = request.volume, pitch = request.pitch })
end

-- Starts the ambient loop for a tier, or does nothing when that file already plays: tiers share one loop, so a tier
-- change keeps its position. Call every frame.
function Sounds.syncMusic(ctx, state, file)
	if state.musicFile == file then return false end
	state.musicFile = file
	ctx.events.send("rtype.PlayMusic", { sound = load(file, true), crossfade = Cfg.music.crossfade })
	return true
end

-- Bus state owned by the game.AudioBus system: what the user set (master / effects / music) and the duck applied on top.
Sounds.bus = { master = 1, effects = 1, base = nil, written = nil, duck = 1, supported = true }

-- Applies the music duck to a writable AudioVolumes view. A change the user made to the music volume (the view no longer
-- holds what we wrote) becomes the new base, so ducking never fights a volume slider or a mute. Returns false once the
-- resource turns out not to be writable (ducking is then off, everything else keeps working).
function Sounds.applyBus(volumes, duck)
	local bus = Sounds.bus
	if not bus.supported then return false end
	local ok = pcall(function()
		bus.master, bus.effects = volumes.master, volumes.effects
		local cur = volumes.music
		if bus.written == nil or math.abs(cur - bus.written) > 1e-4 then bus.base = cur end
		local want = bus.base * duck
		if math.abs(want - cur) > 1e-5 then volumes.music = want end
		bus.written, bus.duck = want, duck
	end)
	if not ok then bus.supported = false end
	return ok
end

return Sounds
