-- Station turrets (GR5-52, GR5-104). Turrets are separate texture files per frame, so a client system swaps the texture of every
-- entity carrying game.StationTurret { kind, site, aim, corp } (kind: index into Stations.turretKinds, site: 1-based index of its
-- station in SystemMap.stations, 0 = none, aim: outward degrees, corp: index into Stations.corpNames). A turret stays parked on
-- its first idle frame; only while the fleet map reports a real raid fight in range of its station (`fleet.turrets[site]`, handed
-- over by StationFx.bind, from FleetMap.update) does it aim at it and play the opening and the fire loop, and the first frame of
-- each firing loop raises the muzzle flash (render/vfx/cues) towards that fight. The clock is the map's animation clock, so a
-- paused game freezes the turret as it is, and reduced motion shows one still fire frame without flashes. Client only.
local Stations = require("@scripts/client/stations")
local Cues = require("@scripts/render/vfx/cues")
local config = require("@scripts/config/stations")

engine.ecs.component("game.StationTurret", { fields = { kind = "u32", site = "u32", aim = "u32", corp = "u32" } })

local StationFx = {}
-- The engine freezes module tables, so the fleet lives in a local behind a setter.
local source
function StationFx.bind(fleet) source = fleet end

local shown = {}
local lastFrame = {}

engine.ecs.system("game.StationTurrets", {
	phase = "Update",
	side = "client",
	query = { write = { "rtype.Transform", "rtype.SpriteRenderer", "game.StationTurret" } },
	after = { "game.MapSprites" },
	run = function(ctx)
		local fleet = source
		local now = ctx.time.elapsed
		for entity, transform, sprite, turret in ctx.query do
			local kind = Stations.turretKinds[turret.kind]
			if kind then
				local engaged = fleet and fleet.turrets and fleet.turrets[turret.site]
				local path, rotation = Stations.turretParked(kind), 0
				if engaged then
					local age = fleet.clock - engaged.since
					path = Stations.turretEngaged(kind, age, fleet.reduced)
					rotation = math.atan2(engaged.x - transform.position.x, -(engaged.y - transform.position.y))
					local frame, last = math.floor(math.max(0, age) * config.turrets.fps), lastFrame[entity]
					lastFrame[entity] = frame
					if not fleet.reduced and (last == nil or frame > last) and Stations.engagedFireStart(kind, frame) then
						local size = config.turrets.frame * transform.scale.x
						local angle = math.deg(math.atan2(engaged.y - transform.position.y, engaged.x - transform.position.x)) % 360
						Cues.turretFire(Cues.shared, entity, transform.position.x, transform.position.y, size, angle, now, Stations.corpNames[turret.corp])
					end
				else
					lastFrame[entity] = nil
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
