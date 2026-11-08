-- GR5-18 gate: every station is built from distinct, existing pack sprites, goes through the palette remap with the
-- idle/active swap, and the emissive-only bloom scales with the state. Headless: engine asset calls are stubbed.
local config = require("@scripts/config/stations")
local Theme = require("@scripts/config/theme")
local Remap = require("@scripts/client/remap")
local Stations = require("@scripts/client/stations")

local materials = {}
local assets = {
  shader = function(path) return "shader:" .. path end,
  texture = function(path) return "texture:" .. path end,
  material = function(def) materials[def.name] = def; return def end,
}
Remap.assets, Stations.assets = assets, assets

local used = {}
for id, def in pairs(config.stations) do
  assert(#def.modules >= 2, id .. ": hub plus attached modules")
  assert(def.modules[1].role == "hub" and def.modules[1].x == 0 and def.modules[1].y == 0, id .. ": hub first, at the centre")
  assert(Theme.corps[config.corp[id]], id .. ": corporation is in the theme")
  local steps = config.steps[id] or config.steps.default
  assert(steps[1] < steps[2] and steps[2] < steps[3], id .. ": steps ascend")
  for _, m in ipairs(def.modules) do
    assert(not used[m.sprite], m.sprite .. " is used by two stations")
    used[m.sprite] = id
  end

  local idle = Stations.entities(id, "idle", { x = 100, y = 50 }, 0.5)
  local active = Stations.entities(id, "active", { x = 100, y = 50 })
  assert(#idle == #def.modules)
  local mi, ma = idle[1]["rtype.SpriteRenderer"].material, active[1]["rtype.SpriteRenderer"].material
  assert(mi ~= ma, id .. ": idle and active are different materials")
  assert(mi.shader == "shader:shaders/palette_remap.glsl", id .. ": goes through the palette remap")
  assert(mi.values.brightness == config.states.idle.brightness and ma.values.brightness == config.states.active.brightness)
  assert(mi.values.emissiveScale < ma.values.emissiveScale and mi.values.brightness < ma.values.brightness)
  assert(mi.values.ramp2.x ~= nil and mi.values.steps.y == steps[2], id .. ": ramp and steps are set")
  for i, e in ipairs(idle) do
    local m = def.modules[i]
    local s = e["rtype.SpriteRenderer"]
    assert(e["rtype.Transform"].position.x == 100 + m.x * 0.5 and e["rtype.Transform"].scale.x == 0.5)
    assert(s.texture == "texture:" .. config.spriteDir .. m.sprite .. ".png" and s.source.z == m.w and s.source.w == m.h)
    assert(s.layer == config.layer and s.material == mi, id .. ": one material for the whole station")
  end
end
assert(config.states.idle.emissiveScale < config.states.active.emissiveScale)
assert(Stations.bloom("idle").intensity < Stations.bloom("active").intensity, "bloom is dimmer when idle")
assert(not pcall(Stations.bloom, "off") and not pcall(Stations.entities, "nope", "idle", { x = 0, y = 0 }))

-- The corporation tint is a ramp of the theme: only the neon differs between corporations.
local a, b = Remap.ramp("player"), Remap.ramp("rivalA")
assert(a[1] == b[1] and a[2] == b[2] and a[4] == b[4] and a[3] ~= b[3])

print("station tests passed")
