-- The bridge to the engine's audio plugin (rtype.audio): loads the sounds once, plays a cue, starts the music. The
-- system that owns the ctx (game.Shell in client/main.luau) declares `calls = { "rtype.audio.playSound" }` and
-- `events = { send = { "rtype.PlayMusic" } }`. Which cue plays for what is client/audio.luau.
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

-- Plays the request returned by Audio.onEvent.
function Sounds.play(ctx, request)
	ctx.call("rtype.audio.playSound", { sound = load(request.file, false), volume = request.volume, pitch = request.pitch })
end

-- Fades the ambient loop in. Call once, on the first frame.
function Sounds.startMusic(ctx)
	ctx.events.send("rtype.PlayMusic", { sound = load(Cfg.music.file, true), crossfade = Cfg.music.crossfade })
end

return Sounds
