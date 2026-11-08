-- GR5-19 gate: miner/freighter sprites are wired through the palette remap with the corporation as a material value, bloom is
-- emissive-only, and the two ships stay distinguishable at map-icon size. Headless: asset calls are stubbed.
local Config = require("@scripts/config/ships")
local Theme = require("@scripts/config/theme")
local Remap = require("@scripts/client/remap")
local Ship = require("@scripts/client/ship")

local materials = {}
local stub = {
  shader = function(path) return "shader:" .. path end,
  texture = function(path) return "texture:" .. path end,
  material = function(def) materials[def.name] = def; return "material:" .. def.name end,
}
Remap.assets, Ship.assets = stub, stub

local function find(parts, name) for _, p in ipairs(parts) do if p.name == name then return p end end end

-- One sprite file per ship kind; the corporation only changes the material (ramp), never the texture.
local cyan = Ship.parts("miner", "player", 1, { x = 0, y = 0 })
local magenta = Ship.parts("miner", "rivalA", 1, { x = 0, y = 0 })
local hullC, hullM = find(cyan, "hull").desc["rtype.SpriteRenderer"], find(magenta, "hull").desc["rtype.SpriteRenderer"]
assert(hullC.texture == hullM.texture, "same sprite for every corporation")
assert(hullC.material ~= hullM.material, "corporation colour is a material value")
for _, corp in ipairs({ "player", "rivalA", "rivalB" }) do
  Ship.parts("miner", corp, 1, { x = 0, y = 0 })
  local ramp = Remap.ramp(corp)
  local def = materials["remap." .. corp .. "|" .. table.concat(Ship.steps(0), ",")]
  assert(def, "material for " .. corp)
  assert(def.values.ramp2.x ~= nil and Theme.corps[corp] == ramp[3], "neon of the ramp is the corporation's")
  assert(def.values.steps.x == Config.remap.steps[1], "ship thresholds passed to the shader")
end

-- tier_glow brightens by lowering the thresholds; no sprite or palette colour is added.
local s1, s3 = Ship.steps(Config.ships.miner.tiers[1].tier_glow), Ship.steps(Config.ships.miner.tiers[3].tier_glow)
assert(s3[1] < s1[1] and s3[2] < s1[2] and s3[3] < s1[3], "Mk3 is brighter than Mk1")
for _, steps in ipairs({ s1, s3 }) do assert(steps[1] > 0 and steps[1] < steps[2] and steps[2] < steps[3] and steps[3] < 1) end

-- Tiers differ visibly: engine overlay grows with the tier.
local function engineScale(tier) return find(Ship.parts("miner", "player", tier, { x = 0, y = 0 }), "engine").desc["rtype.Transform"].scale.x end
assert(engineScale(1) < engineScale(2) and engineScale(2) < engineScale(3), "engine overlay grows with the tier")

-- Bloom: engine only, never the hull.
for _, kind in ipairs({ "miner", "freighter" }) do
  local parts = Ship.parts(kind, "player", 1, { x = 0, y = 0 })
  assert(find(parts, "engine").bloom and find(parts, "engine").bloom.intensity > 0, kind .. " engine blooms")
  assert(find(parts, "hull").bloom == nil, kind .. " hull does not bloom")
  assert(find(parts, "engine").desc["rtype.SpriteRenderer"].layer < find(parts, "hull").desc["rtype.SpriteRenderer"].layer)
end

-- Engine animation stays inside the strip.
for t = 0, 3, 0.07 do
  for _, def in pairs(Config.ships) do local f = Ship.engineFrame(def, t); assert(f >= 0 and f < def.engine.frames) end
end

-- Map readability: the freighter is bigger than the miner on screen, and its map icon differs in shape and size.
local m, f = Config.ships.miner, Config.ships.freighter
assert((f.scale or 1) > (m.scale or 1) and f.map_icon.shape ~= m.map_icon.shape and f.map_icon.size_px > m.map_icon.size_px)
assert(m.map_icon.size_px >= 6, "smallest map icon stays readable")
print("ship tests passed")
