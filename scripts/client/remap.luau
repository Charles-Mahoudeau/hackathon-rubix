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

-- Remap.assets is set by tests to a stub: the Luau CLI has no `engine` global.
local function assets() return Remap.assets or engine.assets end

-- opts (all optional): steps = { a, b, c } luminance cuts, brightness, emissiveScale (see the shader). Materials are
-- cached per corporation and option set.
function Remap.material(corp: string, opts: { steps: { number }?, brightness: number?, emissiveScale: number? }?)
	local o = opts or {}
	local key = corp
	if opts then
		local s = o.steps or {}
		key = string.format("%s|%s|%s|%s,%s,%s", corp, tostring(o.brightness), tostring(o.emissiveScale), tostring(s[1]), tostring(s[2]), tostring(s[3]))
	end
	if cache[key] then return cache[key] end
	local ramp = Remap.ramp(corp)
	shader = shader or assets().shader(SHADER)
	local values = { ramp0 = color(ramp[1]), ramp1 = color(ramp[2]), ramp2 = color(ramp[3]), ramp3 = color(ramp[4]) }
	if o.steps then values.steps = { x = o.steps[1], y = o.steps[2], z = o.steps[3] } end
	if o.brightness then values.brightness = o.brightness end
	if o.emissiveScale then values.emissiveScale = o.emissiveScale end
	cache[key] = assets().material({ name = "remap." .. key, shader = shader, values = values })
	return cache[key]
end

return Remap
