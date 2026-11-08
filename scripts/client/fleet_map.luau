-- Moving ships on the system map (GR5-51): miners, freighters, rival convoys with their escorts and the player's interceptors,
-- drawn from the Kla'ed sprite strips (config/ships.luau) with the palette remap, an animated engine flame, shields while a
-- convoy is attacked, weapon flashes, projectiles and the destruction strips. Client only; the sim is only read.
--
-- FleetMap.update(fleet, sim, t) -> a list of sprite records { key, sheet, fw, fh, frame, x, y, rot, scale, layer, corp, glow }.
-- FleetMap.sync spawns / despawns one entity per record (`game.MapSprite` carries a slot) and FleetMap.apply, run every frame
-- by the game.MapSprites system, writes the record's pose and strip frame into the entity. Everything is a pure function of
-- the sim, the clock and the previous pose, so it runs headless in tests. Positions are view pixels, like the planets.
local Config = require("@scripts/config/ships")
local Screens = require("@scripts/config/screens")
local Raiding = require("@scripts/sim/raiding")
local Remap = require("@scripts/client/remap")
local Ship = require("@scripts/client/ship")
local Shell = require("@scripts/ui/shell")

local FleetMap = {}

local FX = Config.map_fx
local FRAME_PX = Config.frame_px

-- The state of the drawn fleet: smoothed poses, trip trackers, pending explosions and the spawned entities.
function FleetMap.new()
	return { realSeen = false, track = {}, pose = {}, fought = {}, results = {}, disabled = {}, effects = {}, fxSeq = 0, dest = {}, entities = {}, poses = {}, nextSlot = 1, lastT = nil }
end

-- Planet and market centres, id -> { x, y } (the same points the shell draws labels and routes at).
function FleetMap.points()
	local out = {}
	for id, p in pairs(Screens.map.planets) do out[id] = Shell.mapPoint(p.x, p.y) end
	for id, m in pairs(Screens.map.markets) do out[id] = Shell.mapPoint(m.x, m.y) end
	return out
end

-- Geometry ---------------------------------------------------------------------------------------------------------------

-- Sprites point up; a rotation is clockwise on screen. The angle of a move (dx, dy) in view pixels.
local function heading(dx: number, dy: number): number
	return math.atan2(dx, -dy)
end

local function lerp(a, b, t: number) return { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t } end

local function unit(a, b)
	local dx, dy = b.x - a.x, b.y - a.y
	local d = math.sqrt(dx * dx + dy * dy)
	if d < 1e-6 then return 0, -1 end
	return dx / d, dy / d
end

local function phaseOf(id: string): number
	local sum = 0
	for i = 1, #id do sum = (sum * 31 + string.byte(id, i)) % 6283 end
	return sum / 1000
end

-- A parked ship circles `centre` at `radius`; its heading is the tangent of the circle.
local function orbit(centre, radius: number, speed: number, phase: number, t: number)
	local a = phase + speed * t
	return { x = centre.x + math.cos(a) * radius, y = centre.y + math.sin(a) * radius, rot = heading(-math.sin(a), math.cos(a)) }
end

-- Forward and right unit vectors of a ship turned by `rot` (right is clockwise of forward on screen).
local function basis(rot: number)
	return math.sin(rot), -math.cos(rot), math.cos(rot), math.sin(rot)
end

local function angleDiff(a: number, b: number): number
	local d = (b - a) % (2 * math.pi)
	if d > math.pi then d -= 2 * math.pi end
	return d
end

-- Progress of a trip in 0..1 from the ticks left. The sim stores only the timer, so the first timer seen for a trip is its
-- total; a different trip (another state or destination) or a longer timer starts a new one.
local function progress(fleet, key: string, sig: string, timer: number, from)
	local tr = fleet.track[key]
	if not tr or tr.sig ~= sig or timer > tr.total then
		local pose = fleet.pose[key]
		tr = { sig = sig, total = math.max(timer, 1), from = pose and { x = pose.x, y = pose.y } or from }
		fleet.track[key] = tr
	end
	return math.clamp(1 - timer / tr.total, 0, 1), tr
end

