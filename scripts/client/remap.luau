-- Remap.material(corp) -> a material that recolours a greyscale sprite onto that corporation's ramp of the theme
-- (assets/shaders/palette_remap.glsl). corp: a key of Theme.corps ("player", "rivalA", "rivalB"). Client only.
-- Use it as the `material` of a SpriteRenderer: there is one sprite file per kind of ship/station, never one per corporation.
local Theme = require("@scripts/config/theme")

local Remap = {}

local SHADER = "shaders/palette_remap.glsl"
local shader
local cache = {}

local function color(name: string)
	local hex = Theme.palette[name]
	assert(hex, "Remap: colour '" .. tostring(name) .. "' is not in the theme palette")
	return { x = bit32.extract(hex, 16, 8) / 255, y = bit32.extract(hex, 8, 8) / 255, z = bit32.extract(hex, 0, 8) / 255, w = 1 }
end

-- The four colour names of a corporation's ramp, dark to light (pure, for tests).
function Remap.ramp(corp: string)
	local neon = Theme.corps[corp]
	assert(neon, "Remap: unknown corporation '" .. tostring(corp) .. "'")
	local out = {}
	for i, name in ipairs(Theme.remapRamp) do out[i] = name == "$neon" and neon or name end
	return out
end

function Remap.material(corp: string)
	if cache[corp] then return cache[corp] end
	local ramp = Remap.ramp(corp)
	shader = shader or engine.assets.shader(SHADER)
	cache[corp] = engine.assets.material({
		name = "remap." .. corp,
		shader = shader,
		values = { ramp0 = color(ramp[1]), ramp1 = color(ramp[2]), ramp2 = color(ramp[3]), ramp3 = color(ramp[4]) },
	})
	return cache[corp]
end

return Remap
