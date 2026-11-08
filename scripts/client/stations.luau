-- Orbital stations (GR5-18): a station is a hub sprite plus attached modules (config/stations.luau), static, recoloured
-- by the palette remap (client/remap.luau) onto its corporation's ramp. idle/active only changes brightness and the
-- emissive fade; the bloom params for that state come from render/vfx/bloom. Client only.
-- GR5-52: stations grow stage by stage with the player's upgrades and carry animated turrets.
local config = require("@scripts/config/stations")
local Theme = require("@scripts/config/theme")
local Bloom = require("@scripts/render/vfx/bloom")
local Remap = require("@scripts/client/remap")

local Stations = {}

local function assets() return Stations.assets or engine.assets end

-- Params of the emissive-only bloom for a state ("idle" or "active").
function Stations.bloom(state: string)
	assert(config.states[state], "Stations: unknown state '" .. tostring(state) .. "'")
	local b = config.bloom
	return Bloom.params(state == "active" and b.intensityActive or b.intensityIdle)
end

-- The remap material of a station in a state; `corp` overrides the station's configured corporation.
function Stations.material(stationId: string, state: string, corp: string?)
	local s = config.states[state]
	assert(s, "Stations: unknown state '" .. tostring(state) .. "'")
	assert(config.stations[stationId], "Stations: unknown station '" .. tostring(stationId) .. "'")
	return Remap.material(corp or config.corp[stationId], {
		steps = config.steps[stationId] or config.steps.default,
		brightness = s.brightness,
		emissiveScale = s.emissiveScale,
	})
end

