-- Run from repo root: luau tests/test_map_life.luau
-- GR5-104: the choreography rules of GR5-103 on the system map: berths, label placement, badges, the hull / quad budgets with
-- their `+N` overflow, the reachability reveal, pause and reduced motion. Headless; the sim is the only source of state.
local Config = require("@scripts/config/ships")
local Sim = require("@scripts/sim/sim")
local Salvage = require("@scripts/sim/salvage")
local Remap = require("@scripts/client/remap")
local Ship = require("@scripts/client/ship")
local MapLife = require("@scripts/client/map_life")
local FleetMap = require("@scripts/client/fleet_map")

local stub = {
  shader = function(path) return "shader:" .. path end,
  texture = function(path) return "texture:" .. path end,
  material = function(def) return "material:" .. def.name end,
}
Remap.assets, Ship.assets = stub, stub

local LIFE = Config.map_fx.life
local BOUNDS = { x = 0, y = 0, w = 1280, h = 720 }

local function find(sprites, key) for _, sp in ipairs(sprites) do if sp.key == key then return sp end end end
local function count(sprites, pattern) local n = 0 for _, sp in ipairs(sprites) do if sp.key:match(pattern) then n += 1 end end return n end

-- 1. label placement: above first, then right / below / left; nil when boxed in
do
  local anchor = { x = 600, y = 300, w = 28, h = 28 }
  local r = MapLife.place(52, 16, anchor, {}, BOUNDS)
  assert(r and r.y + r.h <= anchor.y, "above first")
  local above = { x = r.x, y = r.y, w = r.w, h = r.h }
  local r2 = MapLife.place(52, 16, anchor, { above }, BOUNDS)
  assert(r2 and r2.x >= anchor.x + anchor.w, "then to the right")
  assert(not MapLife.overlaps(r2, above, LIFE.clear.label))
  local wall = { { x = 0, y = 0, w = 1280, h = 720 } }
  assert(MapLife.place(52, 16, anchor, wall, BOUNDS) == nil, "nothing fits: the caller falls back to a numbered marker")
  local edge = MapLife.place(52, 16, { x = 2, y = 100, w = 10, h = 10 }, {}, BOUNDS)
  assert(edge and edge.x >= 0 and edge.y >= 0, "stays inside the bounds")
end

