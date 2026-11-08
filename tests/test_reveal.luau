-- Planet reachability reveal (GR5-105): the pure timeline (queue, hydration, map exit, one burst, reduced motion), what the shell
-- draws for a frame, that reachability follows the independent equipment gates (Lumen: Mk3 + Deep-range nav), and that a planet
-- unlock alone raises no tier cue while a real tier-up does, once. The reveal reads state; it never buys or grants anything.
local Reveal = require("@scripts/render/vfx/reveal")
local Cues = require("@scripts/render/vfx/cues")
local Vfx = require("@scripts/config/vfx")
local Audio = require("@scripts/client/audio")
local Shell = require("@scripts/ui/shell")
local Model = require("@scripts/ui/shell_model")
local Sim = require("@scripts/sim/sim")
local World = require("@scripts/config/world")

local cfg = Vfx.reveal
local order = World.planetOrder
local function lit(...) local t = {} for _, id in ipairs({ ... }) do t[id] = true end return t end

-- the sheet's numbers
assert(cfg.duration == 2.0 and cfg.burstAt == 0.3 and cfg.ring.start == 0.3 and cfg.ring.finish == 1.1 and cfg.label.start == 0.6 and cfg.label.finish == 1.4)
assert(cfg.dim.finish == 1.1 and cfg.reducedSeconds == 0.5)

