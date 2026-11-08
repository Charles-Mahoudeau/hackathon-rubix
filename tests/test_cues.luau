-- One-shot cue sheet (GR5-100): credits sparkle, planet unlock burst, turret muzzle flash. Count, size, lifetime, palette,
-- placement and cooldown of each, that only its own event raises it, and that the error glitch stays exclusive to AI errors.
local Cues = require("@scripts/render/vfx/cues")
local Glitch = require("@scripts/render/vfx/glitch")
local Vfx = require("@scripts/config/vfx")
local Theme = require("@scripts/config/theme")
local Stations = require("@scripts/client/stations")
local Remap = require("@scripts/client/remap")
local stationsConfig = require("@scripts/config/stations")
local Shell = require("@scripts/ui/shell")
local Screens = require("@scripts/config/screens")
local Sim = require("@scripts/sim/sim")
local Model = require("@scripts/ui/shell_model")

local assets = { shader = function(path) return "shader:" .. path end, texture = function(path) return "texture:" .. path end, material = function(def) return def end }
Remap.assets, Stations.assets = assets, assets

local cfg = Vfx.cues
for _, m in { Cues } do table.freeze(m) end -- the engine freezes returned module tables

local function count(c, kind) local n = 0 for _, p in ipairs(c.particles) do if p.kind == kind then n += 1 end end return n end
local function inRange(v, r) return v >= r[1] and v <= r[2] end

-- the sheet's numbers, as configured
assert(cfg.credits.count == 6 and cfg.credits.life == 0.4 and cfg.credits.cooldown == 0.5)
assert(cfg.planetUnlock.count == 12 and cfg.planetUnlock.life == 0.8 and cfg.planetUnlock.cooldown == 1.0)
assert(cfg.turretFire.count == 4 and cfg.turretFire.life == 0.15 and cfg.turretFire.cooldown == 0.1)
for name, c in pairs({ credits = cfg.credits, planetUnlock = cfg.planetUnlock, turretFire = cfg.turretFire }) do
	assert(c.size[1] >= 2 and c.size[2] <= (name == "planetUnlock" and 4 or 3), name .. ": quad size in px")
	for _, color in ipairs(c.colors) do assert(color == "$corp" or Theme.palette[color], name .. ": palette role " .. color) end
end

-- credits: 6 quads of 2-3 px around the counter, rising 8-12 px over 0.4 s, 500 ms global cooldown, gains coalesce
local anchor = Shell.creditsAnchor("1,250 cr")
local c = Cues.new()
assert(not Cues.observeCredits(c, 500, 0, anchor), "the first reading is a baseline, not a gain")
assert(not Cues.observeCredits(c, 400, 1, anchor), "spending never sparkles")
assert(not Cues.observeCredits(c, 400, 2, anchor), "no change, no sparkle")
assert(Cues.observeCredits(c, 450, 3, anchor) and count(c, "credits") == 6)
for _, p in ipairs(c.particles) do
	assert(inRange(p.size, cfg.credits.size) and p.life == 0.4 and p.dx == 0 and p.dy == -1 and inRange(p.dist, cfg.credits.rise))
	assert(math.abs(p.x - anchor.x) <= anchor.w / 2 and p.y == anchor.y, "around the credits counter")
	assert(p.color == "green" or p.color == "text")