-- The stages of a station reached with `upgrades` (a set of sim.upgrades keys), in order; nil = base only.
local function reached(def, upgrades)
	local out = {}
	for _, stage in ipairs(def.stages or {}) do
		if upgrades and upgrades[stage.when] then out[#out + 1] = stage end
	end
	return out
end

-- The stages of a station reached with `upgrades`, in order.
function Stations.stagesReached(stationId: string, upgrades)
	return reached(config.stations[stationId], upgrades)
end

-- Every module, turret and debris entry a station shows with `upgrades`: base first (hub first), then stage by stage.
function Stations.parts(stationId: string, upgrades)
	local def = config.stations[stationId]
	assert(def, "Stations: unknown station '" .. tostring(stationId) .. "'")
	local modules, turrets, debris = {}, {}, {}
	local function add(src)
		for _, m in ipairs(src.modules or {}) do modules[#modules + 1] = m end
		for _, t in ipairs(src.turrets or {}) do turrets[#turrets + 1] = t end
		for _, d in ipairs(src.debris or {}) do debris[#debris + 1] = d end
	end
	add(def)
	for _, stage in ipairs(reached(def, upgrades)) do add(stage) end
	return { modules = modules, turrets = turrets, debris = debris }
end

-- Bounding box of the station's modules in px from the hub centre, times `scale`.
function Stations.bounds(stationId: string, upgrades, scale: number?)
	local k, b = scale or 1, nil
	for _, m in ipairs(Stations.parts(stationId, upgrades).modules) do
		local l, r, t, d = m.x - m.w / 2, m.x + m.w / 2, m.y - m.h / 2, m.y + m.h / 2
		b = b and { left = math.min(b.left, l), right = math.max(b.right, r), top = math.min(b.top, t), bottom = math.max(b.bottom, d) }
			or { left = l, right = r, top = t, bottom = d }
	end
	return { left = b.left * k, right = b.right * k, top = b.top * k, bottom = b.bottom * k }
end

-- Bounding box of everything the station draws (modules, turrets, debris) in px from the hub centre, times `scale`. A turret
-- counts at its drawn size: the animated ones are `turrets.boost` times their frame.
function Stations.extent(stationId: string, upgrades, scale: number?)
	local k, parts, b = scale or 1, Stations.parts(stationId, upgrades), nil
	local function add(x: number, y: number, w: number, h: number)
		local l, r, t, d = x - w / 2, x + w / 2, y - h / 2, y + h / 2
		b = b and { left = math.min(b.left, l), right = math.max(b.right, r), top = math.min(b.top, t), bottom = math.max(b.bottom, d) }
			or { left = l, right = r, top = t, bottom = d }
	end
	for _, m in ipairs(parts.modules) do add(m.x, m.y, m.w, m.h) end
	for _, d in ipairs(parts.debris) do add(d.x, d.y, d.w, d.h) end
	for _, t in ipairs(parts.turrets) do
		if t.kind then
			local f = config.turrets.frame * config.turrets.boost
			add(t.x, t.y, f, f)
		else
			add(t.x, t.y, t.w, t.h)
		end
	end
	return { left = b.left * k, right = b.right * k, top = b.top * k, bottom = b.bottom * k }
end

-- Names of the animated turret kinds, sorted: the index goes in the entity's game.StationTurret component.
local kindNames = {}
for name in pairs(config.turrets.kinds) do kindNames[#kindNames + 1] = name end
table.sort(kindNames)
Stations.turretKinds = kindNames

local function expand(strip): { string }
	if strip.file then return { config.turretDir .. strip.dir .. strip.file } end
	local out = {}
	for n = strip.from, strip.to do
		out[#out + 1] = config.turretDir .. strip.dir .. string.format("%s%0" .. strip.digits .. "d.png", strip.prefix, n)
	end
	return out
end

local framesOf = {}
local function framesFor(kind: string)
	if framesOf[kind] then return framesOf[kind] end
	local def = config.turrets.kinds[kind]
	assert(def, "Stations: unknown turret '" .. tostring(kind) .. "'")
	framesOf[kind] = { idle = expand(def.idle), open = expand(def.open), fire = expand(def.fire) }
	return framesOf[kind]
end

-- GR5-104: a turret is parked (the first idle frame, still) until the map reports a real fight in range.
function Stations.turretParked(kind: string): string return framesFor(kind).idle[1] end

-- The frame of a turret that has been engaged for `age` seconds: the opening once, then the firing loop. Reduced motion shows
-- one still firing frame (the state, without the animation).
function Stations.turretEngaged(kind: string, age: number, reduced: boolean?): string
	local f = framesFor(kind)
	if reduced then return f.fire[1] end
	local i = math.floor(math.max(0, age) * config.turrets.fps)
	if i < #f.open then return f.open[i + 1] end
	return f.fire[(i - #f.open) % #f.fire + 1]
end

-- True when animation frame `frame` of an engaged turret (floor(age * fps)) starts a firing loop: one shot per loop.
function Stations.engagedFireStart(kind: string, frame: number): boolean
	local f = framesFor(kind)
	return frame >= #f.open and (frame - #f.open) % #f.fire == 0
end

-- True when absolute animation frame `frame` (floor(t * fps), any integer) is the first frame of a firing loop: one shot per loop.
function Stations.isFireStart(kind: string, frame: number): boolean
	local def, t = config.turrets.kinds[kind], config.turrets
	assert(def, "Stations: unknown turret '" .. tostring(kind) .. "'")
	local length = #Stations.turretSequence(kind)
	local fireLength = #expand(def.fire)
	local first = math.floor(t.idleHold * t.fps) + #expand(def.open)
	local i = frame % length
	return i >= first and (i - first) % fireLength == 0
end

-- Names of the corporations, sorted: the index goes in the entity's game.StationTurret `corp` (the colour of its muzzle flash).
local corpNames = {}
for name in pairs(Theme.corps) do corpNames[#corpNames + 1] = name end
table.sort(corpNames)
Stations.corpNames = corpNames

-- Direction in whole degrees (0 = right, 90 = down) from the hub centre out through a turret at (x, y); straight up on the hub.
function Stations.aimOf(x: number, y: number): number
	if x == 0 and y == 0 then return 270 end
	return math.floor(math.deg(math.atan2(y, x)) % 360 + 0.5) % 360
end

local textures = {}
-- The cached texture handle of a path under assets/.
function Stations.texture(path: string)
	textures[path] = textures[path] or assets().texture(path)
	return textures[path]
end

local function sprite(path: string, w: number, h: number, material, layer: number)
	return {
		texture = Stations.texture(path),
		source = { x = 0, y = 0, z = w, w = h },
		origin = { x = w / 2, y = h / 2 },
		material = material,
		layer = layer,
	}
end

-- Entity descriptions (hub first) to pass to ctx.commands:spawn(). position: station centre in world units;
-- scale: world units per sprite pixel; upgrades: the stages reached (nil = the base station). Turrets come last, on top;
-- the animated ones carry game.StationTurret { kind, site, aim, corp } for client/station_fx to engage (site: set by SystemMap).
function Stations.entities(stationId: string, state: string, position, scale: number?, corp: string?, upgrades)
	local parts = Stations.parts(stationId, upgrades)
	local material, k, out = Stations.material(stationId, state, corp), scale or 1, {}
	local function at(x: number, y: number) return { position = { x = position.x + x * k, y = position.y + y * k }, scale = { x = k, y = k } } end
	for _, m in ipairs(parts.modules) do
		local mat = m.corp and Stations.material(stationId, state, m.corp) or material
		out[#out + 1] = { ["rtype.Transform"] = at(m.x, m.y), ["rtype.SpriteRenderer"] = sprite(config.spriteDir .. m.sprite .. ".png", m.w, m.h, mat, config.layer) }
	end
	for _, d in ipairs(parts.debris) do
		out[#out + 1] = { ["rtype.Transform"] = at(d.x, d.y), ["rtype.SpriteRenderer"] = sprite(config.debrisDir .. d.sprite .. ".png", d.w, d.h, material, config.layer) }
	end
	local frame = config.turrets.frame
	for _, t in ipairs(parts.turrets) do
		if t.kind then
			local idx = table.find(kindNames, t.kind)
			assert(idx, "Stations: unknown turret '" .. tostring(t.kind) .. "'")
			local boosted = at(t.x, t.y)
			boosted.scale = { x = k * config.turrets.boost, y = k * config.turrets.boost }
			out[#out + 1] = {
				["rtype.Transform"] = boosted,
				["rtype.SpriteRenderer"] = sprite(Stations.turretParked(t.kind), frame, frame, material, config.turretLayer),
				["game.StationTurret"] = { kind = idx, site = 0, aim = Stations.aimOf(t.x, t.y),
					corp = table.find(corpNames, corp or config.corp[stationId]) or 1 },
			}
		else
			out[#out + 1] = { ["rtype.Transform"] = at(t.x, t.y), ["rtype.SpriteRenderer"] = sprite(config.turretDir .. t.still .. ".png", t.w, t.h, material, config.turretLayer) }
		end
	end
	return out
end

return Stations