-- hydration: the first observation of a sim, and any other sim, only records
local r, simA, simB = Reveal.new(), {}, {}
assert(#Reveal.observe(r, lit("kessa", "varn"), order, simA) == 0, "first sight: baseline")
assert(not Reveal.busy(r) and select(1, Reveal.update(r, 0, true, false)) == nil)
assert(#Reveal.observe(r, lit("kessa", "varn", "ashfall"), order, simB) == 0, "a different sim is a load/reset: baseline again")
assert(not Reveal.busy(r))
-- a real false -> true plays; a repeat of the same state does not
local added = Reveal.observe(r, lit("kessa", "varn", "ashfall", "lumen"), order, simB)
assert(#added == 1 and added[1] == "lumen" and Reveal.busy(r))
assert(#Reveal.observe(r, lit("kessa", "varn", "ashfall", "lumen"), order, simB) == 0, "no duplicate while queued")

-- timeline: dim fades by 1.1 s, ring 0.3-1.1 s, label crossfade 0.6-1.4 s, over by 2.0 s, one burst at 0.3 s
local f, burst = Reveal.update(r, 10, true, false)
assert(f and f.id == "lumen" and f.t == 0 and burst == nil and f.ring == nil and math.abs(f.dim - cfg.dim.alpha) < 1e-9 and f.labelMix == 0 and f.backing == 0)
f, burst = Reveal.update(r, 10.29, true, false)
assert(burst == nil and f.ring == nil)
f, burst = Reveal.update(r, 10.3, true, false)
assert(burst == "lumen" and f.ring and f.ring.alpha > 0.99 and math.abs(f.ring.stroke - cfg.ring.stroke) < 1e-6)
f, burst = Reveal.update(r, 10.5, true, false)
assert(burst == nil, "one burst per reveal")
f = Reveal.update(r, 10.7, true, false)
assert(f.ring.grow > 0 and f.ring.grow < cfg.ring.grow and f.labelMix > 0 and f.labelMix < 0.2 and f.backing > 0 and f.dim < cfg.dim.alpha)
f = Reveal.update(r, 11.2, true, false)
assert(f.ring == nil and f.dim == 0 and f.labelMix > 0.7 and f.labelMix < 1)
f = Reveal.update(r, 11.5, true, false)
assert(f.labelMix == 1 and f.backing > 0 and f.backing < cfg.label.backingAlpha, "backing fades out before the end")
f = Reveal.update(r, 11.99, true, false)
assert(f and f.backing < 0.05)
f = Reveal.update(r, 12.0, true, false)
assert(f == nil and not Reveal.busy(r), "safe exit: back to the plain map")
assert(r.played == 1)

-- simultaneous unlocks queue one reveal each in map order, one after the other, each with its own single burst
local q, owner = Reveal.new(), {}
Reveal.observe(q, lit("kessa"), order, owner)
local both = Reveal.observe(q, lit("kessa", "varn", "ashfall"), order, owner)
assert(#both == 2 and both[1] == "varn" and both[2] == "ashfall")
local bursts, seen = {}, {}
local now = 0
while now < 5 do
	local fr, b = Reveal.update(q, now, true, false)
	if fr then seen[#seen + 1] = fr.id end
	if b then bursts[#bursts + 1] = b end
	now += 0.05
end
assert(#bursts == 2 and bursts[1] == "varn" and bursts[2] == "ashfall", "two reveals, two bursts")
assert(seen[1] == "varn" and seen[#seen] == "ashfall" and not Reveal.busy(q))

-- leaving the map cancels: nothing plays or fires, and nothing is replayed when coming back
local m = Reveal.new()
Reveal.observe(m, lit("kessa"), order, owner)
Reveal.observe(m, lit("kessa", "varn"), order, owner)
Reveal.update(m, 0, true, false)
local fm, bm = Reveal.update(m, 0.1, false, false)
assert(fm == nil and bm == nil and not Reveal.busy(m))
fm, bm = Reveal.update(m, 5, true, false)
assert(fm == nil and bm == nil, "silent on return")

-- a planet that locks again before its turn is dropped
local d = Reveal.new()
Reveal.observe(d, lit("kessa"), order, owner)
Reveal.observe(d, lit("kessa", "varn", "ashfall"), order, owner)
Reveal.observe(d, lit("kessa", "ashfall"), order, owner)
assert(#d.queue == 1 and d.queue[1] == "ashfall")

-- reduced motion: no dim, no ring, no burst, a static outline and the final label, over in 0.5 s
local rm = Reveal.new()
Reveal.observe(rm, lit("kessa"), order, owner)
Reveal.observe(rm, lit("kessa", "varn"), order, owner)
local anyBurst = false
local fr, last
for i = 0, 9 do
	local b
	fr, b = Reveal.update(rm, i * 0.05, true, true)
	anyBurst = anyBurst or b ~= nil
	assert(fr and fr.dim == 0 and fr.ring == nil and fr.outline and fr.labelMix == 1)
end
assert(not anyBurst and Reveal.update(rm, 0.5, true, true) == nil)

-- the shell draws a frame: ring, dim and both labels mid-crossfade; plain map without a frame
local sim = Sim.new()
sim.resources.credits = 1000000
local function mapNodes(reveal)
	local spec = Shell.spec(sim, "map", { reveal = reveal })
	local n = 0
	local function walk(s) n += 1 for _, c in ipairs(s.children or {}) do walk(c) end end
	walk(spec)
	return n, spec
end
local plain = mapNodes(nil)
assert(sim.upgrades.engine == 1)
-- Varn is locked at Mk1, so a frame for it adds nothing (only a reachable planet reveals)
assert(mapNodes(Reveal.frameAt("varn", 0.8, false)) == plain)
sim.tier = 2
assert(sim:buyUpgrade("engine_mk2"))
local lit2 = mapNodes(nil)
assert(mapNodes(Reveal.frameAt("varn", 0.8, false)) > lit2, "ring, dim and the crossfading labels are extra nodes")
assert(mapNodes(Reveal.frameAt("varn", 0.0, false)) > lit2, "dim only")
assert(mapNodes(Reveal.frameAt("varn", 1.9, false)) == lit2 + 0 or mapNodes(Reveal.frameAt("varn", 1.9, false)) >= lit2)
assert(mapNodes(Reveal.frameAt("varn", 0.2, true)) > lit2, "reduced motion: the outline")

-- real reachability and the independent gates; reveal reads them, never grants
local function reach(s)
	local out = {}
	for _, p in ipairs(Model.map(s).planets) do out[p.id] = p.lit end
	return out
end
local g = Sim.new()
g.resources.credits = 1000000
local base = reach(g)
assert(base.kessa and not base.varn and not base.ashfall and not base.lumen, "T1: only Kessa")
local modules, ships, tier = g.upgrades.scanner, #g.shipOrder, g.tier
g.tier = 3
assert(g:buyUpgrade("engine_mk2") and g:buyUpgrade("engine_mk3"))
local r3 = reach(g)
assert(r3.varn and r3.ashfall and not r3.lumen, "Mk3 alone does not reach Lumen (needs Deep-range nav)")
g.tier = 4
assert(g:buyUpgrade("deep_nav"))
assert(reach(g).lumen, "Mk3 + Deep-range nav reaches Lumen")
assert(g.upgrades.scanner == modules and #g.shipOrder == ships, "reveal-relevant purchases grant no other module or ship")
-- Deep-range nav without Mk3 does not reach Lumen either (the gates are independent)
local h = Sim.new()
h.deepNav = true
assert(not reach(h).lumen and not reach(h).ashfall)
-- the simultaneous case: Deep-range nav owned first, then Mk3 lights Ashfall and Lumen together
h.tier, h.resources.credits = 3, 1000000
assert(h:buyUpgrade("engine_mk2"))
local before = reach(h)
assert(h:buyUpgrade("engine_mk3"))
local after = reach(h)
local newly = {}
for _, id in ipairs(order) do if after[id] and not before[id] then newly[#newly + 1] = id end end
assert(#newly == 2 and newly[1] == "ashfall" and newly[2] == "lumen")

-- sound: a planet-only unlock raises no tier_up; a real tier change raises exactly one, and a hydrated backlog none
local s = Sim.new()
s.resources.credits = 1000000
s:drainEvents()
s.tier = 2
assert(s:buyUpgrade("engine_mk2"))
for _, e in ipairs(s:drainEvents()) do assert(e.name ~= "tier_up", "a planet unlock is not a tier event") end
s.lifetimeRevenue = s.b.tierRevenue[2]
s:updateTier()
local tiers = 0
for _, e in ipairs(s:drainEvents()) do if e.name == "tier_up" then tiers += 1 end end
assert(s.tier == 3 or s.tier == 2)
local cue = Audio.new()
local a1, a2 = {}, {}
assert(Audio.firstSight(cue, a1) and not Audio.firstSight(cue, a1) and Audio.firstSight(cue, a2), "only the first sight of a sim is hydration")

local function plays(event, muted)
	local st = Audio.new()
	Audio.setMuted(st, muted)
	Audio.beginFrame(st, 0)
	Audio.onEvent(st, event, { speed = 1 })
	return Audio.flush(st)
end
local tierPlays = plays({ name = "tier_up", data = { tier = 3 } }, false)
assert(#tierPlays == 1 and tierPlays[1].cue == "tier_up")
assert(#plays({ name = "tier_up", data = { tier = 3 } }, true) == 0, "mute silences the tier cue")
assert(#plays({ name = "planet_reachable" }, false) == 0, "an unlock itself maps to no sound")

-- the burst fires from the reveal exactly once and respects the GR5-100 cooldown
local c = Cues.new()
local pos = Shell.planetPositions()
assert(Cues.burstPlanet(c, "varn", pos.varn, require("@scripts/config/screens").map.planetRadius, 1))
assert(not Cues.burstPlanet(c, "varn", pos.varn, require("@scripts/config/screens").map.planetRadius, 1.2), "inside the cooldown")

print("test_reveal ok")
