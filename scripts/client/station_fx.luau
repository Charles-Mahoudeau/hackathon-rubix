-- Station turret animation (GR5-52). Turrets are separate texture files per frame, so a client system swaps the texture of
-- every entity carrying game.StationTurret { kind, phase } (index into Stations.turretKinds, phase in tenths of a second).
-- Client only: required by client/main.
local Stations = require("@scripts/client/stations")

engine.ecs.component("game.StationTurret", { fields = { kind = "u32", phase = "u32" } })

local shown = {}

engine.ecs.system("game.StationTurrets", {
	phase = "Update",
	side = "client",
	query = { write = { "rtype.SpriteRenderer", "game.StationTurret" } },
	after = { "game.MapSprites" },
	run = function(ctx)
		local now = ctx.time.elapsed
		for entity, sprite, turret in ctx.query do
			local kind = Stations.turretKinds[turret.kind]
			if kind then
				local path = Stations.turretPath(kind, now + turret.phase / 10)
				if shown[entity] ~= path then
					shown[entity] = path
					sprite.texture = Stations.texture(path)
				end
			end
		end
	end,
})