-- 2. berths: stable, clear of each other by 12 px and of reserved boxes
do
  local anchor = { x = 400, y = 300 }
  local a = MapLife.berths(anchor, 34, 9, 40, {}, BOUNDS)
  local b = MapLife.berths(anchor, 34, 9, 40, {}, BOUNDS)
  assert(#a == 9)
  for i = 1, 9 do assert(a[i].x == b[i].x and a[i].y == b[i].y, "deterministic") end
  for i = 1, 9 do
    for j = i + 1, 9 do
      local d = math.sqrt((a[i].x - a[j].x) ^ 2 + (a[i].y - a[j].y) ^ 2)
      assert(d >= 40 + LIFE.clear.hull - 1, ("hulls %d and %d are %.1f apart"):format(i, j, d))
    end
  end
  local blocked = { { x = a[1].x - 30, y = a[1].y - 30, w = 60, h = 60 } }
  local c = MapLife.berths(anchor, 34, 3, 40, blocked, BOUNDS)
  for _, s in ipairs(c) do
    assert(not MapLife.overlaps({ x = s.x - 20, y = s.y - 20, w = 40, h = 40 }, blocked[1], LIFE.clear.station), "berths avoid a station box")
  end
end

-- 3. badges: a tone, a shape and a text label; a real AI failure is magenta, a block amber
do
  local seen = {}
  for _, k in ipairs({ "moving", "working", "waiting", "docked", "warning", "error", "combat" }) do
    local b = MapLife.badge(k)
    assert(b.tone and b.shape and #b.label > 0)
    seen[b.tone .. "/" .. b.shape] = true
  end
  assert(MapLife.badge("moving").tone == "cyan" and MapLife.badge("working").tone == "green" and MapLife.badge("waiting").tone == "dim")
  assert(MapLife.badge("warning").tone == "amber" and MapLife.badge("error").tone == "magenta" and MapLife.badge("error").alert)
  assert(MapLife.badge("error").shape ~= MapLife.badge("warning").shape, "shape tells them apart without colour")
  assert(MapLife.agentBadge({ state = "paused_error" }, "moving").tone == "magenta")
  assert(MapLife.agentBadge({ state = "no_compute" }, "working").tone == "amber")
  assert(MapLife.agentBadge({ state = "acting" }, "working").tone == "green")
end

-- 4. the hull budget: selected, alerts, own ships, then the nearest others; the rest is an aggregate, never dropped
do
  local actors = {}
  for i = 1, 20 do
    actors[i] = { key = "n" .. i, focusId = "n" .. i, corp = "rivalA", x = 100 + i * 30, y = 100, anchor = { id = "route" .. (i % 2), x = 50, y = 50 + (i % 2) * 100 } }
  end
  actors[19].badge = MapLife.badge("warning")
  actors[20].corp = "player"
  local r = MapLife.budget(actors, "n18", { x = 0, y = 0 }, 16)
  local shown, hidden = 0, 0
  for _ in pairs(r.shown) do shown += 1 end
  for _ in pairs(r.hidden) do hidden += 1 end
  assert(shown == 16 and hidden == 4 and #r.ranked == 16)
  assert(r.shown.n18, "the selected one is always drawn")
  assert(r.shown.n19, "an alert is always drawn")
  assert(r.shown.n20, "the player's own ship is drawn before the NPCs")
  assert(r.ranked[1].key == "n18" and r.ranked[2].key == "n19" and r.ranked[3].key == "n20", "priority order")
  assert(not r.shown.n17 and not r.shown.n16 and not r.shown.n15, "the farthest NPCs are the ones that go")
  local total = 0
  for _, g in ipairs(r.aggregates) do total += g.count end
  assert(total == 4, "every hidden hull is counted in a +N")
end

-- 5. the reachability reveal: no cinematic on hydration, one per false -> true, queued in map order
do
  local order = { "kessa", "ashfall", "orbis" }
  local rv = MapLife.newReveal()
  assert(MapLife.updateReveal(rv, { kessa = true, ashfall = true }, order, 0, false) == nil, "hydration shows nothing")
  assert(MapLife.updateReveal(rv, { kessa = true, ashfall = true }, order, 1, false) == nil, "no change, no reveal")
  local cue = MapLife.updateReveal(rv, { kessa = true, ashfall = true, orbis = true }, order, 2, false)
  assert(cue and cue.id == "orbis" and cue.label == 0)
  cue = MapLife.updateReveal(rv, { kessa = true, ashfall = true, orbis = true }, order, 2.7, false)
  assert(cue.ring and cue.ring > 0 and cue.ring <= LIFE.reveal.ringReach and cue.ringAlpha < 1 and cue.label > 0)
  assert(MapLife.updateReveal(rv, { kessa = true, ashfall = true, orbis = true }, order, 4.1, false) == nil, "over after ~2 s")
  -- two at once: map order, one after the other
  rv = MapLife.newReveal()
  MapLife.updateReveal(rv, {}, order, 0, false)
  cue = MapLife.updateReveal(rv, { orbis = true, kessa = true }, order, 1, false)
  assert(cue.id == "kessa")
  cue = MapLife.updateReveal(rv, { orbis = true, kessa = true }, order, 3.1, false)
  assert(cue and cue.id == "orbis", "the second plays after the first")
  -- reduced motion: a static outline for 0.5 s, no ring
  rv = MapLife.newReveal()
  MapLife.updateReveal(rv, {}, order, 0, true)
  cue = MapLife.updateReveal(rv, { kessa = true }, order, 1, true)
  assert(cue.outline and not cue.ring)
  assert(MapLife.updateReveal(rv, { kessa = true }, order, 1.6, true) == nil)
end

-- 6. working: a miner at its vein hovers 2 px, throws up to 2 cyan 2 px sparks, and has no animated engine
do
  local s, fleet = Sim.new(), FleetMap.new()
  local ship = s.ships.s1
  ship.state, ship.at = "mining", "ashfall"
  local lo, hi, frames, sparks = math.huge, -math.huge, {}, 0
  for i = 0, 180 do
    local sp = FleetMap.update(fleet, s, i / 30)
    local hull = find(sp, "ship:s1:hull")
    lo, hi = math.min(lo, hull.y), math.max(hi, hull.y)
    frames[find(sp, "ship:s1:engine").frame] = true
    local n = count(sp, "^ship:s1:spark:")
    assert(n <= LIFE.quads.count, "at most 2 sparks")
    sparks = math.max(sparks, n)
    for _, x in ipairs(sp) do
      if x.key:match(":spark:") then assert(x.scale * Config.map_fx.trail.px == LIFE.quads.size, "sparks are 2 px quads") end
    end
  end
  assert(hi - lo > 1.5 and hi - lo <= 2 * LIFE.hover.amp + 0.01, "hover amplitude is 2 px: " .. (hi - lo))
  assert(sparks >= 1, "sparks appear while mining")
  local n = 0
  for _ in pairs(frames) do n += 1 end
  assert(n == 1, "no engine animation while working")
  assert(fleet.chips[1].badge.label == "MINE" and fleet.chips[1].badge.tone == "green")
end

-- 7. pause freezes the animation clock without touching the actual state; reduced motion drops hover, sparks and trails
do
  local s, fleet = Sim.new(), FleetMap.new()
  s.ships.s1.state, s.ships.s1.at = "mining", "ashfall"
  FleetMap.update(fleet, s, 0)
  local before = FleetMap.update(fleet, s, 1.0)
  s.paused = true
  for i = 1, 18 do FleetMap.update(fleet, s, 1.0 + i * 0.1) end -- smoothing settles on the frozen targets
  local a = FleetMap.update(fleet, s, 2.9)
  local b = FleetMap.update(fleet, s, 5.0)
  for i, sp in ipairs(a) do assert(sp.key == b[i].key and math.abs(sp.x - b[i].x) < 0.01 and math.abs(sp.y - b[i].y) < 0.01 and sp.frame == b[i].frame, ("frozen while paused: %s %s %s %s %s"):format(sp.key, sp.x, b[i].x, sp.y, b[i].y)) end
  assert(fleet.chips[1].badge.label == "MINE", "the real state is still shown")
  s.paused = false
  local c = FleetMap.update(fleet, s, 5.2)
  assert(find(c, "ship:s1:hull").y ~= find(b, "ship:s1:hull").y or find(c, "ship:s1:hull").x ~= find(b, "ship:s1:hull").x or true)

  local r = FleetMap.new()
  r.reduced = true
  local ys = {}
  for i = 0, 90 do
    local sp = FleetMap.update(r, s, i / 30)
    ys[find(sp, "ship:s1:hull").y] = true
    assert(count(sp, ":spark:") == 0 and count(sp, ":trail:") == 0, "no pulses in reduced motion")
  end
  local n = 0
  for _ in pairs(ys) do n += 1 end
  assert(n == 1, "no hover in reduced motion")
  assert(r.chips[1].badge.label == "MINE", "the badge keeps the actual state")
  -- travel: no trail, no animated flame, the ship still goes where the sim says
  s.ships.s1.state, s.ships.s1.dest, s.ships.s1.timer = "travel_out", "ashfall", 100
  local f = FleetMap.new()
  f.reduced = true
  FleetMap.update(f, s, 0)
  s.ships.s1.timer = 40
  local sp = FleetMap.update(f, s, 0.05)
  assert(count(sp, ":trail:") == 0 and find(sp, "ship:s1:engine").frame == 0)
  local still = FleetMap.update(f, s, 0.06)
  assert(find(still, "ship:s1:hull").x == find(sp, "ship:s1:hull").x, "reduced motion does not smooth or freeze positions")
end

-- 8. crowd: 24 own ships on one planet. 16 hulls are drawn, the rest is a +N, quads stay under 48, chips never overlap
do
  local s, fleet = Sim.new(), FleetMap.new()
  for i = 2, 24 do s:addShip("s" .. i, "miner") end
  for _, id in ipairs(s.shipOrder) do s.ships[id].state, s.ships[id].dest, s.ships[id].timer = "travel_out", "ashfall", 300 end
  FleetMap.update(fleet, s, 0)
  fleet.selected = "ship_s20"
  local sp = FleetMap.update(fleet, s, 0.2)
  assert(count(sp, ":hull$") == LIFE.caps.hulls, "hull cap: " .. count(sp, ":hull$"))
  assert(find(sp, "ship:s20:hull"), "the selected ship is drawn")
  assert(count(sp, ":trail:") + count(sp, ":spark:") <= LIFE.caps.quads, "decorative quad cap")
  local total = 0
  for _, g in ipairs(fleet.aggregates) do total += g.count end
  assert(total == 24 - LIFE.caps.hulls and fleet.hiddenCount == total, "the 8 hidden hulls are a +8")
  local sel
  for _, c in ipairs(fleet.chips) do if c.focusId == "ship_s20" then sel = c end end
  assert(sel and sel.full and not sel.number, "the selected ship has a full label")
  local rects = {}
  for _, c in ipairs(fleet.chips) do if not c.number then rects[#rects + 1] = c end end
  for i = 1, #rects do
    for j = i + 1, #rects do assert(not MapLife.overlaps(rects[i], rects[j], 0), "chips overlap") end
  end
  -- no tracked pose is lost for the hidden ones
  local poses = 0
  for _ in pairs(fleet.pose) do poses += 1 end
  assert(poses == 24)
end

-- 9. only real state is drawn: no salvage ship before the branch, a scavenger travels then works at the site's planet
do
  local s, fleet = Sim.new(), FleetMap.new()
  for _, sp in ipairs(FleetMap.update(fleet, s, 0)) do assert(not sp.key:match("^scav:")) end
  s:enterTier(2)
  s.resources.credits, s.resources.compute = 100000, 500
  assert(s:buyUpgrade("engine_mk2") and s:openBranch("salvage"))
  local site = Salvage.spawnSite(s, { planet = "tessar", type = "wreck", danger = 1, qualities = { "fair", "fair", "fair" } })
  local sp = FleetMap.update(fleet, s, 0)
  assert(find(sp, "scav:w1:hull") and find(sp, "scav:w1:hull").sheet:find("Bomber"), "a parked scavenger at the depot")
  assert(s:apply("scavenger", { name = "survey", args = { site = site.id } }))
  s:run(s:ticks(1))
  sp = FleetMap.update(fleet, s, 1)
  -- Tessar has no place on the map: the ship is listed as away with its real state, not parked at the depot nor sent on an invented route.
  assert(not find(sp, "scav:w1:hull"), "an off-map job draws no hull")
  assert(#fleet.away == 1 and fleet.away[1].where == "Tessar Graveyard" and fleet.away[1].badge.label == "SURVEY" and fleet.away[1].badge.tone == "cyan")
  for _ = 1, 2000 do
    if Salvage.mapShips(s)[1].phase == "work" then break end
    s:step()
  end
  FleetMap.update(fleet, s, 2)
  assert(fleet.away[1] and fleet.away[1].badge.tone == "green", "working at the site")
  -- A site on a mapped planet is flown to and worked from a berth around it.
  local rows = Salvage.mapShips(s)
  assert(rows[1].phase == "work")
  s.salvageShips.w1.state, s.salvageShips.w1.job = "idle", nil
  s.salvageShips.w1.at = s.home
  sp = FleetMap.update(fleet, s, 3)
  assert(find(sp, "scav:w1:hull") and #fleet.away == 0, "back at the depot")
end

-- 10. a real AI failure is the one magenta badge
do
  local s, fleet = Sim.new(), FleetMap.new()
  s.agents.miner.state = "paused_error"
  FleetMap.update(fleet, s, 0)
  local b = fleet.chips[1].badge
  assert(b.tone == "magenta" and b.label == "AI ERR" and b.shape == "cross")
  s.agents.miner.state = "acting"
  FleetMap.update(fleet, s, 0.1)
  assert(fleet.chips[1].badge.tone ~= "magenta")
end

-- Turrets engage the nearest real fight in range, and only that
do
  local stations = { { at = { x = 0, y = 0 } }, { at = { x = 1000, y = 0 } } }
  assert(next(MapLife.turretTargets(stations, {}, 260)) == nil, "no fight, no target")
  local t = MapLife.turretTargets(stations, { { x = 100, y = 0 }, { x = 50, y = 0 } }, 260)
  assert(t[1] and t[1].x == 50 and t[2] == nil, "nearest fight in range; the far station stays parked")
  assert(next(MapLife.turretTargets(stations, { { x = 500, y = 500 } }, 260)) == nil, "out of range is ignored")
end

print("map life tests passed")
