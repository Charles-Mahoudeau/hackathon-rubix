-- Map life (GR5-104): the pure rules behind the ship and station choreography of GR5-103. Everything here is a function of
-- the sim's published state; nothing invents a route, an event or an actor. Client only, headless-testable.
--   MapLife.status(kind, ...)   -> the state badge of a ship or station: { tone, shape, label, alert }
--   MapLife.berths(...)         -> stable parking slots around an anchor that keep their distance from labels and stations
--   MapLife.budget(actors, ...) -> which hulls are drawn (cap, priority) and the `+N` aggregates of the rest
--   MapLife.place(...)          -> a label rectangle next to an anchor that overlaps nothing reserved
--   MapLife.reveal*             -> the ~2 s reachability reveal, queued in map order
local Config = require("@scripts/config/ships")

local MapLife = {}

local LIFE = Config.map_fx.life

-- Rectangles ({ x, y, w, h }) -------------------------------------------------------------------------------------------

function MapLife.overlaps(a, b, gap: number?)
	local g = gap or 0
	return a.x < b.x + b.w + g and b.x < a.x + a.w + g and a.y < b.y + b.h + g and b.y < a.y + a.h + g
end

local function hits(rect, reserved, gap: number)
	for _, r in ipairs(reserved) do
		if MapLife.overlaps(rect, r, gap) then return true end
	end
	return false
end

local function inside(rect, bounds)
	return rect.x >= bounds.x and rect.y >= bounds.y and rect.x + rect.w <= bounds.x + bounds.w and rect.y + rect.h <= bounds.y + bounds.h
end

-- A w x h box next to `anchor` (a rect): above, right, below, then left. Returns the first one inside `bounds` that clears
-- every reserved rect by `gap`, else nil (the caller falls back to a numbered marker).
function MapLife.place(w: number, h: number, anchor, reserved, bounds, gap: number?)
	local g, pad = gap or LIFE.clear.label, 2
	local cx = anchor.x + anchor.w / 2 - w / 2
	local cy = anchor.y + anchor.h / 2 - h / 2
	local options = {
		{ x = cx, y = anchor.y - h - pad },
		{ x = anchor.x + anchor.w + pad, y = cy },
		{ x = cx, y = anchor.y + anchor.h + pad },
		{ x = anchor.x - w - pad, y = cy },
	}
	for _, o in ipairs(options) do
		local rect = { x = o.x, y = o.y, w = w, h = h }
		if inside(rect, bounds) and not hits(rect, reserved, g) then return rect end
	end
	return nil
end

-- Berths ----------------------------------------------------------------------------------------------------------------

