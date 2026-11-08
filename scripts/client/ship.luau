-- Ship.parts(kind, corp, tier, position) -> { { name, desc, bloom }, ... }: the sprite parts of one ship (GR5-19).
-- desc is an entity description for commands:spawn(); bloom is the Bloom.params table for emissive parts and nil for the hull
-- (bloom is engine trail / running lights only). One sprite per kind of ship, recoloured per corporation by the remap
-- shader (client/remap.luau), never one file per corporation. Client only.
local Config = require("@scripts/config/ships")
local Remap = require("@scripts/client/remap")
local Bloom = require("@scripts/render/vfx/bloom")

local Ship = {}

-- Tests set Ship.assets to a stub: the Luau CLI has no `engine` global.
local function assets() return Ship.assets or engine.assets end

local textures = {}
local function texture(path: string)
	textures[path] = textures[path] or assets().texture(path)
	return textures[path]
end

-- Remap thresholds for a tier_glow in [0,1].
function Ship.steps(tierGlow: number): { number }
	local r = Config.remap
	local d = r.glow_shift * math.clamp(tierGlow, 0, 1)
	return { r.steps[1] - d, r.steps[2] - d, r.steps[3] - d }
end

-- Engine strip frame (0-based) at time t seconds.
function Ship.engineFrame(def, t: number): number
	return math.floor(t * Config.engine_fps) % def.engine.frames
end

local function sprite(sheet: string, frameIndex: number, layer: number, material)
	local px = Config.frame_px
	return {
		texture = texture(sheet),
		source = { x = frameIndex * px, y = 0, z = px, w = px },
		origin = { x = px / 2, y = px / 2 },
		material = material,
		layer = layer,
	}
end

-- tier: miner only (1..3), ignored for other kinds. time: seconds, picks the engine frame.
function Ship.parts(kind: string, corp: string, tier: number?, position, time: number?)
	local def = Config.ships[kind]
	assert(def, "Ship: unknown ship kind '" .. tostring(kind) .. "'")
	local t = def.tiers and def.tiers[math.clamp(tier or 1, 1, #def.tiers)] or nil
	local glow = t and t.tier_glow or 0
	local material = Remap.material(corp, Ship.steps(glow))
	local scale = def.scale or 1
	local transform = { position = position or { x = 0, y = 0 }, scale = { x = scale, y = scale } }

	local engineScale = t and t.engine_scale or 1
	local engineTransform = { position = transform.position, scale = { x = scale * engineScale, y = scale * engineScale } }

	local parts = {
		{
			name = "engine",
			desc = {
				["rtype.Transform"] = engineTransform,
				["rtype.SpriteRenderer"] = sprite(def.engine.sheet, Ship.engineFrame(def, time or 0), Config.layers.engine, material),
			},
			bloom = (Config.bloom.engine_trail or Config.bloom.running_lights) and Bloom.params() or nil,
		},
		{
			name = "hull",
			desc = {
				["rtype.Transform"] = transform,
				["rtype.SpriteRenderer"] = sprite(def.hull.sheet, 0, Config.layers.hull, material),
			},
			bloom = Config.bloom.hull and Bloom.params() or nil,
		},
	}
	return parts
end

return Ship
