-- Planet reachability reveal (GR5-105): a pure timeline over the lit/locked state of the planets. The client feeds it the
-- reachability it observes and the clock, and draws the frame it returns (ui/shell.luau) plus the GR5-100 burst.
-- It reads state and never changes it: the sim keeps every unlock rule, ship, module and branch.
-- Triggers: only a planet going locked -> reachable after the first observation of a sim (a loaded, reset or new game
-- records its baseline and plays nothing). Planets that unlock together queue one reveal each, in the map order given.
local Cfg = require("@scripts/config/vfx").reveal

local Reveal = {}

function Reveal.new()
	return { lit = nil, owner = nil, queue = {}, active = nil, played = 0 }
end

-- The sim was replaced (new game, load, reset): the next observation only records.
function Reveal.reset(self)
	self.lit, self.owner, self.queue, self.active = nil, nil, {}, nil
end

local function queued(self, id: string): boolean
	if self.active and self.active.id == id then return true end
	for _, q in ipairs(self.queue) do
		if q == id then return true end
	end
	return false
end

local function drop(self, id: string)
	for i = #self.queue, 1, -1 do
		if self.queue[i] == id then table.remove(self.queue, i) end
	end
	if self.active and self.active.id == id then self.active = nil end
end

-- `lit` = planet id -> reachable, `order` = the ids in map order, `owner` = the sim being watched: a different one than last time
-- (new game, load, reset) is hydration, it only records. Returns the ids newly queued.
function Reveal.observe(self, lit, order: { string }, owner): { string }
	if owner ~= self.owner then Reveal.reset(self) end
	self.owner = owner
	local added, last = {}, self.lit
	local copy = {}
	for _, id in ipairs(order) do copy[id] = lit[id] == true end
	self.lit = copy
	if last == nil then return added end
	for _, id in ipairs(order) do
		if copy[id] and not last[id] and not queued(self, id) then
			self.queue[#self.queue + 1] = id
			added[#added + 1] = id
		elseif not copy[id] then
			drop(self, id) -- unreachable again before its turn: nothing to reveal
		end
	end
	return added
end

local function span(t: number, from: number, to: number): number
	if t <= from then return 0 end
	if t >= to then return 1 end
	return (t - from) / (to - from)
end

-- The frame at `t` seconds into a reveal. Fields: id, t, dim (0..1 alpha of the dimmed look), ring = { grow px past the planet edge,
-- alpha, stroke } or nil, outline = true for the static reduced-motion outline, labelMix (0 = locked label, 1 = revealed label),
-- backing = alpha of the panel behind the label (in while the label changes, out before the reveal ends).
function Reveal.frameAt(id: string, t: number, reduced: boolean)
	if reduced then
		return { id = id, t = t, dim = 0, ring = nil, outline = true, labelMix = 1, backing = Cfg.label.backingAlpha }
	end
	local ring
	local r = Cfg.ring
	if t >= r.start and t < r.finish then
		local k = span(t, r.start, r.finish)
		ring = { grow = r.grow * (1 - (1 - k) * (1 - k)), alpha = 1 - k, stroke = r.stroke + (r.endStroke - r.stroke) * k }
	end
	local l = Cfg.label
	local backing = l.backingAlpha * math.min(span(t, l.start, l.start + 0.2), 1 - span(t, l.finish, Cfg.duration))
	return { id = id, t = t, dim = Cfg.dim.alpha * (1 - span(t, 0, Cfg.dim.finish)), ring = ring, outline = false,
		labelMix = span(t, l.start, l.finish), backing = backing }
end

-- Advances the timeline to `now` (real seconds). `onMap` false cancels what is playing and queued (leaving the Map: the
-- planets simply show their reachable look when it comes back). -> frame or nil, burst id or nil (fires once per reveal).
function Reveal.update(self, now: number, onMap: boolean, reduced: boolean?)
	if not onMap then
		self.queue, self.active = {}, nil
		return nil, nil
	end
	local length = reduced and Cfg.reducedSeconds or Cfg.duration
	if self.active and now - self.active.at >= length then self.active = nil end
	if not self.active and #self.queue > 0 then
		self.active = { id = table.remove(self.queue, 1), at = now, burst = false }
		self.played += 1
	end
	local a = self.active
	if not a then return nil, nil end
	local t = now - a.at
	local burst
	if not reduced and not a.burst and t >= Cfg.burstAt then
		a.burst, burst = true, a.id
	end
	return Reveal.frameAt(a.id, t, reduced == true), burst
end

function Reveal.busy(self): boolean
	return self.active ~= nil or #self.queue > 0
end

return Reveal