-- `count` parking slots around `anchor`, ring by ring from `radius` outwards. Hulls are `hull` px wide and keep `clear` px
-- between each other, so a ring of radius r holds floor(pi / asin(spacing / 2r)) slots (the chord, not the arc, keeps the gap). A slot whose hull box would touch a
-- reserved rect (a label, a station) or leave `bounds` is skipped, so the same inputs always give the same slots.
function MapLife.berths(anchor, radius: number, count: number, hull: number, reserved, bounds)
	local out = {}
	local spacing = hull + LIFE.clear.hull
	local r = radius
	local guard = 0
	while #out < count and guard < 12 do
		local n = spacing >= 2 * r and 1 or math.max(1, math.floor(math.pi / math.asin(spacing / (2 * r))))
		for i = 0, n - 1 do
			local a = LIFE.berth.start + i * 2 * math.pi / n + guard * 0.35
			local x, y = anchor.x + math.cos(a) * r, anchor.y + math.sin(a) * r
			local box = { x = x - hull / 2, y = y - hull / 2, w = hull, h = hull }
			if inside(box, bounds) and not hits(box, reserved, LIFE.clear.station) then
				out[#out + 1] = { x = x, y = y, rot = a + math.pi / 2 }
				if #out == count then return out end
			end
		end
		r += spacing
		guard += 1
	end
	-- Nowhere is free: stack on the ring rather than lose the ship (it is aggregated by the budget when the map is full).
	while #out < count do out[#out + 1] = { x = anchor.x + radius, y = anchor.y, rot = 0 } end
	return out
end

-- Status badges -----------------------------------------------------------------------------------------------------------

-- tone: a palette role (moving cyan, working green, waiting dim, warning amber, error magenta); shape and label make the
-- state readable without colour. alert: shown ahead of everything else and never aggregated away.
local BADGES = {
	moving = { tone = "cyan", shape = "circle", label = "MOVE" },
	working = { tone = "green", shape = "square", label = "WORK" },
	waiting = { tone = "dim", shape = "ring", label = "WAIT" },
	docked = { tone = "dim", shape = "ring", label = "DOCK" },
	warning = { tone = "amber", shape = "bar", label = "WARN", alert = true },
	error = { tone = "magenta", shape = "cross", label = "AI ERR", alert = true },
	combat = { tone = "amber", shape = "bar", label = "FIGHT", alert = true },
}

function MapLife.badge(kind: string, label: string?)
	local b = BADGES[kind]
	assert(b, "MapLife: unknown badge '" .. tostring(kind) .. "'")
	return { kind = kind, tone = b.tone, shape = b.shape, label = label or b.label, alert = b.alert == true }
end

-- The badge of an agent-driven actor: a real AI failure is magenta, a real block is amber, otherwise the actor's own state.
-- `agent` is a sim agent (or nil); `base` is the badge kind of the ship's own state.
function MapLife.agentBadge(agent, base: string, label: string?)
	if agent and agent.state == "paused_error" then return MapLife.badge("error", "AI ERR") end
	if agent and agent.state == "no_compute" then return MapLife.badge("warning", "NO CU") end
	return MapLife.badge(base, label)
end

-- Budget -----------------------------------------------------------------------------------------------------------------

local function priority(a, selected: string?, from)
	if a.focusId == selected then return 0 end
	if a.badge and a.badge.alert or a.combat then return 1 end
	if a.corp == "player" then return 2 end
	local dx, dy = a.x - from.x, a.y - from.y
	return 3 + math.sqrt(dx * dx + dy * dy) / 10000
end

-- Which hulls are drawn. `actors` carry { key, focusId, corp, x, y, badge, combat, anchor = { id, x, y } }. Selected first,
-- then alerts and combat, then the player's own, then the nearest others to `from`; stable on ties. Beyond `cap` an actor
-- is not drawn but is counted in the aggregate of its anchor: { id, x, y, count, names }. `ranked` is the drawn actors in priority order. Nothing is ever dropped silently.
function MapLife.budget(actors, selected: string?, from, cap: number?)
	local limit = cap or LIFE.caps.hulls
	local order = {}
	for i, a in ipairs(actors) do order[i] = { a = a, p = priority(a, selected, from), i = i } end
	table.sort(order, function(x, y)
		if x.p ~= y.p then return x.p < y.p end
		return x.i < y.i
	end)
	local shown, hidden, groups, list, ranked = {}, {}, {}, {}, {}
	for rank, o in ipairs(order) do
		if rank <= limit then
			shown[o.a.key] = true
			ranked[#ranked + 1] = o.a
		else
			hidden[o.a.key] = true
			local anchor = o.a.anchor or { id = o.a.key, x = o.a.x, y = o.a.y }
			local g = groups[anchor.id]
			if not g then
				g = { id = anchor.id, x = anchor.x, y = anchor.y, count = 0, names = {} }
				groups[anchor.id] = g
				list[#list + 1] = g
			end
			g.count += 1
			g.names[#g.names + 1] = o.a.key
		end
	end
	return { shown = shown, hidden = hidden, aggregates = list, ranked = ranked }
end

-- Takes decorative quads in priority order: returns how many of `want` the actor may draw and the remaining budget.
function MapLife.quads(left: number, want: number): (number, number)
	local n = math.max(0, math.min(want, left))
	return n, left - n
end

-- Station turrets -----------------------------------------------------------------------------------------------------

-- Which station turrets engage: `stations` are { at = {x, y} } (the list SystemMap.stations gives), `fights` the positions of
-- the real raid fights ({ x, y }). A station reacts to the nearest fight within `range` px; with no fight nothing is returned,
-- so a turret never fires on its own. { [index in stations] = { x, y } }.
function MapLife.turretTargets(stations, fights, range: number?)
	local reach, out = range or LIFE.turret.range, {}
	for i, st in ipairs(stations) do
		local best, bestD = nil, reach
		for _, f in ipairs(fights) do
			local d = math.sqrt((f.x - st.at.x) ^ 2 + (f.y - st.at.y) ^ 2)
			if d <= bestD then best, bestD = f, d end
		end
		if best then out[i] = { x = best.x, y = best.y } end
	end
	return out
end

-- Reachability reveal ----------------------------------------------------------------------------------------------------

function MapLife.newReveal() return { lit = nil, queue = {}, active = nil } end

-- `lit` is { [planetId] = bool } for this frame, `order` the planets in map order. The first call hydrates the current state
-- with no cinematic; afterwards a planet whose reachability goes false -> true queues one reveal (duplicates coalesce).
-- Returns the cue to draw now (see MapLife.cue) or nil.
function MapLife.updateReveal(rv, lit, order, now: number, reduced: boolean)
	if rv.lit == nil then
		rv.lit = {}
		for _, id in ipairs(order) do rv.lit[id] = lit[id] == true end
		return nil
	end
	local queued = {}
	for _, id in ipairs(rv.queue) do queued[id] = true end
	if rv.active then queued[rv.active.id] = true end
	for _, id in ipairs(order) do
		if lit[id] and not rv.lit[id] and not queued[id] then rv.queue[#rv.queue + 1] = id end
		rv.lit[id] = lit[id] == true
	end
	if rv.active and now - rv.active.start >= (reduced and LIFE.reveal.reduced or LIFE.reveal.total) then rv.active = nil end
	if not rv.active and #rv.queue > 0 then rv.active = { id = table.remove(rv.queue, 1), start = now } end
	if not rv.active then return nil end
	return MapLife.cue(now - rv.active.start, reduced, rv.active.id)
end

-- The reveal at `age` seconds: { id, ring = radius offset or nil, ringAlpha, label = 0..1 alpha, outline = static ring }.
function MapLife.cue(age: number, reduced: boolean, id: string?)
	local R = LIFE.reveal
	if reduced then
		if age < 0 or age >= R.reduced then return nil end
		return { id = id, outline = true, label = 1 }
	end
	if age < 0 or age >= R.total then return nil end
	local cue = { id = id, label = 0 }
	if age >= R.ring[1] and age < R.ring[2] then
		local u = (age - R.ring[1]) / (R.ring[2] - R.ring[1])
		cue.ring, cue.ringAlpha = u * R.ringReach, 1 - u
	end
	if age >= R.label[1] then cue.label = math.min(1, (age - R.label[1]) / 0.2) end
	if age >= R.label[2] then cue.label = math.max(0, 1 - (age - R.label[2]) / 0.3) end
	return cue
end

return MapLife
