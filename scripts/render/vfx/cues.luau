-- One-shot pixel cues (cue sheet GR5-98): credits sparkle, planet unlock burst, turret muzzle flash. Small palette-coloured
-- quads, no assets. Pure: the client feeds it observations (credits, lit planets, turret shots) and a clock, and draws
-- Cues.nodes(). Each cue owns its trigger, so nothing else can raise it, and none of them touches the error glitch.
local Cfg = require("@scripts/config/vfx").cues
local Theme = require("@scripts/config/theme")
local UiTheme = require("@scripts/ui/theme")

local Cues = {}

function Cues.new()
	return { rng = Cfg.seed, particles = {}, lastCredits = nil, creditsAt = nil, lit = nil, planetAt = {}, turretAt = {}, spawned = { credits = 0, planetUnlock = 0, turretFire = 0 } }
end

-- Forget the baselines (a new or loaded game replaces the sim): the next observation only records, it never fires.
function Cues.reset(self)
	self.lastCredits, self.lit = nil, nil
end

local function rand(self): number
	self.rng = (self.rng * 1664525 + 1013904223) % 4294967296
	return self.rng / 4294967296
end

local function between(self, range): number
	return range[1] + rand(self) * (range[2] - range[1])
end

local function colorName(token: string, corp: string?): string
	if token == "$corp" then return Theme.corps[corp or "player"] end
	return token
end

local function add(self, kind: string, cfg, i: number, now: number, x: number, y: number, dx: number, dy: number, travel, corp: string?)
	if #self.particles >= Cfg.maxParticles then return end
	local colors = cfg.colors
	self.particles[#self.particles + 1] = { kind = kind, born = now, life = cfg.life, x = x, y = y, dx = dx, dy = dy,
		dist = between(self, travel), size = math.floor(between(self, cfg.size) + 0.5), color = colorName(colors[(i - 1) % #colors + 1], corp) }
end

-- The credits counter went up. `anchor` = { x, y, w }: where the counter's value is, in view pixels. Gains inside the cooldown
-- are folded into the last sparkle (dropped); a drop in credits (spending) never fires. Returns true when it fired.
function Cues.observeCredits(self, credits: number, now: number, anchor): boolean
	local last = self.lastCredits
	self.lastCredits = credits
	if last == nil or credits <= last then return false end
	local c = Cfg.credits
	if self.creditsAt and now - self.creditsAt < c.cooldown then return false end
	self.creditsAt = now
	self.spawned.credits += 1
	for i = 1, c.count do
		local x = anchor.x + (rand(self) - 0.5) * math.min(anchor.w, c.spread * 2)
		add(self, "credits", c, i, now, x, anchor.y, 0, -1, c.rise)
	end
	return true
end

-- `lit` = planet id -> unlocked. A planet going from locked to unlocked bursts once at its centre; each planet has its own
-- cooldown. `positions` = id -> { x, y } in view pixels, `radius` = the planet disc. Returns the ids that fired.
function Cues.observePlanets(self, lit, positions, radius: number, now: number, corp: string?): { string }
	local fired, last = {}, self.lit
	self.lit = table.clone(lit)
	if last == nil then return fired end
	local c = Cfg.planetUnlock
	local ids = {}
	for id in pairs(lit) do ids[#ids + 1] = id end
	table.sort(ids)
	for _, id in ipairs(ids) do
		local at = positions[id]
		if lit[id] and not last[id] and at and not (self.planetAt[id] and now - self.planetAt[id] < c.cooldown) then
			self.planetAt[id] = now
			self.spawned.planetUnlock += 1
			fired[#fired + 1] = id
			for i = 1, c.count do
				local a = (i - 1 + rand(self) * 0.8) / c.count * 2 * math.pi
				add(self, "planetUnlock", c, i, now, at.x + math.cos(a) * radius, at.y + math.sin(a) * radius, math.cos(a), math.sin(a), c.travel, corp or c.corp)
			end
		end
	end
	return fired
end

-- A turret fires. `key` identifies the turret (its cooldown), (x, y) its centre in view pixels, `size` its drawn frame, `angle`
-- the direction of the shot in degrees (0 = right, 90 = down). Returns true when it fired.
function Cues.turretFire(self, key, x: number, y: number, size: number, angle: number, now: number, corp: string?): boolean
	local c = Cfg.turretFire
	local last = self.turretAt[key]
	if last and now - last < c.cooldown then return false end
	self.turretAt[key] = now
	self.spawned.turretFire += 1
	local a = math.rad(angle)
	local mx, my = x + math.cos(a) * size * c.muzzle, y + math.sin(a) * size * c.muzzle
	for i = 1, c.count do
		local b = a + (rand(self) * 2 - 1) * c.cone
		add(self, "turretFire", c, i, now, mx, my, math.cos(b), math.sin(b), c.travel, corp)
	end
	return true
end

-- Drops the finished quads. True while any is still alive (the shell must keep redrawing).
function Cues.update(self, now: number): boolean
	for i = #self.particles, 1, -1 do
		local p = self.particles[i]
		if now - p.born >= p.life then table.remove(self.particles, i) end
	end
	return #self.particles > 0
end

function Cues.active(self): boolean
	return #self.particles > 0
end

-- UI nodes of the live quads at `now`: absolute, fading with age, ignoring the pointer. Positions snap to whole pixels.
-- `hide` = kind -> true for the cues whose subject is not on screen (the planets and turrets only exist on the map).
function Cues.nodes(self, now: number, hide)
	local out = {}
	for _, p in ipairs(self.particles) do
		local k = (now - p.born) / p.life
		if k >= 0 and k < 1 and not (hide and hide[p.kind]) then
			local moved = p.dist * (1 - (1 - k) * (1 - k))
			out[#out + 1] = { style = { position = "absolute", left = math.floor(p.x + p.dx * moved - p.size / 2 + 0.5), top = math.floor(p.y + p.dy * moved - p.size / 2 + 0.5),
				width = p.size, height = p.size, ignorePointer = true }, background = { color = UiTheme.color(p.color, 1 - k) } }
		end
	end
	return out
end

-- The UI tree of the quads (a transparent full-view layer of nodes), or nil when none is drawn.
function Cues.spec(self, now: number, view, hide)
	local nodes = Cues.nodes(self, now, hide)
	if #nodes == 0 then return nil end
	return { style = { position = "absolute", left = 0, top = 0, width = view.w, height = view.h, ignorePointer = true }, children = nodes }
end

-- The one live state of the windowed client: client/station_fx.luau (turret shots) and client/main.luau (the rest, and the drawing)
-- share it. Tests build their own with Cues.new().
Cues.shared = Cues.new()

return Cues
