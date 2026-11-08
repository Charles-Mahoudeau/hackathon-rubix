-- GR5-51 gate: the ships on the system map. Headless: asset calls are stubbed, so this checks which sprites exist, where, their
-- strip frames and layers, the raid sequence (shield, weapons, projectiles, destruction) and the entity wiring, not the pixels.
local Config = require("@scripts/config/ships")
local World = require("@scripts/config/world")
local Cfg = require("@scripts/config/branches").raiding
local Sim = require("@scripts/sim/sim")
local Market = require("@scripts/sim/market")
local Remap = require("@scripts/client/remap")
local Ship = require("@scripts/client/ship")
local FleetMap = require("@scripts/client/fleet_map")

local materials = {}
local stub = {
  shader = function(path) return "shader:" .. path end,
  texture = function(path) return "texture:" .. path end,
  material = function(def) materials[def.name] = def; return "material:" .. def.name end,
}
Remap.assets, Ship.assets = stub, stub

local FX = Config.map_fx
local FRAME_FPS = 30

-- Steps the sim `seconds` of game time and draws a frame every 1/30 s; returns the last sprite list and a counter of what was seen.
local function play(fleet, s, t, seconds, seen)
  local sprites
  for _ = 1, math.floor(seconds * FRAME_FPS) do
    s:run(math.max(1, s:ticks(1 / FRAME_FPS)))
    t += 1 / FRAME_FPS
    for _, e in ipairs(s:drainEvents()) do FleetMap.onEvent(fleet, e) end
    sprites = FleetMap.update(fleet, s, t)
    for _, sp in ipairs(sprites) do
      local what = sp.sheet:match("Kla'ed %- ([%w ]+)%.png") or sp.sheet:match("([%w ]+)%.png")
      if what == "Bullet" then seen.bullet = (seen.bullet or 0) + 1 end
      if what == "Torpedo" then seen.torpedo = (seen.torpedo or 0) + 1 end
      if what == "Wave" then seen.wave = (seen.wave or 0) + 1 end
      if sp.sheet:find("Weapons") then seen.weapons = (seen.weapons or 0) + 1 end
      if sp.key:match("^boom") then seen.boom = (seen.boom or 0) + 1 end
      if sp.key:match("^boom") then seen.maxBoomFrame = math.max(seen.maxBoomFrame or 0, sp.frame) end
    end
  end
  return sprites, t
end

local function find(sprites, key) for _, sp in ipairs(sprites) do if sp.key == key then return sp end end end

-- Every sprite is a frame of its strip, on a known layer, and uses a pack file the config names.
local sheets = {}
for _, def in pairs(Config.ships) do
  for _, part in ipairs({ "hull", "engine", "destruction", "shield", "weapons" }) do if def[part] then sheets[def[part].sheet] = true end end
end
for _, p in pairs(Config.projectiles) do sheets[p.sheet] = true end
sheets[FX.trail.sheet] = true
local function checkSprite(sp)
  assert(sheets[sp.sheet], "unknown sheet " .. tostring(sp.sheet))
  assert(sp.frame >= 0 and sp.frame == math.floor(sp.frame), "integer frame " .. sp.key)
  assert(sp.scale > 0 and sp.layer and sp.fw > 0 and sp.fh > 0)
  assert(sp.x == sp.x and sp.y == sp.y and sp.rot == sp.rot, "no NaN pose " .. sp.key)
end

local function depotOf(points) return { x = points.kessa.x + FX.depot.dx, y = points.kessa.y + FX.depot.dy } end

