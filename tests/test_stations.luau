-- GR5-18 gate: every station is built from distinct, existing pack sprites, goes through the palette remap with the
-- idle/active swap, and the emissive-only bloom scales with the state. Headless: engine asset calls are stubbed.
local config = require("@scripts/config/stations")
local Theme = require("@scripts/config/theme")
local Remap = require("@scripts/client/remap")
local Stations = require("@scripts/client/stations")
local SystemMap = require("@scripts/client/system_map")
local Sim = require("@scripts/sim/sim")
local Shell = require("@scripts/ui/shell")
local Screens = require("@scripts/config/screens")

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
  local everything = {}
  for _, stage in ipairs(def.stages or {}) do everything[stage.when] = true end
  for _, m in ipairs(Stations.parts(id, everything).modules) do
    assert(not used[m.sprite], m.sprite .. " is used by two stations")
    used[m.sprite] = id
  end
  for _, d in ipairs(Stations.parts(id, everything).debris) do
    assert(not used["debris" .. d.sprite], d.sprite .. " is used twice")
    used["debris" .. d.sprite] = id
  end

  local idle = Stations.entities(id, "idle", { x = 100, y = 50 }, 0.5)
  local active = Stations.entities(id, "active", { x = 100, y = 50 })
  local base = Stations.parts(id, nil)
  assert(#idle == #base.modules + #base.debris + #base.turrets)
  local mi, ma = idle[1]["rtype.SpriteRenderer"].material, active[1]["rtype.SpriteRenderer"].material
  assert(mi ~= ma, id .. ": idle and active are different materials")
  assert(mi.shader == "shader:shaders/palette_remap.glsl", id .. ": goes through the palette remap")
  assert(mi.values.brightness == config.states.idle.brightness and ma.values.brightness == config.states.active.brightness)
  assert(mi.values.emissiveScale < ma.values.emissiveScale and mi.values.brightness < ma.values.brightness)
  assert(mi.values.ramp2.x ~= nil and mi.values.steps.y == steps[2], id .. ": ramp and steps are set")
  for i, m in ipairs(base.modules) do
    local e = idle[i]
    local s = e["rtype.SpriteRenderer"]
    assert(e["rtype.Transform"].position.x == 100 + m.x * 0.5 and e["rtype.Transform"].scale.x == 0.5)
    assert(s.texture == "texture:" .. config.spriteDir .. m.sprite .. ".png" and s.source.z == m.w and s.source.w == m.h)
    assert(s.layer == config.layer and (m.corp and s.material ~= mi or s.material == mi), id .. ": one material for the whole station, bar the accents")
    assert(not m.corp or Theme.corps[m.corp], id .. ": accent corporation is in the theme")
  end
end

-- GR5-52: the whole pack is used: every building B01-B26, the 8 platforms, the 3 mini asteroids and Turret01-10.
local function seen(prefix, list)
  for _, name in ipairs(list) do assert(used[name], prefix .. name .. " is not drawn by any station") end
end
local wanted = {}
for n = 1, 26 do wanted[#wanted + 1] = string.format("B%02d", n) end
for n = 1, 8 do wanted[#wanted + 1] = string.format("Platform[PLAYER]/P%02d", n) end
seen("", wanted)
local stills = {}
for id, def in pairs(config.stations) do
  local all = {}
  for _, stage in ipairs(def.stages or {}) do all[stage.when] = true end
  for _, t in ipairs(Stations.parts(id, all).turrets) do if t.still then stills[t.still] = true end end
end
for n = 1, 10 do assert(stills[string.format("Turret%02d", n)], "Turret" .. n .. " is not drawn") end
for _, a in ipairs({ "01", "02", "03" }) do assert(used["debris" .. a], "MiniAsteroids/" .. a .. " is not drawn") end

-- stages: each upgrade adds modules and turrets, in order; only the upgrades reached count
local depot = {}
local prev = #Stations.parts("hmc_depot", depot).modules
for _, up in ipairs({ "warehouse", "tradingPost", "hub", "commandCenter" }) do
  depot[up] = true
  local now = #Stations.parts("hmc_depot", depot).modules
  assert(now > prev, up .. " adds a module to the depot")
  prev = now
end
assert(#Stations.parts("hmc_depot", { hub = true }).modules == #Stations.parts("hmc_depot", nil).modules + 3, "a stage shows only when reached")
local bb0, bb1 = Stations.bounds("hmc_depot", nil, 1), Stations.bounds("hmc_depot", depot, 1)
assert(bb1.top < bb0.top and bb1.bottom > bb0.bottom and bb1.left < bb0.left, "the full depot is bigger than the base one")

-- turrets: parked on a still idle frame; engaged they open once, then loop the fire frames; reduced motion is one still fire frame
local tcfg = config.turrets
for _, kind in ipairs(Stations.turretKinds) do
  local parked = Stations.turretParked(kind)
  assert(parked == Stations.turretParked(kind), kind .. ": parked is still")
  local opening = Stations.turretEngaged(kind, 0)
  assert(opening ~= parked, kind .. ": opening differs from parked")
  local seen = {}
  for i = 0, 120 do seen[Stations.turretEngaged(kind, i / tcfg.fps)] = true end
  local n = 0
  for _ in pairs(seen) do n += 1 end
  assert(n > 8, kind .. ": animated while engaged")
  local first, last = Stations.turretEngaged(kind, 20), Stations.turretEngaged(kind, 20 + 1000)
  assert(first and last, kind .. ": the fire loop never ends")
  assert(Stations.turretEngaged(kind, 0, true) == Stations.turretEngaged(kind, 9, true), kind .. ": reduced motion is one still frame")
end
local anim = {}
for _, e in ipairs(Stations.entities("hmc_depot", "active", { x = 0, y = 0 }, 1, nil, depot)) do
  local t = e["game.StationTurret"]
  if t then anim[#anim + 1] = t; assert(Stations.turretKinds[t.kind], "turret kind index") end
end
assert(#anim == 6, "every animated turret of the full depot carries the component")
assert(Stations.entities("hmc_depot", "idle", { x = 0, y = 0 }, 1, nil, depot)[#Stations.parts("hmc_depot", depot).modules + 1], "turrets drawn after the modules")

-- map: the depot at Kessa from tier 1, markets as they unlock, outposts when built
local sim = Sim.new()
local function ids(s) local out = {} for _, st in ipairs(SystemMap.stations(s)) do out[#out + 1] = st.id end return table.concat(out, ",") end
assert(ids(sim) == "hmc_depot", "tier 1: only the depot, at Kessa")
local kessa = Shell.planetPositions().kessa
local depotAt = SystemMap.stations(sim)[1].at
assert(math.abs(depotAt.x - kessa.x - config.map.home.dx) < 1e-9 and math.abs(depotAt.y - kessa.y - config.map.home.dy) < 1e-9)
local sig1 = SystemMap.stationSignature(sim)
sim.tier = 3
sim.upgrades.warehouse = true
assert(ids(sim) == "hmc_depot,orbis_exchange", "tier 3: Orbis")
assert(SystemMap.stationSignature(sim) ~= sig1, "the signature moves when the depot grows")
sim.tier = 4
sim.upgrades.hub = true
assert(ids(sim) == "hmc_depot,orbis_exchange,halcyon_shipyards,meridian_institute", "tier 4: all three markets")
sim.stations.varn = { id = "varn", planet = "varn", kind = "outpost", stock = {}, hangar = 0 }
assert(ids(sim) == "hmc_depot,outpost_varn,orbis_exchange,halcyon_shipyards,meridian_institute", "a built outpost appears on its planet")
local main = Shell.layout().main
local planets = Shell.planetPositions()
local function inside(st)
  local e, edge = Stations.extent(st.id, st.upgrades, st.scale), config.map.edge
  return st.at.x + e.left >= main.x + edge - 1e-6 and st.at.x + e.right <= main.x + main.w - edge + 1e-6
    and st.at.y + e.top >= main.y + edge - 1e-6 and st.at.y + e.bottom <= main.y + main.h - edge + 1e-6
end
for _, st in ipairs(SystemMap.stations(sim)) do
  assert(inside(st), st.id .. " stays inside the main panel, clear of the nebula edge")
  -- no station sits on a planet: its modules never cover a planet's centre
  local b = Stations.bounds(st.id, st.upgrades, st.scale)
  for pid, p in pairs(planets) do
    local covered = p.x > st.at.x + b.left and p.x < st.at.x + b.right and p.y > st.at.y + b.top and p.y < st.at.y + b.bottom
    assert(not covered, st.id .. " covers the planet " .. pid)
  end
end
-- the depot stays small on the 1280x720 map: 64-80 px wide at the start, a bigger box once every stage is built, clear of Kessa
local function depotOf(s) return SystemMap.stations(s)[1] end
local base = Sim.new()
local d0 = depotOf(base)
local e0 = Stations.extent("hmc_depot", nil, d0.scale)
assert(e0.right - e0.left >= 64 and e0.right - e0.left <= 80.5, "the base depot is 64-80 px wide: " .. (e0.right - e0.left))
assert(e0.bottom - e0.top <= 80.5, "the base depot is at most 80 px tall")
assert(config.turrets.frame * config.turrets.boost * d0.scale >= 20, "an animated turret is at least 20 px")
local off = { x = d0.at.x - kessa.x, y = d0.at.y - kessa.y }
assert(off.x > 40 and off.x < 90 and off.y < -40 and off.y > -90, "the depot hangs about 60 px up-right of Kessa")
local full = Sim.new()
for _, up in ipairs({ "warehouse", "tradingPost", "hub", "commandCenter" }) do full.upgrades[up] = true end
local d1 = depotOf(full)
local e1 = Stations.extent("hmc_depot", full.upgrades, d1.scale)
assert(inside(d1) and e1.right - e1.left <= 160 and e1.bottom - e1.top <= 160, "the full depot grows but stays within 160 px and the panel")
assert(Stations.parts("hmc_depot", nil).modules[1].w * d1.scale >= 30, "the full depot hub is still at least 30 px")
for _, d in ipairs({ d0, d1 }) do
  local dx, dy = d.at.x - kessa.x, d.at.y - kessa.y
  assert(math.sqrt(dx * dx + dy * dy) > Screens.map.planetRadius, "the depot hub is off Kessa's disc")
end
-- the label and dock line tie the depot and each outpost to its planet
local labels = SystemMap.stationLabels(sim)
assert(#labels == 2 and labels[1].label == config.map.home.label and labels[2].label == config.map.outposts.varn.label, "depot and outpost labelled")
for _, l in ipairs(labels) do
  assert(l.at.y >= main.y and #Shell.dashes(l.from, l.to, l.skipFrom, l.skipTo, l.spacing) >= 1, "a dock line with dashes")
end
-- a market's station stands against its node (above, or to the side), never on it, and big enough to read
for _, st in ipairs(SystemMap.stations(sim)) do
  local mid = ({ orbis_exchange = "orbis", halcyon_shipyards = "halcyon", meridian_institute = "meridian" })[st.id]
  if mid then
    local node = Shell.mapPoint(Screens.map.markets[mid].x, Screens.map.markets[mid].y)
    local e = Stations.extent(st.id, nil, st.scale)
    local over = node.x > st.at.x + e.left - 9 and node.x < st.at.x + e.right + 9 and node.y > st.at.y + e.top - 9 and node.y < st.at.y + e.bottom + 9
    assert(not over, st.id .. " does not cover its node")
    if not config.map.markets[mid].side then assert(st.at.y + e.bottom <= node.y - 9, st.id .. " is above its node") end
    assert(st.scale >= 0.2, st.id .. " is big enough to read")
  end
end

assert(config.states.idle.emissiveScale < config.states.active.emissiveScale)
assert(Stations.bloom("idle").intensity < Stations.bloom("active").intensity, "bloom is dimmer when idle")
assert(not pcall(Stations.bloom, "off") and not pcall(Stations.entities, "nope", "idle", { x = 0, y = 0 }))

-- The corporation tint is a ramp of the theme: only the neon differs between corporations.
local a, b = Remap.ramp("player"), Remap.ramp("rivalA")
assert(a[1] == b[1] and a[2] == b[2] and a[4] == b[4] and a[3] ~= b[3])

-- GR5-104: a station wears its real state and the roles it hosts; nothing is made up
do
  local s = Sim.new()
  local sid = SystemMap.stations(s)[1].sid
  assert(SystemMap.status(s, sid).label == "IDLE" and SystemMap.status(s, sid).tone == "dim", "a quiet station is idle")
  s.alertTrack.stations[sid] = true
  assert(SystemMap.status(s, sid).label == "FULL" and SystemMap.status(s, sid).alert, "station_full shows as an alert")
  s.alertTrack.stations[sid] = nil
  assert(#SystemMap.tags(s, sid) == 0, "no role tag without the role")
  local labels = SystemMap.stationLabels(s)
  assert(labels[1].status and labels[1].tags, "labels carry status and tags")
  for _, r in ipairs(SystemMap.reserved(s)) do assert(r.w > 0 and r.h > 0) end
end

print("station tests passed")