end
assert(not Cues.observeCredits(c, 460, 3.3, anchor) and count(c, "credits") == 6, "inside 500 ms: coalesced, dropped")
assert(Cues.observeCredits(c, 470, 3.6, anchor) and count(c, "credits") == 12, "after the cooldown it fires again")
assert(Cues.update(c, 3.39) and #c.particles == 12, "alive before 0.4 s")
assert(Cues.update(c, 3.5) and #c.particles == 6, "the first sparkle is gone after 0.4 s")
assert(not Cues.update(c, 4.1) and #c.particles == 0 and not Cues.active(c), "and the second")
Cues.reset(c)
assert(not Cues.observeCredits(c, 9999, 10, anchor), "a loaded game re-baselines instead of sparkling")
-- the anchor sits in the top bar, to the right of the title
local top = Shell.layout().top
assert(anchor.x > top.x and anchor.y > top.y and anchor.y < top.y + top.h)

-- planet unlock: 12 quads, 2-4 px, radial from the planet, 12-24 px over 0.8 s, once per planet per second, never at load
local positions = Shell.planetPositions()
local r = Screens.map.planetRadius
local p = Cues.new()
assert(#Cues.observePlanets(p, { kessa = true, varn = false }, positions, r, 0) == 0 and #p.particles == 0, "baseline: already lit planets do not burst")
assert(#Cues.observePlanets(p, { kessa = true, varn = false }, positions, r, 1) == 0, "nothing changed")
local fired = Cues.observePlanets(p, { kessa = true, varn = true }, positions, r, 2)
assert(#fired == 1 and fired[1] == "varn" and count(p, "planetUnlock") == 12)
for _, q in ipairs(p.particles) do
	assert(inRange(q.size, cfg.planetUnlock.size) and q.life == 0.8 and inRange(q.dist, cfg.planetUnlock.travel))
	local ex, ey = q.x - positions.varn.x, q.y - positions.varn.y
	assert(math.abs(math.sqrt(ex * ex + ey * ey) - r) < 1e-6 and math.abs(ex * q.dy - ey * q.dx) < 1e-6, "radial, at the planet")
	assert(q.color == Theme.corps.player or q.color == "text")
end
assert(#Cues.observePlanets(p, { kessa = true, varn = true }, positions, r, 2.2) == 0, "already lit: no second burst")
Cues.observePlanets(p, { kessa = true, varn = false }, positions, r, 2.3) -- a reset save relocks it
assert(#Cues.observePlanets(p, { kessa = true, varn = true }, positions, r, 2.5) == 0 and count(p, "planetUnlock") == 12, "per-planet cooldown 1 s")
assert(#Cues.observePlanets(p, { kessa = true, varn = false }, positions, r, 3.2) == 0)
assert(#Cues.observePlanets(p, { kessa = true, varn = true }, positions, r, 3.3) == 1, "after 1 s it can burst again")
assert(#Cues.observePlanets(p, { kessa = true, varn = true, ashfall = false }, positions, r, 9) == 0)
assert(#Cues.observePlanets(p, { kessa = true, varn = true, ashfall = true }, positions, r, 9.05) == 1, "another planet is independent")

-- turret fire: 4 quads, 2-3 px, from the muzzle along the shot, 4-8 px over 0.15 s, 100 ms per turret
local t = Cues.new()
assert(Cues.turretFire(t, "a", 100, 100, 96, 0, 1, "player") and count(t, "turretFire") == 4)
for _, q in ipairs(t.particles) do
	assert(inRange(q.size, cfg.turretFire.size) and q.life == 0.15 and inRange(q.dist, cfg.turretFire.travel))
	assert(math.abs(q.x - (100 + 96 * cfg.turretFire.muzzle)) < 1e-6 and q.dx > 0.9, "at the muzzle, along the shot (right)")
	assert(q.color == Theme.corps.player or q.color == "text")
end
assert(not Cues.turretFire(t, "a", 100, 100, 96, 0, 1.05, "player"), "inside 100 ms: same turret refused")
assert(Cues.turretFire(t, "b", 100, 100, 96, 90, 1.05, "rivalA") and t.particles[5].dy > 0.9, "another turret is independent; 90 degrees = down")
assert(t.particles[5].color == Theme.corps.rivalA or t.particles[5].color == "text")
assert(Cues.turretFire(t, "a", 100, 100, 96, 0, 1.11, "player"), "after 100 ms the turret fires again")
assert(not Cues.update(t, 2) and #t.particles == 0, "all gone after 0.15 s")

-- nodes: absolute, fading, pointer-transparent, in palette colours only; the map cues are hidden off the map
local n = Cues.new()
Cues.observeCredits(n, 1, 0, anchor)
Cues.observeCredits(n, 2, 1, anchor)
Cues.turretFire(n, "a", 300, 300, 96, 0, 1)
local early, late = Cues.nodes(n, 1.02), Cues.nodes(n, 1.3)
assert(#early == 6 + 4 and #late == 6, "the muzzle flash is over after 0.15 s")
for _, node in ipairs(early) do
	assert(node.style.position == "absolute" and node.style.ignorePointer and node.style.width >= 2 and node.style.width <= 3)
end
assert(early[1].background.color[4] > late[1].background.color[4], "quads fade with age")
assert(#Cues.nodes(n, 1.02, { turretFire = true }) == 6 and #Cues.nodes(n, 1.02, { turretFire = true, planetUnlock = true, credits = true }) == 0)
assert(Cues.spec(n, 5, Theme.layout.view) == nil, "no quads, no layer")
assert(Cues.spec(n, 1.02, Theme.layout.view).style.ignorePointer)

-- the cooldown and spawn counters feed no sim state, and the stream is deterministic
local a, b = Cues.new(), Cues.new()
for _, c2 in { a, b } do Cues.observeCredits(c2, 1, 0, anchor); Cues.observeCredits(c2, 2, 1, anchor) end
for i = 1, 6 do assert(a.particles[i].x == b.particles[i].x and a.particles[i].size == b.particles[i].size) end

-- turret shots come from the animation: one per firing loop, at its first frame, nothing while idle or opening
for kind in pairs(stationsConfig.turrets.kinds) do
	local length, starts = #Stations.turretSequence(kind), 0
	for f = 0, length - 1 do
		if Stations.isFireStart(kind, f) then starts += 1 end
		if f < stationsConfig.turrets.idleHold * stationsConfig.turrets.fps then assert(not Stations.isFireStart(kind, f), kind .. ": idle never fires") end
	end
	assert(starts == stationsConfig.turrets.fireLoops, kind .. ": one shot per fire loop")
	assert(Stations.isFireStart(kind, 3 * length + 1) == Stations.isFireStart(kind, 1), kind .. ": the cycle repeats")
end

-- the turret entity carries the outward aim and its station's corporation
assert(Stations.aimOf(0, -62) == 270 and Stations.aimOf(10, 0) == 0 and Stations.aimOf(0, 5) == 90 and Stations.aimOf(-3, 0) == 180 and Stations.aimOf(0, 0) == 270)
local depot = {}
for _, stage in ipairs(stationsConfig.stations.hmc_depot.stages or {}) do depot[stage.when] = true end
for _, e in ipairs(Stations.entities("orbis_exchange", "idle", { x = 0, y = 0 }, 1, nil, nil)) do
	local tc = e["game.StationTurret"]
	if tc then assert(Stations.corpNames[tc.corp] == "rivalA" and tc.aim >= 0 and tc.aim < 360) end
end
local seen = 0
for _, e in ipairs(Stations.entities("hmc_depot", "active", { x = 0, y = 0 }, 1, nil, depot)) do
	local tc = e["game.StationTurret"]
	if tc then seen += 1; assert(Stations.corpNames[tc.corp] == "player") end
end
assert(seen > 0)

-- the error glitch stays exclusive to AI errors: none of these cues touches it, and it still refuses everything else
local g = Glitch.new()
local credits = Cues.new()
Cues.observeCredits(credits, 1, 0, anchor); Cues.observeCredits(credits, 2, 1, anchor)
Cues.turretFire(credits, "a", 0, 0, 96, 0, 1)
Cues.observePlanets(credits, { kessa = false }, positions, r, 1); Cues.observePlanets(credits, { kessa = true }, positions, r, 2)
assert(not Glitch.isActive(g) and not Glitch.trigger(g, "credits") and not Glitch.trigger(g, "planet_unlock") and not Glitch.trigger(g, "turret_fire"))
assert(Shell.onSimEvent(Shell.new(), { name = "tier_up" }) == false and Shell.onSimEvent(Shell.new(), { name = "freighter_delivered" }) == false)
assert(Shell.onSimEvent(Shell.new(), { name = "agent_paused_error" }) == true)
assert(next(Vfx.glitch.allowedSources) == "ai_error" and next(Vfx.glitch.allowedSources, "ai_error") == nil)

-- the real sim: delivering ore raises credits (the sparkle), unlocking a planet flips Model.map lit (the burst)
local sim = Sim.new()
local live = Cues.new()
local function lit() local out = {} for _, pl in ipairs(Model.map(sim).planets) do out[pl.id] = pl.lit end return out end
Cues.observeCredits(live, sim.resources.credits, 0, anchor)
Cues.observePlanets(live, lit(), positions, r, 0)
sim.resources.credits += 100
assert(Cues.observeCredits(live, sim.resources.credits, 1, anchor), "a gain in the sim sparkles")
assert(#Cues.observePlanets(live, lit(), positions, r, 1) == 0, "a gain does not burst a planet")
assert(not lit().varn, "Varn is locked with the base engine")
for _, id in ipairs(sim.shipOrder) do sim.ships[id].engineMark = 2 end
local burst = Cues.observePlanets(live, lit(), positions, r, 2)
assert(#burst == 1 and burst[1] == "varn", "a better engine lights Varn: one burst, only there")
print("cues OK")