-- 1. T1: a docked miner is drawn next to Kessa with an animated engine.
do
  local s, fleet, seen = Sim.new(), FleetMap.new(), {}
  local points = FleetMap.points()
  local sprites, t = play(fleet, s, 0, 1.0, seen)
  local hull, engine = find(sprites, "ship:s1:hull"), find(sprites, "ship:s1:engine")
  assert(hull and engine, "a miner is a hull and an engine")
  assert(engine.layer < hull.layer, "engine behind the hull")
  assert(hull.sheet:find("Support ship %- Base") and engine.sheet:find("Support ship %- Engine"))
  local k = depotOf(points)
  local d = math.sqrt((hull.x - k.x) ^ 2 + (hull.y - k.y) ^ 2)
  assert(math.abs(d - FX.depot.ring) < 6, "parked on the depot ring, got " .. d)
  assert(not find(sprites, "ship:s1:trail:0"), "a parked ship leaves no trail")
  -- Engines animate only in transit: a parked ship's flame is a still frame.
  local still = {}
  for i = 0, 19 do
    local sp = FleetMap.update(fleet, s, t + i / 15)
    still[find(sp, "ship:s1:engine").frame] = true
    for _, x in ipairs(sp) do checkSprite(x) end
  end
  local n = 0
  for _ in pairs(still) do n += 1 end
  assert(n == 1, "a parked engine does not animate (" .. n .. " frames)")
end

