-- Station turret animation (GR5-52). Turrets are separate texture files per frame, so a client system swaps the texture of
-- every entity carrying game.StationTurret { kind, phase, aim, corp } (index into Stations.turretKinds, phase in tenths of a
-- second, outward direction in degrees, index into Stations.corpNames). The first frame of each firing loop also raises the
-- turret's muzzle flash (render/vfx/cues). Client only: required by client/main.
local Stations = require("@scripts/client/stations")
local Cues = require("@scripts/render/vfx/cues")
local config = require("@scripts/config/stations")

engine.ecs.component("game.StationTurret", { fields = { kind = "u32", phase = "u32", aim = "u32", corp = "u32" } })

local shown = {}
local lastFrame = {}

engine.ecs.system("game.StationTurrets", {
	phase = "Update",
	side = "client",
	query = { read = { "rtype.Transform" }, write = { "rtype.SpriteRenderer", "game.StationTurret" } },
	after = { "game.MapSprites" }, -- that system writes Transform; reading it here needs a fixed order
	run = function(ctx)
		local now = ctx.time.elapsed
		for entity, transform, sprite, turret in ctx.query do
			local kind = Stations.turretKinds[turret.kind]
			if kind then
				local t = now + turret.phase / 10
				local path = Stations.turretPath(kind, t)
				if shown[entity] ~= path then
					shown[entity] = path
					sprite.texture = Stations.texture(path)
				end
				local frame, last = math.floor(math.max(0, t) * config.turrets.fps), lastFrame[entity]
				lastFrame[entity] = frame
				if last and frame > last then
					-- A slow frame can skip animation frames; look at each one it jumped over (at most one loop's worth).
					for f = math.max(last + 1, frame - #Stations.turretSequence(kind) + 1), frame do
						if Stations.isFireStart(kind, f) then
							local size = config.turrets.frame * transform.scale.x
							Cues.turretFire(Cues.shared, entity, transform.position.x, transform.position.y, size, turret.aim, now, Stations.corpNames[turret.corp])
							break
						end
					end
				end
			end
		end
	end,
})
