-- Background.new(screenId, size, position?) builds the layered procedural space backdrop (see assets/shaders/background.glsl).
-- Returns a list of entity descriptions, back to front, to pass one by one to ctx.commands:spawn(). Client only.
-- Every colour is a theme name (config/theme.luau), so a background cannot leave the 8-colour theme.
-- Big stars are not drawn here: call Star.new (client/bodies.luau) for those.

local Theme = require("@scripts/config/theme")
local config = require("@scripts/config/background")
local Linear = require("@scripts/client/linear")

local Background = {}

local function paletteColor(name: string)
	local hex = Theme.palette[name]
	assert(hex, "Background: colour '" .. tostring(name) .. "' is not in the theme palette")
	return Linear.fromHex(hex)
end

local shader, texture

local function material(name: string, def, r)
	shader = shader or engine.assets.shader(r.shaderPath)
	texture = texture or engine.assets.texture(r.texturePath)
	local stars = def.stars or { "text", "text" }
	return engine.assets.material({
		name = name,
		shader = shader,
		values = {
			mode = def.mode,
			seed = def.seed,
			pixels = def.pixels or r.pixels,
			size = def.size,
			octaves = r.octaves,
			drift = { x = def.drift.x, y = def.drift.y },
			starDensity = def.starDensity or 0,
			ramp0 = paletteColor(def.ramp[1]),
			ramp1 = paletteColor(def.ramp[2]),
			ramp2 = paletteColor(def.ramp[3]),
			ramp3 = paletteColor(def.ramp[4]),
			star1 = paletteColor(stars[1]),
			star2 = paletteColor(stars[2]),
		},
	})
end

-- screenId: a key of config.backgrounds. size: {x, y} in world units, the area to cover.
function Background.new(screenId: string, size, position)
	local layers = config.backgrounds[screenId]
	assert(layers, "Background.new: unknown screen '" .. tostring(screenId) .. "'")
	local r = config.backgroundRender
	texture = texture or engine.assets.texture(r.texturePath)
	local out = {}
	for i, def in ipairs(layers) do
		out[i] = {
			["rtype.Transform"] = {
				position = position or { x = 0, y = 0 },
				scale = { x = size.x / r.textureSize, y = size.y / r.textureSize },
			},
			["rtype.SpriteRenderer"] = {
				texture = texture,
				source = { x = 0, y = 0, z = r.textureSize, w = r.textureSize }, -- the whole texture: UV 0..1
				origin = { x = r.textureSize / 2, y = r.textureSize / 2 },
				material = material("background." .. screenId .. "." .. i, def, r),
				layer = def.layer,
			},
		}
	end
	return out
end

return Background