-- Where a trip between two planets starts and ends: at the planet's edge, not its centre.
local function leg(a, b, t: number)
	local pad = Screens.map.planetRadius + FX.dock.pad / 2
	local ux, uy = unit(a, b)
	local from = a.depot and a or { x = a.x + ux * pad, y = a.y + uy * pad }
	local to = b.depot and b or { x = b.x - ux * pad, y = b.y - uy * pad }
	return lerp(from, to, t), heading(ux, uy)
end

-- Where a ship of planet `id` stops: the home planet's ships use the depot (points.depot) instead of its centre.
local function stop(points, sim, id: string?)
	if id == sim.home then return points.depot end
	return id and points[id]
end

-- Actors: one per ship, with the pose it should have right now ---------------------------------------------------------

local function dockRadius(extra: number?) return Screens.map.planetRadius + FX.dock.pad + (extra or 0) end

local function actorOf(key: string, kind: string, corp: string, pose, extra)
	local a = { key = key, kind = kind, corp = corp, x = pose.x, y = pose.y, rot = pose.rot }
	for k, v in pairs(extra or {}) do a[k] = v end
	return a
end

local function minerActors(fleet, sim, points, t, out)
	for i, id in ipairs(sim.shipOrder) do
		local ship = sim.ships[id]
		local key = "ship:" .. id
		local atId = ship.at or sim.home
		local at = stop(points, sim, atId) or points.depot
		local dest = stop(points, sim, ship.dest)
		local tier = math.clamp(ship.engineMark or 1, 1, #Config.ships.miner.tiers)
		local st = ship.state
		if (st == "travel_out" or st == "travel_back" or st == "travel_scan") and at and dest and dest ~= at then
			local p = progress(fleet, key, st .. ">" .. tostring(ship.dest), ship.timer or 0, at)
			local pos, rot = leg(at, dest, p)
			out[#out + 1] = actorOf(key, "miner", "player", { x = pos.x, y = pos.y, rot = rot }, { moving = true, tier = tier })
		elseif at and st == "mining" then
			local planet = points[atId] or points[sim.home]
			local pos = orbit(planet, Screens.map.planetRadius + FX.mining.pad, FX.mining.speed, phaseOf(id), t)
			out[#out + 1] = actorOf(key, "miner", "player", pos, { moving = true, tier = tier })
		elseif at then
			local pos
			if atId == sim.home then pos = orbit(points.depot, FX.depot.ring, FX.dock.speed, i * FX.dock.step, t)
			else pos = orbit(at, dockRadius(), FX.dock.speed, i * FX.dock.step, t) end
			out[#out + 1] = actorOf(key, "miner", "player", pos, { parked = true, tier = tier })
		end
	end
end

local function freighterActors(fleet, sim, points, t, out)
	for i, f in ipairs(sim.freighters) do
		local key = "freighter:" .. f.id
		local home = stop(points, sim, f.station)
		if home then
			if f.state == "out" and f.load then fleet.dest[f.id] = f.load.destination end
			local dest = stop(points, sim, fleet.dest[f.id])
			if (f.state == "out" or f.state == "back") and dest then
				local a, b = home, dest
				if f.state == "back" then a, b = dest, home end
				local p = progress(fleet, key, f.state .. ">" .. tostring(fleet.dest[f.id]), f.timer or 0, a)
				local pos, rot = leg(a, b, p)
				out[#out + 1] = actorOf(key, "freighter", "player", { x = pos.x, y = pos.y, rot = rot }, { moving = true })
			else
				local pos = orbit(home, home.depot and FX.depot.ring + 24 or dockRadius(18), FX.dock.speed * 0.6, math.pi + i * FX.dock.step, t)
				out[#out + 1] = actorOf(key, "freighter", "player", pos, { parked = true })
			end
		end
	end
end

local function corpOf(name: string): string return FX.corp_of[name] or "rivalA" end

-- Rival convoys with their escorts. Returns id -> the convoy actor, for the interceptors and the volleys.
local function convoyActors(fleet, sim, points, t, out)
	local byId = {}
	for _, c in ipairs(Raiding.mapConvoys(sim)) do
		local a, b = points[c.from], points[c.to]
		if a and b then
			local pos, rot = leg(a, b, c.t)
			local corp = corpOf(c.corp)
			local convoy = actorOf("convoy:" .. c.id, "convoy", corp, { x = pos.x, y = pos.y, rot = rot },
				{ moving = not c.fought, shield = c.fought, cid = c.id, escorts = {} })
			out[#out + 1] = convoy
			byId[c.id] = convoy
			local fx, fy, rx, ry = basis(rot)
			for e = 1, c.escort or 0 do
				local side = (e % 2 == 1) and 1 or -1
				local back = math.floor((e - 1) / 2) * FX.escort_gap * 0.8
				local escort = actorOf(("escort:%s:%d"):format(c.id, e), "privateer", corp,
					{ x = pos.x + rx * side * FX.escort_gap - fx * back, y = pos.y + ry * side * FX.escort_gap - fy * back, rot = rot },
					{ moving = not c.fought, shield = c.fought, firing = c.fought, cid = c.id, level = e })
				out[#out + 1] = escort
				convoy.escorts[#convoy.escorts + 1] = escort
			end
			if c.fought then fleet.fought[c.id] = true end
		end
	end
	return byId
end

local function interceptorActors(fleet, sim, points, t, convoys, out)
	local home = points.depot
	if not sim.interceptors or not home then return end
	for i, id in ipairs(sim.interceptorOrder) do
		local it = sim.interceptors[id]
		local key = "interceptor:" .. id
		local st, target = it.state, it.target and convoys[it.target]
		local sig = st .. ":" .. tostring(it.at) .. ":" .. tostring(it.target)
		local pose, extra = nil, { tier = 1 }
		if st == "chasing" and target then
			local p = progress(fleet, key, sig, it.timer or 0, home)
			local tr = fleet.track[key]
			local pos = lerp(tr.from, target, p)
			local ux, uy = unit(tr.from, target)
			pose, extra.moving = { x = pos.x, y = pos.y, rot = heading(ux, uy) }, true
		elseif (st == "alongside" or st == "fighting") and target then
			local fx, fy, rx, ry = basis(target.rot)
			local side = (st == "fighting") and -1 or 1
			local row = (i - 1) * FX.escort_gap * 0.7
			pose = { x = target.x + rx * side * FX.alongside.gap - fx * row, y = target.y + ry * side * FX.alongside.gap - fy * row, rot = target.rot }
			extra.moving, extra.firing, extra.shield, extra.cid = true, st == "fighting", st == "fighting", it.target
		elseif st == "returning" then
			local p, tr = progress(fleet, key, sig, it.timer or 0, home)
			local pos = lerp(tr.from, home, p)
			local ux, uy = unit(tr.from, home)
			pose, extra.moving = { x = pos.x, y = pos.y, rot = heading(ux, uy) }, true
		elseif it.at == "space" and fleet.pose[key] and st ~= "disabled" then
			local cur = fleet.pose[key]
			pose = { x = cur.x, y = cur.y, rot = cur.rot }
		else
			pose = orbit(home, FX.depot.ring + 14, FX.dock.speed, math.pi / 2 + i * FX.dock.step, t)
			extra.parked, extra.noEngine = true, st == "disabled"
		end
		out[#out + 1] = actorOf(key, "privateer", "player", pose, extra)
	end
end

-- Sprites ------------------------------------------------------------------------------------------------------------------

local function sprite(key, sheet, fw, fh, frame, x, y, rot, scale, layer, corp, glow, steps)
	return { key = key, sheet = sheet, fw = fw, fh = fh, frame = frame, x = x, y = y, rot = rot or 0, scale = scale, layer = layer, corp = corp, glow = glow or 0, steps = steps }
end

-- Engine trail: pixel squares streaming out behind a moving ship, shrinking as they age. A stateless function of the clock.
local function trailSprites(a, def, t, out)
	local T = FX.trail
	local fx, fy, rx, ry = basis(a.rot)
	local scale = def.map_scale or 0.6
	local phase = phaseOf(a.key)
	for j = 0, T.count - 1 do
		local clock = t * T.rate + j / T.count
		local age = clock % 1
		local back = T.rear * scale + age * T.length
		local side = math.sin(phase + j * 2.4 + math.floor(clock) * 1.7) * T.spread * (0.3 + age)
		out[#out + 1] = sprite(("%s:trail:%d"):format(a.key, j), T.sheet, T.px, T.px, 0, a.x - fx * back + rx * side, a.y - fy * back + ry * side,
			a.rot, math.max(T.size * (1 - 0.8 * age), 0.15), FX.layers.trail, a.corp, 0, T.steps)
	end
end

local function actorSprites(a, t, out)
	local def = Config.ships[a.kind]
	local tier = def.tiers and def.tiers[a.tier or 1] or nil
	local scale = def.map_scale or 0.6
	local glow = tier and tier.tier_glow or 0
	if a.moving and not a.noEngine then trailSprites(a, def, t, out) end
	if not a.noEngine then
		local fps = a.parked and FX.idle_engine_fps or Config.engine_fps
		out[#out + 1] = sprite(a.key .. ":engine", def.engine.sheet, FRAME_PX, FRAME_PX, math.floor(t * fps) % def.engine.frames, a.x, a.y, a.rot,
			scale * (tier and tier.engine_scale or 1), Config.layers.engine, a.corp, glow)
	end
	if a.firing and def.weapons then
		out[#out + 1] = sprite(a.key .. ":hull", def.weapons.sheet, FRAME_PX, FRAME_PX, math.floor(t * FX.weapons_fps) % def.weapons.frames, a.x, a.y, a.rot,
			scale, Config.layers.hull, a.corp, glow)
	else
		out[#out + 1] = sprite(a.key .. ":hull", def.hull.sheet, FRAME_PX, FRAME_PX, 0, a.x, a.y, a.rot, scale, Config.layers.hull, a.corp, glow)
	end
	if a.shield and def.shield then
		out[#out + 1] = sprite(a.key .. ":shield", def.shield.sheet, FRAME_PX, FRAME_PX, math.floor(t * FX.shield_fps) % def.shield.frames, a.x, a.y, a.rot,
			scale, FX.layers.shield, a.corp, glow)
	end
end

-- Shots in the air from `a` to `b`: `count` slots, each fires once every interval x count seconds and flies `flight` seconds.
local function volley(out, key, proj, a, b, t, interval, flight, count, offset, corp)
	local p = Config.projectiles[proj]
	local cycle = interval * count
	local rot = heading(b.x - a.x, b.y - a.y)
	for j = 0, count - 1 do
		local age = (t + offset - j * interval) % cycle
		if age < flight then
			local pos = lerp(a, b, age / flight)
			out[#out + 1] = sprite(("%s:%d"):format(key, j), p.sheet, p.fw, p.fh, math.floor(t * FX.shield_fps) % p.frames, pos.x, pos.y, rot,
				FX.projectile_scale, FX.layers.projectile, corp)
		end
	end
end

local function fightSprites(sim, actors, convoys, t, out)
	local fights = sim.raid and sim.raid.fights
	if not fights then return end
	local interceptors = {}
	for _, a in ipairs(actors) do if a.kind == "privateer" and a.key:sub(1, 12) == "interceptor:" and a.firing then interceptors[#interceptors + 1] = a end end
	local f = FX.fire
	for cid, fight in pairs(fights) do
		local convoy = convoys[cid]
		if convoy then
			out[#out + 1] = sprite("wave:" .. cid, Config.projectiles.wave.sheet, 64, 64, math.floor(t * FX.shield_fps) % Config.projectiles.wave.frames,
				convoy.x, convoy.y, convoy.rot + math.pi, FX.wave_scale, FX.layers.wave, convoy.corp)
			local pack = {}
			for _, a in ipairs(interceptors) do if a.cid == cid then pack[#pack + 1] = a end end
			for i, shooter in ipairs(pack) do
				volley(out, "bullet:" .. shooter.key, "bullet", shooter, convoy, t, f.interval, f.flight, f.per_ship, phaseOf(shooter.key), "player")
				if i == 1 then
					volley(out, "torpedo:" .. shooter.key, "torpedo", shooter, convoy, t, FX.torpedo.interval, FX.torpedo.flight, 1, 0, "player")
				end
			end
			for _, escort in ipairs(convoy.escorts) do
				local target = pack[(escort.level - 1) % math.max(#pack, 1) + 1]
				if target then
					local proj = escort.level >= 2 and "ray" or "big_bullet"
					volley(out, "shot:" .. escort.key, proj, escort, target, t, f.interval, proj == "ray" and FX.ray_flight or f.flight, 1, phaseOf(escort.key), convoy.corp)
				end
			end
		end
	end
end

local function explode(fleet, rec, t)
	local def = Config.ships[rec.kind]
	if not def then return end
	fleet.fxSeq += 1
	fleet.effects[#fleet.effects + 1] = { key = "boom:" .. fleet.fxSeq, kind = rec.kind, corp = rec.corp, x = rec.x, y = rec.y, rot = rec.rot, born = t }
end

-- A raid ended: its result is read when the convoy leaves the map in the same frame (see FleetMap.update).
function FleetMap.onEvent(fleet, event)
	if event.name == "raid_result" then fleet.results[event.data.convoy] = event.data.won end
end

local function effectSprites(fleet, t, out)
	local keep = {}
	for _, e in ipairs(fleet.effects) do
		local def = Config.ships[e.kind]
		local frame = math.floor((t - e.born) * FX.explosion.fps)
		if frame < def.destruction.frames then
			keep[#keep + 1] = e
			out[#out + 1] = sprite(e.key, def.destruction.sheet, FRAME_PX, FRAME_PX, math.max(frame, 0), e.x, e.y, e.rot,
				(def.map_scale or 0.6) * FX.explosion.scale, FX.layers.explosion, e.corp)
		end
	end
	fleet.effects = keep
end

-- True once the player's fleet does something the map shows: a trip, a vein being mined or a freighter.
local function realActivity(sim): boolean
	if #sim.freighters > 0 then return true end
	for _, ship in pairs(sim.ships) do
		local st = ship.state
		if st == "travel_out" or st == "travel_back" or st == "travel_scan" or st == "mining" then return true end
	end
	return false
end

-- The start-up loop (config demo): one miner circling the home planet and one hauler shuttling from the vein planet to the
-- depot and back, until the first real activity. Cosmetic: not in the sim, gone for good once realActivity() is true.
local function demoActors(points, sim, t, out)
	local D = FX.demo
	local planet, from, depot = points[sim.home], points[D.from], points.depot
	if not (planet and from and depot) then return end
	local ring = Screens.map.planetRadius + FX.mining.pad
	out[#out + 1] = actorOf("demo:miner", "miner", "player", orbit(planet, ring, FX.mining.speed, 1.0, t), { moving = true, tier = 1 })
	local cycle = 2 * (D.travel + D.dwell)
	local u = t % cycle
	local pose
	if u < D.travel then
		local pos, rot = leg(from, depot, u / D.travel)
		pose = { x = pos.x, y = pos.y, rot = rot }
	elseif u < D.travel + D.dwell then
		pose = orbit(depot, FX.depot.ring, FX.dock.speed * 2, 0, t)
	elseif u < 2 * D.travel + D.dwell then
		local pos, rot = leg(depot, from, (u - D.travel - D.dwell) / D.travel)
		pose = { x = pos.x, y = pos.y, rot = rot }
	else
		pose = orbit(from, ring, FX.mining.speed, 0, t)
	end
	out[#out + 1] = actorOf("demo:hauler", "miner", "player", pose, { moving = true, tier = 1 })
end

-- Smooths the actors' poses, notices who left the map (an exploded convoy, a disabled interceptor) and builds the sprites.
function FleetMap.update(fleet, sim, t: number)
	local dt = math.clamp(fleet.lastT and (t - fleet.lastT) or 0, 0, 0.25)
	fleet.lastT = t
	local points = FleetMap.points()
	local home = points[sim.home] or points.kessa
	points.depot = { x = home.x + FX.depot.dx, y = home.y + FX.depot.dy, depot = true }
	local actors, convoys = {}, nil
	if not fleet.realSeen then
		if realActivity(sim) then fleet.realSeen = true else demoActors(points, sim, t, actors) end
	end
	minerActors(fleet, sim, points, t, actors)
	freighterActors(fleet, sim, points, t, actors)
	convoys = convoyActors(fleet, sim, points, t, actors)
	interceptorActors(fleet, sim, points, t, convoys, actors)

	local k = 1 - math.exp(-FX.smoothing * dt)
	local seen = {}
	for _, a in ipairs(actors) do
		seen[a.key] = true
		local p = fleet.pose[a.key]
		if not p then
			p = { x = a.x, y = a.y, rot = a.rot }
			fleet.pose[a.key] = p
		else
			p.x, p.y, p.rot = p.x + (a.x - p.x) * k, p.y + (a.y - p.y) * k, p.rot + angleDiff(p.rot, a.rot) * k
		end
		p.kind, p.corp, p.cid = a.kind, a.corp, a.cid
		a.x, a.y, a.rot = p.x, p.y, p.rot
	end
	-- A convoy and its escorts that leave the map after a fight blow up, unless the raid was lost (they got away).
	local settled = {}
	for key, p in pairs(fleet.pose) do
		if not seen[key] then
			if p.cid and fleet.fought[p.cid] and fleet.results[p.cid] ~= false and key:sub(1, 12) ~= "interceptor:" then
				explode(fleet, p, t)
				settled[p.cid] = true
			end
			fleet.pose[key], fleet.track[key] = nil, nil
		end
	end
	for cid in pairs(settled) do fleet.fought[cid], fleet.results[cid] = nil, nil end
	for id, it in pairs(sim.interceptors or {}) do
		if it.state == "disabled" and not fleet.disabled[id] then
			fleet.disabled[id] = true
			local p = fleet.pose["interceptor:" .. id]
			if p then explode(fleet, p, t) end
		elseif it.state ~= "disabled" then
			fleet.disabled[id] = nil
		end
	end

	local sprites = {}
	for _, a in ipairs(actors) do actorSprites(a, t, sprites) end
	fightSprites(sim, actors, convoys, t, sprites)
	effectSprites(fleet, t, sprites)
	return sprites
end

-- Entities -----------------------------------------------------------------------------------------------------------------

function FleetMap.describe(s, slot: number)
	return {
		["rtype.Transform"] = { position = { x = s.x, y = s.y }, rotation = s.rot, scale = { x = s.scale, y = s.scale } },
		["rtype.SpriteRenderer"] = {
			texture = Ship.texture(s.sheet),
			source = { x = s.frame * s.fw, y = 0, z = s.fw, w = s.fh },
			origin = { x = s.fw / 2, y = s.fh / 2 },
			material = Remap.material(s.corp, { steps = s.steps or Ship.steps(s.glow) }),
			layer = s.layer,
		},
		["game.MapSprite"] = { slot = slot },
	}
end

-- Writes the sprite record of `slot` into the entity's Transform and SpriteRenderer (the game.MapSprites system, every frame).
function FleetMap.apply(fleet, slot: number, transform, renderer)
	local s = fleet.poses[slot]
	if not s then return end
	transform.position = { x = s.x, y = s.y }
	transform.rotation = s.rot
	transform.scale = { x = s.scale, y = s.scale }
	renderer.source = { x = s.frame * s.fw, y = 0, z = s.fw, w = s.fh }
end

-- Spawns the entities of new sprites, despawns those that are gone and hands the poses to apply(). `visible` false (another
-- screen) clears the map. sim may be nil before the first frame.
function FleetMap.sync(fleet, sim, t: number, commands, visible: boolean)
	local sprites = {}
	if visible and sim then sprites = FleetMap.update(fleet, sim, t)
	else fleet.pose, fleet.track, fleet.effects, fleet.lastT = {}, {}, {}, nil end
	local want = {}
	fleet.poses = {}
	for _, s in ipairs(sprites) do
		want[s.key] = true
		local e = fleet.entities[s.key]
		if not e then
			e = { slot = fleet.nextSlot }
			fleet.nextSlot += 1
			e.entity = commands:spawn(FleetMap.describe(s, e.slot))
			fleet.entities[s.key] = e
		end
		fleet.poses[e.slot] = s
	end
	for key, e in pairs(fleet.entities) do
		if not want[key] then
			commands:despawn(e.entity)
			fleet.entities[key] = nil
		end
	end
	return #sprites
end

return FleetMap
