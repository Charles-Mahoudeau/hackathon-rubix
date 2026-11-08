-- Station turrets (GR5-52, GR5-104). Turrets are separate texture files per frame, so a client system swaps the texture of every
-- entity carrying game.StationTurret { kind, site } (kind: index into Stations.turretKinds, site: 1-based index of its station in
-- SystemMap.stations, 0 = none). A turret stays parked on its first idle frame; only while the fleet map reports a real raid
-- fight in range of its station (`fleet.turrets[site]`, handed over by StationFx.bind, from FleetMap.update) does it aim at it and play the opening
-- and the fire loop. The clock is the map's animation clock, so a paused game freezes the turret as it is. Client only.
local Stations = require("@scripts/client/stations")

engine.ecs.component("game.StationTurret", { fields = { kind = "u32", site = "u32" } })

local StationFx = {}
-- The engine freezes module tables, so the fleet lives in a local behind a setter.
local source
function StationFx.bind(fleet) source = fleet end

local shown = {}

engine.ecs.system("game.StationTurrets", {
	phase = "Update",
	side = "client",
	query = { write = { "rtype.Transform", "rtype.SpriteRenderer", "game.StationTurret" } },
	after = { "game.MapSprites" },
	run = function(ctx)
		local fleet = source
		for entity, transform, sprite, turret in ctx.query do
			local kind = Stations.turretKinds[turret.kind]
			if kind then
				local engaged = fleet and fleet.turrets and fleet.turrets[turret.site]
				local path, rotation = Stations.turretParked(kind), 0
				if engaged then
					path = Stations.turretEngaged(kind, fleet.clock - engaged.since, fleet.reduced)
					rotation = math.atan2(engaged.x - transform.position.x, -(engaged.y - transform.position.y))
				end
				transform.rotation = rotation
				if shown[entity] ~= path then
					shown[entity] = path
					sprite.texture = Stations.texture(path)
				end
			end
		end
	end,
})

return StationFx
