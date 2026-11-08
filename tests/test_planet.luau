-- GR5-39 gate: the system map's planets are spawned with the data the renderer needs. Headless: the engine's asset calls
-- are stubbed, so this checks the wiring (entity components, positions, layers, material values), not the pixels.
local Theme = require("@scripts/config/theme")
local Screens = require("@scripts/config/screens")
local Planets = require("@scripts/config/planets")
local Backgrounds = require("@scripts/config/background")
local World = require("@scripts/config/world")
local Sim = require("@scripts/sim/sim")
local Shell = require("@scripts/ui/shell")
local SystemMap = require("@scripts/client/system_map")
local Planet = require("@scripts/client/planet")

local materials = {}
Planet.assets = {
  shader = function(path) return "shader:" .. path end,
  texture = function(path) return "texture:" .. path end,
  material = function(def) materials[def.name] = def; return "material:" .. def.name end,
}

-- Keep in step with the uniforms assets/shaders/planet.glsl declares: a missing or misspelt key leaves the shader on its
-- default for that value, silently.
local UNIFORMS = {
  "seed", "pixels", "size", "timeSpeed", "tilt", "phase", "waterLevel", "cloudCover", "octaves", "lightOrigin", "lightBorders",
  "land1", "land2", "land3", "land4", "water1", "water2", "cloud1", "cloud2", "rimWidth", "rim1", "rim2",
}

local sim = Sim.new()
local entities = SystemMap.entities(sim)
assert(#entities == #World.planetOrder, "one world entity per harvest planet")

local positions = Shell.planetPositions()
local main = Shell.layout().main
local r = Planets.planetRender
local frontOfBackground = -math.huge
for _, layers in pairs(Backgrounds.backgrounds) do
  for _, l in ipairs(layers) do frontOfBackground = math.max(frontOfBackground, l.layer) end
end

local function sameColor(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
local bg = { x = bit32.extract(Theme.palette.bg, 16, 8) / 255, y = bit32.extract(Theme.palette.bg, 8, 8) / 255, z = bit32.extract(Theme.palette.bg, 0, 8) / 255 }

for i, id in ipairs(World.planetOrder) do
  local e = entities[i]
  local t, s = e["rtype.Transform"], e["rtype.SpriteRenderer"]
  assert(t and s, id .. ": needs a Transform and a SpriteRenderer")

  local at = positions[id]
  assert(t.position.x == at.x and t.position.y == at.y, id .. ": world position is the UI label position")
  assert(at.x - Screens.map.planetRadius >= main.x and at.x + Screens.map.planetRadius <= main.x + main.w, id .. ": inside the main panel (x)")
  assert(at.y - Screens.map.planetRadius >= main.y and at.y + Screens.map.planetRadius <= main.y + main.h, id .. ": inside the main panel (y)")

  assert(t.scale.x == (Screens.map.planetRadius * 2) / r.textureSize and t.scale.x == t.scale.y, id .. ": square, diameter = 2 * radius")
  assert(s.source.z == r.textureSize and s.source.w == r.textureSize, id .. ": source is the whole texture")
  assert(s.origin.x == r.textureSize / 2 and s.origin.y == r.textureSize / 2, id .. ": origin is the centre")
  assert(s.layer > frontOfBackground and s.layer < 0, id .. ": drawn in front of every background layer")
  assert(s.texture == "texture:" .. r.texturePath and type(s.material) == "string", id .. ": texture and material set")

  local key = id .. (SystemMap.signature(sim):find(id .. "+", 1, true) and "" or ".locked")
  local m = materials["planet." .. key]
  assert(m and m.shader == "shader:" .. r.shaderPath, id .. ": material built on the planet shader")
  for _, name in ipairs(UNIFORMS) do assert(m.values[name] ~= nil, id .. ": material value '" .. name .. "' is missing") end
  for name in pairs(m.values) do assert(table.find(UNIFORMS, name), id .. ": material value '" .. name .. "' is not a uniform of planet.glsl") end

  -- the planet must show against the space behind it: a rim, and a shadow side that is not the backdrop colour
  assert(m.values.rimWidth > 0, id .. ": has an outline ring")
  assert(not sameColor(m.values.rim1, bg) and not sameColor(m.values.rim2, bg), id .. ": ring is not the backdrop colour")
  assert(not sameColor(m.values.land4, bg), id .. ": shadow side is not the backdrop colour")
end

for a = 1, #World.planetOrder do
  for b = a + 1, #World.planetOrder do
    local pa, pb = positions[World.planetOrder[a]], positions[World.planetOrder[b]]
    assert(math.sqrt((pa.x - pb.x) ^ 2 + (pa.y - pb.y) ^ 2) > Screens.map.planetRadius * 2, "planets do not overlap")
  end
end

-- a locked planet keeps its seed and shape but takes the locked colours and its own material
local locked = SystemMap.look("varn", false)
assert(locked.rim == Planets.locked.rim and locked.seed == Planets.planets.varn.seed, "locked look keeps the shape, greys the colours")
assert(Planets.planets.varn.rim and Planets.planets.varn.rim ~= Planets.locked.rim, "a lit planet has its own ring")

print("planet OK")