-- 1b. GR5-104: nothing is invented. At game start the map shows only the real miner (no demo loop), big enough to see.
do
  local s, fleet = Sim.new(), FleetMap.new()
  local sprites = play(fleet, s, 0, 1.0, {})
  for _, sp in ipairs(sprites) do assert(not sp.key:match("^demo:"), "no cosmetic actor: " .. sp.key) end
  local hull = find(sprites, "ship:s1:hull")
  assert(hull.scale * 28 >= 40 and hull.corp == "player", "hulls are 40+ px (28 px of art in the frame) in the player's colour")
  assert(#fleet.chips == 1 and fleet.chips[1].badge.label == "DOCK" and fleet.chips[1].badge.tone == "dim", "a docked miner wears a dim DOCK badge")
end

-- 2. A travelling miner flies from Kessa towards the vein, nose first, and the flame speeds up.
do
  local s, fleet, seen = Sim.new(), FleetMap.new(), {}
  local ship = s.ships.s1
  ship.state, ship.dest, ship.timer = "travel_out", "ashfall", 100
  local before = FleetMap.update(fleet, s, 0)
  local a = find(before, "ship:s1:hull")
  s:run(0) ship.timer = 50
  local t = 0
  for _ = 1, 40 do t += 1 / 30; FleetMap.update(fleet, s, t) end
  local b = find(FleetMap.update(fleet, s, t + 1 / 30), "ship:s1:hull")
  local points = FleetMap.points()
  assert(math.abs(b.x - a.x) + math.abs(b.y - a.y) > 20, "the ship moved")
  local dp = depotOf(points)
  assert(math.abs(a.x - dp.x) < 1 and math.abs(a.y - dp.y) < 1, "a trip starts at the depot")
  local fwdX, fwdY = math.sin(b.rot), -math.cos(b.rot)
  local trails = 0
  for _, sp in ipairs(FleetMap.update(fleet, s, t + 1 / 30)) do
    if sp.key:match("^ship:s1:trail:") then
      trails += 1
      assert((sp.x - b.x) * fwdX + (sp.y - b.y) * fwdY < 0, "trail behind the flying miner")
    end
  end
  assert(trails == FX.trail.count, "a flying miner has a pixel trail")
  local frames = {}
  for i = 0, 19 do frames[find(FleetMap.update(fleet, s, t + i / 15), "ship:s1:engine").frame] = true end
  local nf = 0
  for _ in pairs(frames) do nf += 1 end
  assert(nf >= 3, "the engine flame animates in transit (" .. nf .. " frames)")
  assert(fleet.chips[1].badge.label == "TRAVEL" and fleet.chips[1].badge.tone == "cyan", "a travelling miner wears a cyan TRAVEL badge")
  local dx, dy = points.ashfall.x - dp.x, points.ashfall.y - dp.y
  assert(math.abs(math.atan2(dx, -dy) - b.rot) < 0.2, "nose points at the destination")
end

-- 3. T4: a freighter on a delivery is drawn between Kessa and the market, bigger than a miner.
do
  local s, fleet = Sim.new(), FleetMap.new()
  s:enterTier(4)
  s:addFreighter("kessa")
  local f = s.freighters[1]
  f.state, f.load, f.timer = "out", { resource = "titanium", qty = 10, destination = "orbis" }, s:ticks(World.freighterRoutes.kessa.orbis) // 2
  local sprites = FleetMap.update(fleet, s, 0)
  local hull = find(sprites, "freighter:F1:hull")
  assert(hull and hull.sheet:find("Frigate %- Base") and find(sprites, "freighter:F1:engine").sheet:find("Frigate %- Engine"))
  assert(hull.scale * 39 > find(sprites, "ship:s1:hull").scale * 28, "freighter is bigger than the miner (39 vs 28 px of art)")
  local p = FleetMap.points()
  local dp = depotOf(p)
  assert(hull.x >= math.min(dp.x, p.orbis.x) - 1 and hull.x <= math.max(dp.x, p.orbis.x) + 1, "between the depot and the market")
  f.state, f.load = "back", nil
  assert(find(FleetMap.update(fleet, s, 0.1), "freighter:F1:hull"), "still drawn on the way back")
end

-- 4. Raid: scan, chase, fight, win. Convoy with escorts, shield, weapon flashes, projectiles, destruction.
do
  local s = Sim.new({ seed = 11 })
  s:enterTier(4)
  s.lifetimeRevenue = 30000
  s.resources.credits, s.resources.compute = 100000, 500
  assert(s:openBranch("raiding"))
  Market.quiet(s.market)
  s.raid.convoySeq += 1
  local c = { id = "C1", corp = "korvax", resource = "iridium", qty = 200, escort = 2, dest = "meridian",
    from = s.home, total = s:ticks(World.freighterRoutes[s.home][ "meridian" ]), elapsed = 0, state = "travel" }
  s.raid.convoys[1] = c
  local fleet, seen = FleetMap.new(), {}
  local sprites, t = play(fleet, s, 0, 0.5, seen)
  assert(find(sprites, "convoy:C1:hull") and find(sprites, "escort:C1:1:hull") and find(sprites, "escort:C1:2:hull"), "convoy and two escorts")
  assert(find(sprites, "convoy:C1:hull").sheet:find("Bomber") and find(sprites, "escort:C1:1:hull").sheet:find("Fighter"))
  assert(not find(sprites, "convoy:C1:shield"), "no shield before a fight")
  assert(find(sprites, "convoy:C1:hull").corp == "rivalA" and find(sprites, "ship:s1:hull").corp == "player", "faction colours")

  local function ok(name, args) assert(s:validate("privateer", { name = name, args = args or {} })); assert(s:apply("privateer", { name = name, args = args or {} })) end
  ok("scan_route", { route = "meridian" })
  sprites, t = play(fleet, s, t, Cfg.interceptor.scanSeconds + 1, seen)
  ok("intercept", { convoy = "C1" })
  sprites, t = play(fleet, s, t, 3, seen)
  assert(find(sprites, "interceptor:i1:hull"), "the interceptor is drawn while chasing")
  sprites, t = play(fleet, s, t, 60, seen)
  assert(s.interceptors.i1.state == "alongside")
  local itc, cv = find(sprites, "interceptor:i1:hull"), find(sprites, "convoy:C1:hull")
  assert(math.sqrt((itc.x - cv.x) ^ 2 + (itc.y - cv.y) ^ 2) < 80, "alongside the convoy")

  ok("attack")
  sprites, t = play(fleet, s, t, 4, seen)
  assert(find(sprites, "convoy:C1:shield") and find(sprites, "interceptor:i1:shield"), "shields while fighting")
  assert(find(sprites, "interceptor:i1:hull").sheet:find("Weapons"), "weapon flash replaces the hull while firing")
  assert(seen.bullet and seen.torpedo and seen.wave, "projectiles and the impact wave appear: " .. table.concat((function() local l = {} for k in pairs(seen) do l[#l + 1] = k end table.sort(l) return l end)(), ","))
  for _, sp in ipairs(sprites) do checkSprite(sp) end

  sprites, t = play(fleet, s, t, Cfg.interceptor.attackSeconds, seen)
  assert(s.raid.attacks == 1 and #s.raid.convoys == 0, "the fight is over")
  assert(s.raid.wins == 1, "seed 11 wins the fight")
  assert(seen.boom and seen.boom > 0, "the raided convoy blows up")
  assert(not find(sprites, "convoy:C1:hull"), "the convoy is gone")
end

-- 5. Destruction strips play once through and are then removed.
do
  local s = Sim.new({ seed = 3 })
  s:enterTier(4)
  s.lifetimeRevenue = 30000
  s.resources.credits, s.resources.compute = 100000, 500
  assert(s:openBranch("raiding"))
  Market.quiet(s.market)
  local fleet = FleetMap.new()
  local c = { id = "C1", corp = "helion", resource = "iridium", qty = 50, escort = 0, dest = "meridian", from = s.home,
    total = s:ticks(World.freighterRoutes[s.home].meridian), elapsed = 0, state = "travel" }
  s.raid.convoys[1] = c
  FleetMap.update(fleet, s, 0)
  c.state = "fought"
  FleetMap.update(fleet, s, 0.1)
  s.raid.convoys = {}
  FleetMap.onEvent(fleet, { name = "raid_result", data = { convoy = "C1", won = true } })
  local frames, last = {}, nil
  for i = 0, 40 do
    local sprites = FleetMap.update(fleet, s, 0.2 + i / 30)
    local boom
    for _, sp in ipairs(sprites) do if sp.key:match("^boom") then boom = sp end end
    if boom then
      frames[boom.frame] = true
      last = boom
      assert(boom.sheet:find("Bomber %- Destruction"), "the convoy explodes with its own strip")
    end
  end
  local n = 0
  for _ in pairs(frames) do n += 1 end
  assert(n == Config.ships.convoy.destruction.frames, "every destruction frame plays (" .. n .. ")")
  local after = FleetMap.update(fleet, s, 5)
  for _, sp in ipairs(after) do assert(not sp.key:match("^boom"), "the explosion is removed") end

  -- a convoy that reaches its market is not blown up
  s.raid.convoys = { { id = "C2", corp = "helion", resource = "iridium", qty = 50, escort = 0, dest = "meridian", from = s.home,
    total = 100, elapsed = 10, state = "travel" } }
  FleetMap.update(fleet, s, 6)
  s.raid.convoys = {}
  for _, sp in ipairs(FleetMap.update(fleet, s, 6.1)) do assert(not sp.key:match("^boom")) end
end

-- 6. Entities: one per sprite, despawned when gone, and apply() writes the pose and the strip frame.
do
  local spawned, despawned, nextId = {}, {}, 0
  local commands = {
    spawn = function(_, desc) nextId += 1; spawned[nextId] = desc; return nextId end,
    despawn = function(_, e) despawned[e] = true end,
  }
  local s, fleet = Sim.new(), FleetMap.new()
  local n = FleetMap.sync(fleet, s, 0, commands, true)
  assert(n >= 2 and nextId == n, "every sprite spawned an entity (the real miner: hull and engine)")
  for _, desc in ipairs(spawned) do
    local r = desc["rtype.SpriteRenderer"]
    assert(desc["rtype.Transform"] and r.texture and r.material and r.source.z > 0 and r.source.z == r.source.w and desc["game.MapSprite"].slot)
  end
  assert(FleetMap.sync(fleet, s, 0.1, commands, true) == n and nextId == n, "nothing respawned")
  local slot = spawned[1]["game.MapSprite"].slot
  local transform, renderer = { position = {}, scale = {} }, { source = {} }
  FleetMap.apply(fleet, slot, transform, renderer)
  assert(transform.position.x and transform.scale.x > 0 and renderer.source.z > 0)
  assert(FleetMap.sync(fleet, s, 0.2, commands, false) == 0, "leaving the map clears it")
  for i = 1, n do assert(despawned[i], "entity " .. i .. " despawned") end
end

print("fleet map tests passed")
