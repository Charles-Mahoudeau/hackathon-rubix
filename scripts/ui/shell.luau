-- The UI shell (GR5-3): top bar, left nav, main panel, bottom agent feed, and the system map drawn over the main panel.
-- Everything here is a pure description (engine.ui specs) built from ui/shell_model.luau, so it can be tested headless;
-- only Shell.spawn touches the engine. Colours come from config/theme.luau through ui/theme.luau, nothing else.
-- Panels, buttons and gauges are Pixel Holo UI nine-patch images tinted by the theme (opts.skin, from UiTheme.panelSkin).
-- Without a skin (headless tests) they fall back to translucent nodes with a hairline border. Neither bakes a glow: the only bloom is
-- the neon of a lit thing (spec art rule), never a panel (see DECISIONS.md, Pixel Holo UI).
local Theme = require("@scripts/config/theme")
local Screens = require("@scripts/config/screens")
local UiTheme = require("@scripts/ui/theme")
local Model = require("@scripts/ui/shell_model")
local Editor = require("@scripts/ui/agent_editor")
local ComputeView = require("@scripts/ui/compute_view")
local LogsView = require("@scripts/ui/logs_view")
local ShopView = require("@scripts/ui/shop_view")
local FleetView = require("@scripts/ui/fleet_view")
local MissionsView = require("@scripts/ui/missions_view")
local AlertsView = require("@scripts/ui/alerts_view")
local BranchesView = require("@scripts/ui/branches_view")
local ArchiveView = require("@scripts/ui/archive_view")
local Studio = require("@scripts/ui/skill_studio")
local TeamView = require("@scripts/ui/team_view")
local MarketView = require("@scripts/ui/market_view")
local StationView = require("@scripts/ui/station_view")
local DebugPanel = require("@scripts/ui/debug")
local Glitch = require("@scripts/render/vfx/glitch")
local Route = require("@scripts/render/vfx/route")
local Vfx = require("@scripts/config/vfx")
local Planets = require("@scripts/config/planets")
local Glow = require("@scripts/ui/glow")
local Fit = require("@scripts/ui/fit")

local Shell = {}

local L = Theme.layout
local T = Theme.type

-- Rectangles in view pixels. Absolute layout keeps the world-drawn planets and the UI labels on the same coordinates.
function Shell.layout()
  local g, v = L.gap, L.view
  local top = { x = g, y = g, w = v.w - 2 * g, h = L.topBar }
  local navY = top.y + top.h + g
  local nav = { x = g, y = navY, w = L.nav, h = v.h - navY - g }
  local mainX = nav.x + nav.w + g
  local main = { x = mainX, y = navY, w = v.w - mainX - g, h = v.h - navY - L.feed - 2 * g }
  local feed = { x = mainX, y = main.y + main.h + g, w = main.w, h = L.feed }
  return { top = top, nav = nav, main = main, feed = feed }
end

-- A map fraction (0..1 of the main panel) -> view pixels. The world planets use the same function.
function Shell.mapPoint(fx: number, fy: number)
  local m = Shell.layout().main
  return { x = m.x + fx * m.w, y = m.y + fy * m.h }
end

-- Where a planet of the map sits, id -> { x, y } in view pixels (world and UI share these).
function Shell.planetPositions()
  local out = {}
  for id, p in pairs(Screens.map.planets) do out[id] = Shell.mapPoint(p.x, p.y) end
  return out
end

local function rect(r)
  return { position = "absolute", left = r.x, top = r.y, width = r.w, height = r.h }
end

-- Set by Shell.spec for the duration of one build; nil = no texture available.
local skin

-- `plain` keeps the hairline node even with a skin (the map panel, which must stay see-through over the world).
local function panel(r, extra, plain)
  local node = { style = { rect(r), { overflow = "hidden" }, extra }, children = {} }
  if skin and not plain then
    node.image = { texture = skin.texture, slice = skin.slice, color = skin.color }
    node.background = { color = UiTheme.color("panel", Theme.alpha.chromeFill), radius = L.radius }
  else
    node.background = { color = UiTheme.panel(), radius = L.radius, borderColor = UiTheme.line(), borderWidth = 1 }
  end
  return node
end

-- A button node. `colorName` is its colour (dim idle, cyan or another neon highlighted); `selected` takes the lighter texture.
-- Its resting colour is always spelled out: the engine paints a button with `normal`, which is white by default.
local function buttonNode(style, action: string, colorName: string, children, selected: boolean?)
	local node = { style = style, children = children }
	if skin and skin.button then
		node.image = { texture = selected and skin.button.active or skin.button.normal, slice = skin.button.slice, color = UiTheme.color(colorName) }
		node.button = UiTheme.skinButton(action, colorName)
	else
		local base = selected and UiTheme.mix("panel", colorName, Theme.mix.hover) or UiTheme.color("panel")
		node.background = { color = base, radius = L.radius, borderColor = UiTheme.color(colorName, 0.6), borderWidth = 1 }
		node.button = UiTheme.button(action, colorName, { normal = base, base = "panel" })
	end
	return node
end

-- A gauge: a track with a fill of `percent` (0..100) in `colorName`. `style` carries width and height (8 px or more).
local function gauge(style, percent: number, colorName: string)
	local pct = ("%d%%"):format(math.floor(math.max(0, math.min(100, percent))))
	local g = skin and skin.gauge
	if g then
		local fill = percent > 0 and { { style = { height = "100%", width = pct, minWidth = 6 },
			image = { texture = g.fill, slice = g.slice, color = UiTheme.color(colorName) } } } or {}
		return { style = style, image = { texture = g.track, slice = g.slice, color = g.trackColor }, children = fill }
	end
	return { style = style, background = { color = UiTheme.color("dim", Theme.alpha.line), radius = 2 },
		children = { { style = { height = "100%", width = pct }, background = { color = UiTheme.color(colorName), radius = 2 } } } }
end

local function text(font, str: string, size: number, colorName: string, extra)
  return { style = extra, text = { text = str, font = font, size = size, color = UiTheme.color(colorName) } }
end

local function withChildren(node, children)
  node.children = children
  return node
end

local function topBar(font, r, bar)
  local rep = bar.reputation
  local repLine = rep.next and ("%s  %s / %s"):format(bar.reputationText, Model.thousands(rep.revenue), Model.thousands(rep.next))
    or ("%s  max"):format(bar.reputationText)
  local gaugeColor = bar.computeLevel == "ok" and "cyan" or Theme.semantic.warning
  local function cell(label, value, valueColor, extra)
    return { style = { direction = "column", gap = 2, justify = "center", extra },
      children = { text(font, label, T.small, "dim"), text(font, value, T.heading, valueColor or "text") } }
  end
  local note = bar.computeLevel == "empty" and "  EMPTY" or (bar.computeLevel == "low" and "  low" or "")
  local gauge = { style = { direction = "column", gap = 4, justify = "center", width = 230 },
    children = {
      text(font, ("Compute  %s (%s)%s"):format(bar.computeText, bar.computeCreditsText, note), T.small, bar.computeLevel == "ok" and "dim" or Theme.semantic.warning),
      gauge({ height = 8, width = "100%" }, bar.computeFraction * 100, bar.budgetReached and Theme.semantic.warning or gaugeColor),
    } }
  -- Always offered: the button is greyed, never hidden, when the credits do not cover the pack (it then does nothing).
  local buyColor = bar.buy.affordable and "cyan" or "dim"
  local buy = buttonNode({ width = 176, height = 28, justify = "center", alignItems = "center" }, bar.buy.action, buyColor,
    { text(font, bar.buy.text, T.small, buyColor) }, bar.buy.affordable)
  local speed = { style = { direction = "row", gap = 4, alignItems = "center" }, children = {} }
  for _, c in ipairs(bar.speed) do
    local color = c.active and "cyan" or "dim"
    speed.children[#speed.children + 1] = buttonNode({ width = 38, height = 28, justify = "center", alignItems = "center" },
      c.action, color, { text(font, c.label, T.small, color) }, c.active)
  end
  local children = {
    text(font, "GRIDMIND", T.heading, "cyan", { marginRight = 16 }),
    cell("Credits", bar.creditsText, "text"),
    gauge,
    buy,
    cell("Reputation", repLine, "text"),
    cell("Tier", bar.tierText, "green"),
    speed,
  }
  if bar.budgetReached then children[#children + 1] = text(font, bar.budgetMessage, T.small, Theme.semantic.warning) end
  return withChildren(panel(r, { direction = "row", alignItems = "center", gap = 24, paddingX = L.pad }), children)
end

local function nav(font, r, entries, screenId)
  local items = {}
  for _, e in ipairs(entries) do
    items[#items + 1] = buttonNode({ paddingX = L.pad, paddingY = 8, direction = "row", alignItems = "center" },
      "nav." .. e.id, e.active and "cyan" or "dim", { text(font, e.label, T.body, e.active and "cyan" or "text") }, e.active)
  end
  return withChildren(panel(r, { direction = "column", gap = 4, padding = L.gap }), items)
end

local function empty(font, r, id)
  local e = Model.emptyState(id)
  return withChildren(panel(r, { direction = "column", justify = "center", alignItems = "center", gap = 8, padding = L.pad * 2 }), {
    text(font, e.title, T.heading, "text"),
    { style = { maxWidth = 460 }, text = { text = e.hint, font = font, size = T.body, color = UiTheme.color("dim"), align = "center", wrap = true } },
  })
end

local function feedStrip(font, r, lines)
  local rows = { text(font, "AGENT FEED", T.small, "dim", { marginBottom = 4 }) }
  if #lines == 0 then rows[#rows + 1] = text(font, "No tool calls yet.", T.small, "dim") end
  -- One line per entry, cut to the strip: a wrapped entry would push the newest ones out of the fixed-height panel.
  local room = r.w - 2 * L.pad
  for _, l in ipairs(lines) do
    local color = l.status == "failed" and Theme.semantic.error or (l.status == "running" and "dim" or (l.source == "monitor" and "cyan" or "text"))
    local line = Fit.truncate((l.agent and (l.agent .. "  ") or "") .. l.text, T.small, room)
    rows[#rows + 1] = text(font, line, T.small, color, { height = math.ceil(T.small * Fit.lineHeight) })
  end
  return withChildren(panel(r, { direction = "column", paddingX = L.pad, paddingY = L.gap, overflow = "hidden" }), rows)
end

-- Dash positions along a route A -> B, skipping the planet discs at both ends. Pure; spacing in view pixels. `phase` slides
-- the whole pattern along the line, which is how an active route animates.
function Shell.dashes(a, b, skipA: number, skipB: number, spacing: number, phase: number?)
  local dx, dy = b.x - a.x, b.y - a.y
  local len = math.sqrt(dx * dx + dy * dy)
  local out = {}
  if len < 1 then return out end
  local n = math.floor(len / spacing)
  local shift = (phase or 0) % spacing
  for i = (phase and 0 or 1), n - 1 do
    local d = i * spacing + shift
    if d > skipA and d < len - skipB then out[#out + 1] = { x = a.x + dx * d / len, y = a.y + dy * d / len } end
  end
  return out
end

local function dot(center, size: number, colorName: string, alpha: number?)
  return { style = { position = "absolute", left = center.x - size / 2, top = center.y - size / 2, width = size, height = size, ignorePointer = true },
    background = { color = UiTheme.color(colorName, alpha), radius = size / 2 } }
end

-- A transparent hit area over a map thing: hovering tints it, a click focuses it ("map.focus.<id>", Shell.act).
local function focusArea(center, size: number, id: string, colorName: string)
  return { style = { position = "absolute", left = center.x - size / 2, top = center.y - size / 2, width = size, height = size },
    background = { color = UiTheme.color(colorName, 0), radius = size / 2 },
    button = UiTheme.button("map.focus." .. id, colorName, { base = colorName, alpha = 0 }) }
end

-- opts: time (seconds, animates the pulse and the moving dashes), focus (the hovered / selected planet or market id).
local function mapOverlay(font, r, map, opts)
  local cfg = Screens.map
  local t, focus = opts.time or 0, opts.focus
  local nodes = {}
  local points = {}
  for _, p in ipairs(map.planets) do points[p.id] = Shell.mapPoint(p.x, p.y) end
  for _, m in ipairs(map.markets) do points[m.id] = Shell.mapPoint(m.x, m.y) end
  local routeName = { safe = Vfx.route.safe, risky = Vfx.route.risky }
  local glow = Vfx.glow

  local busy = {}
  for _, c in ipairs(map.convoys) do busy[c.from .. ">" .. c.to] = true end

  -- Routes: colour and alpha from render/vfx/route; a route with a convoy on it (or touching the focus) moves and glows.
  for _, route in ipairs(map.routes) do
    local a, b = points[route.from], points[route.to]
    local focused = focus ~= nil and (route.from == focus or route.to == focus)
    local active = busy[route.from .. ">" .. route.to] == true
    local style = Route.style(cfg.riskValue[route.risk] or 0.5, active or focused, t)
    local name = routeName[route.color]
    local scale = focused and glow.focusScale or 1
    local phase = style.dashOffset / (style.dash + style.gap) * cfg.routeSpacing
    for i, d in ipairs(Shell.dashes(a, b, cfg.planetRadius + 6, 14, cfg.routeSpacing, phase)) do
      if (active or focused) and i % 2 == 0 then
        nodes[#nodes + 1] = dot(d, glow.routeUnderlay.size * scale, name, glow.routeUnderlay.alpha)
      end
      nodes[#nodes + 1] = dot(d, cfg.routeThickness * scale, name, math.min(1, style.color[4] * 0.55 + (focused and 0.3 or 0)))
    end
  end
  -- Convoys and rival convoys are ships now (client/fleet_map.luau, GR5-51): the world layer draws them, no dot here.

  local function label(center, name, sub, colorName, subColor, below)
    local title, line = text(font, name, T.body, colorName), sub and text(font, sub, T.small, subColor or "dim") or nil
    title.text.align = "center"
    if line then line.text.align = "center" end
    local left = math.max(r.x + L.gap, math.min(center.x - 90, r.x + r.w - 180 - L.gap))
    return { style = { position = "absolute", left = left, top = center.y + below, width = 180, alignItems = "center", direction = "column", gap = 2 },
      children = { title, line } }
  end
  for _, p in ipairs(map.planets) do
    local c = points[p.id]
    local sub = p.lit and table.concat(p.ores, ", ") or ("Locked: " .. p.condition)
    if p.lit then
      local look = Planets.planets[p.id]
      local neon = look.rim and look.rim[1] or "cyan"
      for _, n in ipairs(Glow.planetRing(c, cfg.planetRadius, neon, t)) do nodes[#nodes + 1] = n end
      if focus == p.id then
        for _, n in ipairs(Glow.halo(c, cfg.planetRadius, "selected", t, false)) do nodes[#nodes + 1] = n end
      end
      nodes[#nodes + 1] = focusArea(c, cfg.planetRadius * 2, p.id, neon)
    end
    nodes[#nodes + 1] = label(c, p.name, sub, p.lit and "text" or "dim", p.lit and "dim" or Theme.semantic.warning, cfg.planetRadius + 8)
  end
  for _, m in ipairs(map.markets) do
    local c = points[m.id]
    for _, n in ipairs(Glow.halo(c, glow.node, focus == m.id and "selected" or "idle", t, false)) do nodes[#nodes + 1] = n end
    nodes[#nodes + 1] = { style = { position = "absolute", left = c.x - 9, top = c.y - 9, width = 18, height = 18 },
      background = { color = UiTheme.color("panel"), radius = 3, borderColor = UiTheme.color("cyan"), borderWidth = 1 },
      button = UiTheme.button("map.focus." .. m.id, "cyan") }
    nodes[#nodes + 1] = label(c, m.name, ("T%d market"):format(m.tier), "text", "dim", 14)
  end
  -- The depot and the outposts: a dotted dock line from the planet to the station, and its name above it (GR5-52).
  for _, st in ipairs(opts.mapStations or {}) do
    for _, d in ipairs(Shell.dashes(st.from, st.to, st.skipFrom, st.skipTo, st.spacing)) do
      nodes[#nodes + 1] = dot(d, 3, "cyan", 0.75)
    end
    local title = text(font, st.label, T.small, "cyan")
    title.text.align = "center"
    nodes[#nodes + 1] = { style = { position = "absolute", left = st.at.x - 90, top = st.at.y, width = 180, alignItems = "center", ignorePointer = true },
      children = { title } }
  end
  return nodes
end


-- Agent editor (GR5-5). Fields are absolute view-pixel rectangles shared by the shell (holes) and the inputs tree.
function Shell.editorFields()
  local m, e = Shell.layout().main, Screens.editor
  local x, w = m.x + L.pad, e.leftWidth - 2 * L.pad
  return {
    directive = { x = x, y = m.y + e.directiveY, w = w, h = e.fieldHeight },
    order = { x = x, y = m.y + e.orderY, w = w, h = e.fieldHeight },
  }
end

-- Child of `parent` at (x, y) relative to it.
local function at(x: number, y: number, node, w: number?, h: number?)
  local style = { position = "absolute", left = x, top = y, width = w, height = h }
  node.style = node.style and { style, node.style } or style
  return node
end

local function button(font, label: string, action: string, colorName: string, w: number)
  return buttonNode({ width = w, height = 28, justify = "center", alignItems = "center" }, action, colorName,
    { text(font, label, T.small, colorName) }, colorName ~= "dim")
end

local function tabButtons(font, active: string)
  local out = {}
  for _, tab in ipairs(Screens.tabs) do
    out[#out + 1] = at(tab.x, Screens.tabs.y, button(font, tab.label, "editor.tab." .. tab.id, tab.id == active and "cyan" or "dim", tab.w))
  end
  return out
end

-- Cost of one decision: what the Context panel and the editor both say, from the same prompt the ledger bills.
local function costRows(font, m, formats)
  local rows = {
    text(font, "COST OF ONE DECISION", T.small, "dim"),
    text(font, m.cost.text, T.heading, "cyan"),
    text(font, ("%d input + %d output = %d tokens"):format(m.inputTokens, m.outputTokens, m.totalTokens), T.small, "dim"),
    text(font, "", T.small, "dim"),
  }
  for _, name in ipairs({ "rules", "directive", "order", "context", "tools" }) do
    rows[#rows + 1] = text(font, ("%-10s %5d tokens"):format(name, m.sections[name]), T.body, "text")
  end
  rows[#rows + 1] = text(font, "", T.small, "dim")
  for _, f in ipairs(formats) do
    rows[#rows + 1] = text(font, ("Context %-7s %5d tokens%s"):format(f.format, f.context, f.active and "  (in use)" or ""), T.small, f.active and "cyan" or "dim")
  end
  return rows
end

-- Per-agent Compute/h, the hourly AI budget and the buy packs, under the editor fields.
local function computeBlock(font, cv, nodeAt)
  local c = Screens.compute
  local y = c.y
  nodeAt(L.pad, y, text(font, "COMPUTE PER HOUR  (who thinks the most)", T.small, "dim"))
  y += c.rowHeight + 2
  for _, row in ipairs(cv.rows) do
    local blocked = row.state == "no_compute"
    local state = blocked and ("no compute: " .. tostring(row.blockReason or "")) or row.state
    local line = ("%-10s %6.1f /h  (%d cr/h)  %s"):format(row.id, row.computePerHour, math.floor(row.creditsPerHour + 0.5), state)
    nodeAt(L.pad, y, text(font, line, T.small, blocked and Theme.semantic.warning or (row.thinksMost and #cv.rows > 1 and "cyan" or "text")))
    y += c.rowHeight
  end
  nodeAt(L.pad, y, text(font, ("%-10s %6.1f /h  (%d cr/h)"):format("team", cv.top.teamPerHour, math.floor(cv.top.teamPerHour * cv.cfg.compute.priceCredits + 0.5)), T.small, "dim"))
  y += c.rowHeight
  local b = cv.top.budget
  local budgetText = b.reached and b.message or ("AI budget this hour: %s / %s tokens (%d%%)"):format(Model.thousands(b.used), Model.thousands(b.cap), math.floor(b.fraction * 100))
  nodeAt(L.pad, y, text(font, budgetText, T.small, b.reached and Theme.semantic.warning or "dim"))
  y += c.rowHeight + 6
  local x = L.pad
  for _, o in ipairs(cv.buy) do
    nodeAt(x, y, button(font, o.text, o.action, o.affordable and "cyan" or "dim", c.buyWidth))
    x += c.buyWidth + c.buyGap
  end
end

local function editorScreen(font, r, m, opts)
  local e = Screens.editor
  local counterColor = function(c) return c.amber and Theme.semantic.warning or "dim" end
  local left = {}
  local function nodeAt(x, y, node) left[#left + 1] = at(x, y, node) end
  nodeAt(L.pad, L.pad, text(font, "AGENT EDITOR  " .. m.agentId, T.small, "dim"))
  for _, n in ipairs(Glow.light({ x = L.pad + 7 * (16 + #m.agentId) + 12, y = L.pad + 8 }, opts.state, opts.time or 0)) do left[#left + 1] = n end
  for _, n in ipairs(tabButtons(font, "editor")) do left[#left + 1] = n end
  nodeAt(L.pad, e.directiveY - 22, text(font, "Directive (permanent)", T.body, "text"))
  nodeAt(e.leftWidth - L.pad - 150, e.directiveY - 22, text(font, m.directive.text .. " tokens", T.body, counterColor(m.directive)))
  nodeAt(L.pad, e.orderY - 22, text(font, "Order (one-off, until cleared)", T.body, "text"))
  nodeAt(e.leftWidth - L.pad - 150, e.orderY - 22, text(font, m.order.text .. " tokens", T.body, counterColor(m.order)))
  local x = L.pad
  for _, preset in ipairs(opts.presets) do
    nodeAt(x, e.buttonsY, button(font, preset.label, "editor.preset." .. preset.key, "dim", 80))
    x += 88
  end
  nodeAt(x + 16, e.buttonsY, button(font, "Clear order", "editor.clear_order", "dim", 110))
  nodeAt(x + 134, e.buttonsY, button(font, "Save", "editor.save", m.canSave and "cyan" or "dim", 80))
  if m.lock then
    nodeAt(x + 230, e.buttonsY, button(font, m.lock.locked and "Monitor lock: ON" or "Monitor lock: off", m.lock.action, m.lock.locked and "amber" or "dim", 150))
  end
  if m.orderSource then nodeAt(L.pad + 200, e.orderY - 22, text(font, "set by the " .. m.orderSource, T.small, "cyan")) end
  local note = opts.toast or (not m.canSave and "Over the limit: cannot be saved." or (m.dirty and "Unsaved changes." or nil))
  if note then
    nodeAt(L.pad, e.toastY, text(font, note, T.small, opts.toast and "green" or (not m.canSave and Theme.semantic.warning or "dim")))
  end
  computeBlock(font, opts.compute, nodeAt)
  local leftPanel = panel({ x = r.x, y = r.y, w = e.leftWidth, h = r.h }, nil)
  withChildren(leftPanel, left)

  local rows = costRows(font, m, m.formats)
  rows[#rows + 1] = text(font, "", T.small, "dim")
  rows[#rows + 1] = text(font, "TOOLS (each one is paid in every prompt)", T.small, "dim")
  for _, t in ipairs(m.tools) do rows[#rows + 1] = text(font, ("%-8s %4d tokens"):format(t.name, t.tokens), T.small, "text") end
  rows[#rows + 1] = text(font, ("Skill slots %d / %d"):format(m.skills.used, m.skills.slots), T.small, "dim")
  local rightPanel = panel({ x = r.x + e.costX, y = r.y, w = r.w - e.costX, h = r.h }, { direction = "column", gap = 4, padding = L.pad, overflow = "hidden" })
  return leftPanel, withChildren(rightPanel, rows)
end

-- Context panel (GR5-6, spec §9.3): every setting with the tokens each option adds to every decision. The total on the
-- right is the cost the ledger bills for the next decision.
local function contextScreen(font, r, panelModel)
  local e, c = Screens.editor, Screens.context
  local left = {}
  local function nodeAt(x, y, node) left[#left + 1] = at(x, y, node) end
  nodeAt(L.pad, L.pad, text(font, "CONTEXT  " .. panelModel.agentId, T.small, "dim"))
  for _, n in ipairs(tabButtons(font, "context")) do left[#left + 1] = n end
  nodeAt(L.pad, c.rowY - 22, text(font, "(+N) = tokens the option adds to every decision of this agent", T.small, "dim"))
  for i, row in ipairs(panelModel.rows) do
    local y = c.rowY + (i - 1) * c.rowHeight
    nodeAt(L.pad, y + 6, text(font, row.label, T.body, row.available and "text" or "dim"))
    if not row.available then
      nodeAt(L.pad + c.optionX, y + 6, text(font, ("Locked: unlocks at T%d"):format(row.unlockTier), T.small, Theme.semantic.warning))
    elseif row.kind == "stepper" then
      nodeAt(L.pad + c.optionX, y, button(font, "-", row.stepActions.down, "cyan", c.stepWidth))
      nodeAt(L.pad + c.optionX + c.stepWidth + 10, y + 6, text(font, ("%d  (+%d)"):format(row.value, row.weight), T.body, "cyan"))
      nodeAt(L.pad + c.optionX + 160, y, button(font, "+", row.stepActions.up, "cyan", c.stepWidth))
    else
      for k, o in ipairs(row.options) do
        local label = o.weight > 0 and ("%s (+%d)"):format(o.text, o.weight) or o.text
        nodeAt(L.pad + c.optionX + (k - 1) * (c.optionWidth + c.optionGap), y, button(font, label, o.action, o.selected and "cyan" or "dim", c.optionWidth))
      end
    end
  end
  local leftPanel = withChildren(panel({ x = r.x, y = r.y, w = e.leftWidth, h = r.h }, nil), left)

  local rows = costRows(font, panelModel, panelModel.formatList)
  rows[#rows + 1] = text(font, "", T.small, "dim")
  local b = panelModel.budget
  rows[#rows + 1] = text(font, b.reached and b.message or ("AI budget this hour: %d%% used"):format(math.floor(b.fraction * 100)), T.small, b.reached and Theme.semantic.warning or "dim")
  local rightPanel = panel({ x = r.x + e.costX, y = r.y, w = r.w - e.costX, h = r.h }, { direction = "column", gap = 4, padding = L.pad, overflow = "hidden" })
  return leftPanel, withChildren(rightPanel, rows)
end

-- Logs screen (GR5-8, spec §12.2): per-agent stats on top, the filtered list (errors amber with their reason), and the
-- clicked record on the right.
local function logsScreen(font, r, m)
  local c = Screens.logs
  local left = {}
  local function nodeAt(x, y, node, w, h) left[#left + 1] = at(x, y, node, w, h) end
  local y = L.pad
  nodeAt(L.pad, y, text(font, "DECISION LOG", T.small, "dim"))
  y += c.statRowHeight
  nodeAt(L.pad, y, text(font, "PER AGENT, LAST 10 GAME MINUTES", T.small, "dim"))
  y += c.statRowHeight
  for _, h in ipairs(m.header) do
    local line = ("%-12s credits/h %6s   Compute/h %5.1f   net/h %6s"):format(h.id, Model.thousands(h.creditsPerHour), h.computePerHour,
      (h.netPerHour < 0 and "-" or "") .. Model.thousands(math.abs(h.netPerHour)))
    nodeAt(L.pad, y, text(font, line, T.small, h.netPerHour < 0 and Theme.semantic.warning or "text"))
    y += c.statRowHeight
  end
  y += 6
  local x = L.pad
  for _, a in ipairs(m.agents) do
    nodeAt(x, y, button(font, a.label, a.action, a.active and "cyan" or "dim", c.agentButtonWidth), c.agentButtonWidth, c.buttonHeight)
    x += c.agentButtonWidth + 6
  end
  y += c.buttonHeight + 6
  x = L.pad
  for _, sBtn in ipairs(m.sources) do
    nodeAt(x, y, button(font, sBtn.label, sBtn.action, sBtn.active and "cyan" or "dim", c.sourceButtonWidth), c.sourceButtonWidth, c.buttonHeight)
    x += c.sourceButtonWidth + 6
  end
  nodeAt(x + 10, y, button(font, "Errors only", "logs.errors", m.errorsOnly and Theme.semantic.warning or "dim", c.errorsButtonWidth), c.errorsButtonWidth, c.buttonHeight)
  nodeAt(x + 10 + c.errorsButtonWidth + 6, y, button(font, m.compareButton.label, m.compareButton.action, "cyan", c.compareButtonWidth), c.compareButtonWidth, c.buttonHeight)
  y += c.buttonHeight + 10
  local rowW = c.listWidth - 2 * L.pad
  for _, row in ipairs(m.rows) do
    local color = row.isError and Theme.semantic.error or (row.pending and "dim" or "text")
    nodeAt(L.pad, y, { style = { paddingX = 6, justify = "center" },
      background = { color = row.selected and UiTheme.hover("cyan") or UiTheme.color("panel", 0), radius = 2 },
      button = UiTheme.button(row.action, "cyan", row.selected and { normal = UiTheme.hover("cyan") } or { base = "panel", alpha = 0 }),
      children = { text(font, row.text, T.small, color) } }, rowW, c.rowHeight)
    y += c.rowHeight
  end
  y += 6
  nodeAt(L.pad, y, button(font, "Newer", "logs.page.-1", m.page > 0 and "cyan" or "dim", 80), 80, c.buttonHeight)
  nodeAt(L.pad + 90, y + 6, text(font, ("%d-%d of %d   page %d/%d"):format(m.shown == 0 and 0 or m.page * c.rows + 1,
    math.min(m.shown, (m.page + 1) * c.rows), m.shown, m.page + 1, m.pages), T.small, "dim"))
  nodeAt(c.listWidth - L.pad - 80, y, button(font, "Older", "logs.page.1", m.page + 1 < m.pages and "cyan" or "dim", 80), 80, c.buttonHeight)
  local leftPanel = withChildren(panel({ x = r.x, y = r.y, w = c.listWidth, h = r.h }, nil), left)

  local rows = {}
  local d = m.detail
  local wrapW = r.w - c.listWidth - L.gap - 2 * L.pad
  local function wrapped(str, colorName)
    return { style = { maxWidth = wrapW }, text = { text = str, font = font, size = T.small, color = UiTheme.color(colorName), wrap = true } }
  end
  if not d then
    rows[#rows + 1] = wrapped(m.hint, "dim")
  else
    rows[#rows + 1] = text(font, d.title, T.heading, d.isError and Theme.semantic.error or "cyan")
    rows[#rows + 1] = text(font, ("%s   answered in %s   prompt v%s"):format(d.time, d.latency, d.promptVersion or "-"), T.small, "dim")
    rows[#rows + 1] = text(font, "", T.small, "dim")
    rows[#rows + 1] = text(font, "TOKENS" .. (d.realTokens and " (total from the provider)" or " (estimate)"), T.small, "dim")
    for _, t in ipairs(d.tokens) do rows[#rows + 1] = text(font, ("%-10s %5d"):format(t.name, t.tokens), T.small, t.name == "total" and "cyan" or "text") end
    local sizes = {}
    for _, sz in ipairs(d.contextSizes) do sizes[#sizes + 1] = ("%s %d"):format(sz.format, sz.tokens) end
    if #sizes > 0 then rows[#rows + 1] = text(font, "Context in both formats: " .. table.concat(sizes, ", "), T.small, "dim") end
    rows[#rows + 1] = text(font, "Compute spent: " .. d.computeText, T.small, "text")
    rows[#rows + 1] = text(font, "", T.small, "dim")
    rows[#rows + 1] = text(font, "REASONING", T.small, "dim")
    rows[#rows + 1] = wrapped(d.reasoning, "text")
    rows[#rows + 1] = text(font, "CALL", T.small, "dim")
    rows[#rows + 1] = wrapped(d.call, "text")
    rows[#rows + 1] = text(font, "VALIDATION", T.small, "dim")
    rows[#rows + 1] = wrapped(d.validation .. (d.fallback and "  (the stub played this decision)" or ""), d.validation == "ok" and "green" or Theme.semantic.error)
    rows[#rows + 1] = text(font, "RESULT", T.small, "dim")
    rows[#rows + 1] = wrapped(d.result, (d.isError and d.validation == "ok") and Theme.semantic.error or "text")
    if d.credits ~= 0 then rows[#rows + 1] = text(font, ("Credits from this action: %+d"):format(d.credits), T.small, "green") end
    if d.record then rows[#rows + 1] = button(font, d.record.label, d.record.action, "cyan", 220) end
  end
  local rightPanel = panel({ x = r.x + c.listWidth + L.gap, y = r.y, w = r.w - c.listWidth - L.gap, h = r.h },
    { direction = "column", gap = 3, padding = L.pad, overflow = "hidden" })
  return leftPanel, withChildren(rightPanel, rows)
end

-- Prompt-version comparison (GR5-13, spec §12.3): pick an agent and two of its versions, then the rates side by side
-- (the better one green) and the two directives with the words that differ highlighted.
local function compareScreen(font, r, m)
  local c = Screens.logs.compare
  local kids = {}
  local function nodeAt(x, y, node, w, h) kids[#kids + 1] = at(x, y, node, w, h) end
  local colW = (r.w - 3 * L.pad) // 2
  local colB = L.pad + colW + L.pad
  nodeAt(L.pad, L.pad, text(font, "COMPARE PROMPT VERSIONS", T.small, "dim"))
  nodeAt(r.w - L.pad - 150, L.pad - 6, button(font, m.back.label, m.back.action, "cyan", 150), 150, 28)
  local y = L.pad + 22
  local x = L.pad
  for _, a in ipairs(m.agents) do
    nodeAt(x, y, button(font, a.label, a.action, a.active and "cyan" or "dim", 96), 96, 28)
    x += 102
  end
  y += 34
  for _, pick in ipairs({ { "A", m.pickA }, { "B", m.pickB } }) do
    nodeAt(L.pad, y + 8, text(font, pick[1], T.small, "dim"))
    x = L.pad + 24
    for _, v in ipairs(pick[2]) do
      nodeAt(x, y, button(font, v.label, v.action, v.active and "cyan" or "dim", c.versionButtonWidth), c.versionButtonWidth, 28)
      x += c.versionButtonWidth + 6
    end
    y += 34
  end
  if not m.rows then
    nodeAt(L.pad, y + 6, text(font, m.versionCount == 0 and "No versions yet: an agent gets one as soon as it plays." or m.hint, T.small, "dim"))
    return withChildren(panel(r, nil), kids)
  end
  y += 6
  nodeAt(L.pad, y, text(font, m.a.title, T.body, "cyan"))
  nodeAt(L.pad + c.labelWidth + c.valueWidth, y, text(font, m.b.title, T.body, "cyan"))
  y += 20
  nodeAt(L.pad, y, text(font, m.a.detail, T.small, "dim"))
  y += 16
  nodeAt(L.pad, y, text(font, m.b.detail, T.small, "dim"))
  y += 22
  for _, row in ipairs(m.rows) do
    local dimmed = m.notEnoughData and "dim" or "text"
    nodeAt(L.pad, y, text(font, row.label, T.small, "dim"))
    nodeAt(L.pad + c.labelWidth, y, text(font, "A  " .. row.a, T.small, row.better == "a" and "green" or dimmed))
    nodeAt(L.pad + c.labelWidth + c.valueWidth, y, text(font, "B  " .. row.b, T.small, row.better == "b" and "green" or dimmed))
    y += c.rowHeight
  end
  for _, side in ipairs({ { "A", m.a }, { "B", m.b } }) do
    if side[2].note then
      nodeAt(L.pad, y, text(font, ("%s: %s"):format(side[1], side[2].note), T.small, Theme.semantic.warning))
      y += 16
    end
  end
  if m.sameVersion then
    nodeAt(L.pad, y, text(font, "A and B are the same version.", T.small, "dim"))
    y += 16
  end
  y += 8
  nodeAt(L.pad, y, text(font, "TOOLS  " .. m.tools.a, T.small, m.tools.changed and Theme.semantic.warning or "dim"))
  nodeAt(colB, y, text(font, "TOOLS  " .. m.tools.b, T.small, m.tools.changed and Theme.semantic.warning or "dim"))
  y += 16
  nodeAt(L.pad, y, text(font, "CONTEXT  " .. m.settings.text, T.small, m.settings.changed and Theme.semantic.warning or "dim"))
  y += 22
  nodeAt(L.pad, y, text(font, "DIRECTIVE A", T.small, "dim"))
  nodeAt(colB, y, text(font, "DIRECTIVE B", T.small, "dim"))
  y += 18
  for i, lines in ipairs({ m.directiveA, m.directiveB }) do
    local lx = i == 1 and L.pad or colB
    local ly = y
    for _, line in ipairs(lines) do
      local words = {}
      for _, w in ipairs(line) do
        local node = text(font, w.text, T.small, w.changed and Theme.semantic.warning or "text")
        if w.changed then node.background = { color = UiTheme.color(Theme.semantic.warning, 0.18), radius = 2 } end
        words[#words + 1] = node
      end
      nodeAt(lx, ly, { style = { direction = "row", gap = c.wordGap }, children = words })
      ly += c.lineHeight
    end
    local more = i == 1 and m.moreA or m.moreB
    if more > 0 then nodeAt(lx, ly, text(font, ("... %d more lines"):format(more), T.small, "dim")) end
  end
  return withChildren(panel(r, nil), kids)
end

-- Shop (GR5-7, spec §6.5): every upgrade with its cost, a Buy button when it can be bought, and why when it cannot.
local function shopScreen(font, r, m)
  local c = Screens.shop
  local kids = {}
  local function nodeAt(x, y, node) kids[#kids + 1] = at(x, y, node) end
  nodeAt(L.pad, L.pad, text(font, "SHOP  upgrades apply to every mining ship", T.small, "dim"))
  for i, row in ipairs(m.rows) do
    local y = c.rowY + (i - 1) * c.rowHeight
    local owned = row.state == "owned"
    nodeAt(L.pad, y + 6, text(font, row.name, T.body, owned and "dim" or "text"))
    nodeAt(c.descX, y + 8, text(font, row.desc, T.small, "dim"))
    if row.note and row.state ~= "available" then
      nodeAt(c.noteX, y + 8, text(font, row.note, T.small, owned and "green" or Theme.semantic.warning))
    end
    if not owned then
      nodeAt(c.costX, y + 8, text(font, row.costText, T.small, row.state == "available" and "cyan" or "dim"))
      if row.state == "available" then nodeAt(c.buyX, y, button(font, "Buy", row.action, "cyan", c.buyWidth)) end
    end
  end
  local y = c.rowY + #m.rows * c.rowHeight + c.footerGap
  for _, f in ipairs(m.fleet) do
    nodeAt(L.pad, y, text(font, f.text, T.small, "text"))
    y += 18
  end
  for _, s in ipairs(m.slots) do
    nodeAt(L.pad, y, text(font, s.text, T.small, "dim"))
    y += 18
  end
  return withChildren(panel(r, nil), kids)
end

-- Fleet (GR5-12, spec §6.5-6.7): Reputation and command capacity, the logistics hub, each station with its freighters,
-- Logisticians and idle reason, outposts to build, and the mining ships.
local function fleetScreen(font, r, m, time)
  local c = Screens.fleet
  local kids = {}
  local function nodeAt(x, y, node) kids[#kids + 1] = at(x, y, node) end
  local rep = m.reputation
  nodeAt(L.pad, L.pad, text(font, ("REPUTATION %d  %s  command %d / %d"):format(rep.level,
    rep.next and ("%s / %s"):format(Model.thousands(rep.revenue), Model.thousands(rep.next)) or "max", rep.used, rep.capacity), T.small, "dim"))
  nodeAt(L.pad, c.barY, gauge({ height = c.barHeight, width = c.barWidth }, rep.percent, "cyan"))
  local hub = m.hub
  if hub then
    if hub.state == "owned" then
      nodeAt(c.hubX, L.pad, text(font, "Logistics hub: online", T.small, "green"))
    else
      nodeAt(c.hubX, L.pad, text(font, ("Logistics hub  %s"):format(hub.costText), T.small, hub.state == "available" and "cyan" or "dim"))
      if hub.state == "available" then nodeAt(c.hubX, c.barY - 4, button(font, "Build hub", hub.action, "cyan", c.buttonWidth))
      elseif hub.note then nodeAt(c.hubX, c.barY, text(font, hub.note, T.small, Theme.semantic.warning)) end
    end
  end
  local y = c.stationY
  local function row(label, colorName, x, state)
    if state then for _, n in ipairs(Glow.light({ x = (x or L.pad) - 8, y = y + 8 }, state, time)) do kids[#kids + 1] = n end end
    nodeAt(x or L.pad, y, text(font, label, T.small, colorName))
    y += c.lineHeight
  end
  for _, st in ipairs(m.stations) do
    row(("%s   stock %s"):format(st.label, st.stockText), "text")
    row(("freighters %d/%d   hangars %d   Logisticians %s"):format(st.freighters, st.freighterCap, st.hangar,
      #st.logisticians > 0 and table.concat(st.logisticians, ", ") or "none"), "dim")
    if st.idleText then row(st.idleText, Theme.semantic.warning, L.pad + 12, "pending") end
    for _, f in ipairs(st.freighterRows) do
      row(f.state == "docked" and (f.id .. "  docked") or ("%s  %s  eta %ds"):format(f.id, f.cargo and ("-> " .. f.dest .. " " .. f.cargo) or ("back to " .. f.dest), f.eta), "dim", c.convoyX, f.state == "docked" and "idle" or "acting")
    end
    if m.hubOpen then
      local x = L.pad
      local function act(label, can, action, note)
        if can then nodeAt(x, y, button(font, label, action, "cyan", c.buttonWidth))
        else nodeAt(x, y, text(font, label .. ": " .. (note or "unavailable"), T.small, "dim")) end
        x += c.buttonWidth + c.buttonGap
      end
      act(("Freighter %d cr"):format(st.freighterCost), st.canFreighter, st.actions.freighter, st.freighterNote)
      act(("Hangar %d cr"):format(st.hangarCost), st.canHangar, st.actions.hangar, st.hangarNote)
      act("Hire Logistician", st.canHire, st.actions.hire, st.hireNote)
      y += 34
    end
    y += c.blockGap
  end
  if m.hubOpen then
    row("OUTPOSTS", "dim")
    local x = L.pad
    for _, o in ipairs(m.outposts) do
      if o.can then nodeAt(x, y, button(font, ("%s %d cr"):format(o.planet, o.cost), o.action, "cyan", c.outpostButtonWidth))
      else nodeAt(x, y + 6, text(font, ("%s: %s"):format(o.planet, o.note or "unavailable"), T.small, "dim")) end
      x += c.outpostButtonWidth + c.buttonGap
    end
    y += 34 + c.blockGap
  end
  row("SHIPS", "dim")
  for _, s in ipairs(m.ships) do row(s.text, s.owner and "text" or Theme.semantic.warning, L.pad + 12, s.owner and "acting" or "idle") end
  return withChildren(panel(r, nil), kids)
end

-- Station (GR5-73, spec §6.6 T3, §7): stock per resource with used / capacity, docked ships, freighters and Logisticians of
-- the main station and of each outpost (one tab per station).
local function stationScreen(font, r, m, time)
  local c = Screens.station
  local kids = {}
  local function nodeAt(x, y, node) kids[#kids + 1] = at(x, y, node) end
  if m.showTabs then
    for i, tab in ipairs(m.tabs) do
      nodeAt(L.pad + (i - 1) * (c.tabWidth + c.tabGap), c.tabY, button(font, tab.label, tab.action, tab.active and "cyan" or "dim", c.tabWidth))
    end
  end
  nodeAt(L.pad, c.headerY, text(font, ("%s  %s   stock %s"):format(m.label:upper(), m.planet, m.usedText), T.small, "dim"))
  nodeAt(L.pad, c.barY, gauge({ height = c.barHeight, width = c.barWidth }, m.percent, m.percent >= 90 and Theme.semantic.warning or "cyan"))
  for i, row in ipairs(m.stock) do
    local y = c.rowY + (i - 1) * c.rowHeight
    nodeAt(L.pad, y, text(font, row.name, T.body, row.qty > 0 and "text" or "dim"))
    nodeAt(c.rowBarX, y + c.rowBarY - 4, gauge({ height = c.barHeight, width = c.rowBarWidth }, row.percent, "green"))
    nodeAt(c.rowQtyX, y, text(font, tostring(row.qty), T.body, row.qty > 0 and "text" or "dim"))
  end
  local y = c.rowY
  local function line(label, colorName, state, x)
    if state then for _, n in ipairs(Glow.light({ x = c.listX - 8, y = y + 8 }, state, time)) do kids[#kids + 1] = n end end
    nodeAt(x or c.listX, y, text(font, label, T.small, colorName))
    y += c.lineHeight
  end
  line(("DOCKED SHIPS  %d"):format(#m.ships), "dim")
  if #m.ships == 0 then line("none", "dim", nil, c.listX + 12) end
  for _, s in ipairs(m.ships) do line(s.text, s.owner and "text" or Theme.semantic.warning, s.owner and "idle" or "pending", c.listX + 12) end
  y += c.sectionGap
  if not m.hub then
    line("FREIGHTERS AND LOGISTICIANS", "dim")
    line("Build the logistics hub (tier 4) to ship stock to other markets.", "dim", nil, c.listX + 12)
  else
    line(("FREIGHTERS  %d / %d"):format(#m.freighters, m.freighterCap), "dim")
    if #m.freighters == 0 then line("none", "dim", nil, c.listX + 12) end
    for _, f in ipairs(m.freighters) do line(f.text, "text", f.state == "docked" and "idle" or "acting", c.listX + 12) end
    y += c.sectionGap
    line(("LOGISTICIANS  %d"):format(#m.logisticians), "dim")
    if #m.logisticians == 0 then line("none", "dim", nil, c.listX + 12) end
    for _, a in ipairs(m.logisticians) do line(a.text, "text", a.state, c.listX + 12) end
    if m.idleText then line(m.idleText, Theme.semantic.warning, "pending", c.listX + 12) end
  end
  return withChildren(panel(r, nil), kids)
end

-- Missions (GR5-9, spec §15): the current mission (goal, hint, progress bar, reward, Claim), then every mission in order.
local function missionsScreen(font, r, m)
  local c = Screens.missions
  local kids = {}
  local function nodeAt(x, y, node) kids[#kids + 1] = at(x, y, node) end
  local width = r.w - 2 * L.pad
  local function wrapped(str, colorName)
    return { style = { maxWidth = width }, text = { text = str, font = font, size = T.body, color = UiTheme.color(colorName), wrap = true } }
  end
  local cur = m.current
  if cur then
    nodeAt(L.pad, L.pad, text(font, ("MISSION %d / %d"):format(cur.index, m.total), T.small, "dim"))
    nodeAt(L.pad, c.nameY, text(font, cur.name, T.heading, "cyan"))
    nodeAt(L.pad, c.goalY, wrapped(cur.goal, "text"))
    nodeAt(L.pad, c.hintY, wrapped("Hint: " .. cur.hint, "dim"))
    if cur.locked then
      nodeAt(L.pad, c.barY, text(font, cur.progressText, T.body, Theme.semantic.warning))
    else
      local barColor = cur.status == "complete" and "green" or "cyan"
      nodeAt(L.pad, c.barY, gauge({ height = c.barHeight, width = c.barWidth }, cur.percent, barColor))
      nodeAt(L.pad, c.barY + c.barHeight + 6, text(font, cur.progressText, T.small, cur.retry and Theme.semantic.warning or "text"))
      for i, line in ipairs(cur.lines) do
        nodeAt(L.pad, c.barY + c.barHeight + 28 + (i - 1) * 18, text(font, (line.done and "[x] " or "[ ] ") .. line.text, T.small, line.done and "green" or "dim"))
      end
    end
    nodeAt(L.pad, c.rewardY, text(font, cur.rewardText, T.body, "text"))
    if cur.claim then nodeAt(L.pad, c.buttonY, button(font, "Claim", cur.claim, "green", c.buttonWidth)) end
    if cur.retry then nodeAt(L.pad, c.buttonY, button(font, "Retry", cur.retry, Theme.semantic.warning, c.buttonWidth)) end
  else
    nodeAt(L.pad, L.pad, text(font, "ALL MISSIONS CLAIMED", T.heading, "green"))
  end
  for i, row in ipairs(m.rows) do
    local y = c.listY + (i - 1) * c.rowHeight
    local color = row.state == "claimed" and "green" or (row.state == "current" and "cyan" or "dim")
    nodeAt(L.pad, y, text(font, (row.state == "claimed" and "[x] " or "[ ] ") .. row.name, T.small, color))
    nodeAt(c.rewardX, y, text(font, row.reward, T.small, color))
  end
  for j, row in ipairs(m.optional) do
    local y = c.listY + (#m.rows + j - 1) * c.rowHeight
    local color = row.state == "claimed" and "green" or (row.failed and Theme.semantic.warning or (row.state == "current" and "cyan" or "dim"))
    nodeAt(L.pad, y, text(font, (row.state == "claimed" and "[x] " or "[ ] ") .. row.name .. "  " .. row.progressText, T.small, color))
    nodeAt(c.rewardX + c.optionalRewardOffset, y, text(font, row.reward, T.small, color))
    if row.claim then nodeAt(c.rewardX + c.optionalButtonOffset, y - 6, button(font, "Claim", row.claim, "green", 80)) end
    if row.retry then nodeAt(c.rewardX + c.optionalButtonOffset, y - 6, button(font, "Retry", row.retry, Theme.semantic.warning, 80)) end
  end
  return withChildren(panel(r, nil), kids)
end

-- Alerts (GR5-29, spec §8.7): the Monitor's hire button and settings, then the alert log newest first.
local function alertsScreen(font, r, m)
  local c = Screens.alerts
  local kids = {}
  local function nodeAt(x, y, node) kids[#kids + 1] = at(x, y, node) end
  nodeAt(L.pad, L.pad, text(font, "ALERTS  Monitor: " .. (m.hired and "hired" or "not hired"), T.small, "dim"))
  local x = L.pad
  if m.hire then
    nodeAt(x, c.controlsY, button(font, "Hire Monitor", m.hire, "green", c.buttonWidth))
  elseif m.hireNote then
    nodeAt(x, c.controlsY + 6, text(font, m.hireNote, T.small, Theme.semantic.warning))
  end
  if m.hired then
    nodeAt(x, c.controlsY, button(font, "Scope: " .. m.scope, m.scopeAction, "cyan", c.buttonWidth))
    x += c.buttonWidth + c.gap
    nodeAt(x, c.controlsY + 6, text(font, "Heartbeat " .. m.heartbeatText, T.small, "text"))
    x += 140
    nodeAt(x, c.controlsY, button(font, "-", m.heartbeatActions.down, "cyan", c.smallWidth))
    nodeAt(x + c.smallWidth + c.gap, c.controlsY, button(font, "+", m.heartbeatActions.up, "cyan", c.smallWidth))
    nodeAt(x + 2 * (c.smallWidth + c.gap), c.controlsY, button(font, "On / off", m.heartbeatActions.off, "dim", 90))
    for i, t in ipairs(m.types) do
      local col, row = (i - 1) % c.typesPerRow, math.floor((i - 1) / c.typesPerRow)
      nodeAt(L.pad + col * (c.typeWidth + c.gap), c.typesY + row * c.typeRowHeight,
        button(font, (t.on and "[x] " or "[ ] ") .. t.type, t.action, t.on and "cyan" or "dim", c.typeWidth))
    end
  end
  if #m.rows == 0 then
    nodeAt(L.pad, c.listY, text(font, Screens.empty.alerts.title .. ": " .. Screens.empty.alerts.hint, T.small, "dim"))
  end
  for i, row in ipairs(m.rows) do
    if i > c.maxRows then break end
    local line = ("%5ds ago  %-14s %-12s %-10s %s"):format(row.ageS, row.type, row.agent or "-", row.status, row.reason)
    local color = row.status == "queued" and Theme.semantic.warning or (row.status == "handled" and "green" or "dim")
    nodeAt(L.pad, c.listY + (i - 1) * c.rowHeight, text(font, line, T.small, color))
  end
  return withChildren(panel(r, nil), kids)
end

-- Branches (B-0, spec §15b.1): one row per branch with its state, agents and money per hour.
local function branchesScreen(font, r, m, time)
  local c = Screens.branches
  local kids = {}
  local function nodeAt(x, y, node) kids[#kids + 1] = at(x, y, node) end
  nodeAt(L.pad, L.pad, text(font, ("BRANCHES  command %d / %d"):format(m.used, m.capacity), T.small, "dim"))
  for i, row in ipairs(m.rows) do
    local y = c.rowY + (i - 1) * c.rowHeight
    local color = row.state == "open" and "green" or (row.state == "available" and "cyan" or "dim")
    local accent = row.state == "open" and 1 or (row.state == "available" and 0.55 or Theme.alpha.line)
    kids[#kids + 1] = Glow.accentBar(0, y - 2, c.rowHeight - 8, row.id, accent)
    if #row.agents > 0 then
      for _, n in ipairs(Glow.light({ x = L.pad + c.stateX + 72, y = y + 8 }, "acting", time)) do kids[#kids + 1] = n end
    end
    nodeAt(L.pad, y, text(font, row.name, T.body, color))
    nodeAt(L.pad + c.stateX, y, text(font, row.state, T.small, color))
    nodeAt(c.agentsX, y, text(font, #row.agents > 0 and table.concat(row.agents, ", ") or "no agents", T.small, "text"))
    if row.state == "open" then
      nodeAt(c.moneyX, y, text(font, ("%d cr/h   %.1f Compute/h"):format(row.creditsPerHour, row.computePerHour), T.small, "text"))
    elseif row.action then
      nodeAt(c.moneyX, y, button(font, ("Open %d cr"):format(row.cost), row.action, "green", c.buttonWidth))
    end
    if row.note then nodeAt(L.pad, y + c.noteGap, text(font, row.note, T.small, Theme.semantic.warning)) end
  end
  return withChildren(panel(r, nil), kids)
end

-- Archive tab strip and the studio's last message, shared by every Archive mode (GR5-26).
local function studioHeader(font, r, kids, sm)
  local c = Screens.studio
  for i, t in ipairs(sm.tabs) do
    kids[#kids + 1] = at(c.tabX + (i - 1) * (c.tabWidth + c.tabGap), L.pad, button(font, t.label, t.action, t.active and "cyan" or "dim", c.tabWidth))
  end
  if sm.message then
    kids[#kids + 1] = at(L.pad, r.h - 28, text(font, sm.message.text, T.small, sm.message.bad and Theme.semantic.warning or "green"))
  end
end

-- Rows of text and buttons (record, form, assign): laid out top to bottom from the studio's rowY.
local function studioRows(font, kids, rows)
  local c = Screens.studio
  local y = c.rowY
  for _, row in ipairs(rows) do
    local x = L.pad
    for _, cell in ipairs(row) do
      if cell.action then
        kids[#kids + 1] = at(x, y, button(font, cell.label, cell.action, cell.color, cell.w))
        x += cell.w + c.rowGap
      else
        kids[#kids + 1] = at(x, y + 6, text(font, cell.text, T.small, cell.color))
        x += (cell.w or (#cell.text * 7 + 8)) + c.rowGap
      end
    end
    y += c.rowHeight
  end
end

-- Team (GR5-28, spec §8.6): one monospace row per agent, a click opens its editor.
local function teamScreen(font, r, m, time)
  local c = Screens.team
  local kids = {}
  local function nodeAt(x, y, node, w, h) kids[#kids + 1] = at(x, y, node, w, h) end
  nodeAt(L.pad, L.pad, text(font, ("TEAM  command %d / %d"):format(m.used, m.capacity), T.small, "dim"))
  local fmt = "%-14s %-12s %-10s %-16s %9s %9s %6s  %s"
  nodeAt(L.pad, c.headerY + 8, text(font, fmt:format("agent", "asset", "mode", "state", "Compute/h", "net cr/h", "errors", "last alert"), T.small, "dim"))
  local y, rowW = c.rowY + 8, r.w - 2 * L.pad
  for _, row in ipairs(m.rows) do
    local line = fmt:format(row.id, row.asset, row.mode, row.state, ("%.1f"):format(row.computePerHour), Model.thousands(row.netPerHour), row.errors, row.lastAlert)
    local color = (row.state == "paused_error" or row.errors > 0) and Theme.tokens.alert.error or (row.netPerHour < 0 and Theme.tokens.alert.warning or "text")
    for _, n in ipairs(Glow.light({ x = L.pad - 6, y = y + c.rowHeight / 2 }, row.state, time)) do kids[#kids + 1] = n end
    nodeAt(L.pad, y, { style = { paddingX = 6, justify = "center" },
      background = { color = UiTheme.color("panel", 0), radius = 2 },
      button = UiTheme.button(row.action, "cyan", { base = "panel", alpha = 0 }),
      children = { text(font, line, T.small, color) } }, rowW, c.rowHeight)
    y += c.rowHeight
  end
  for _, ship in ipairs(m.idleShips) do
    nodeAt(L.pad, y + 4, text(font, ("%s  idle: %s"):format(ship.id, FleetView.why(ship.why) or "no agent"), T.small, Theme.semantic.warning))
    y += c.rowHeight
  end
  return withChildren(panel(r, nil), kids)
end

-- Archive (GR5-10, spec §13/§14; GR5-26 studio): company-wide skills with who runs them and with what values, the slot
-- count, the demo "Simulate 1 h away" button, the "While you were away" box, and the Record / New skill / Run-on tabs.
local function archiveScreen(font, r, m, sm)
  local c = Screens.archive
  local kids = {}
  local function nodeAt(x, y, node) kids[#kids + 1] = at(x, y, node) end
  nodeAt(L.pad, L.pad + 6, text(font, "ARCHIVE  " .. m.slots.text, T.small, "dim"))
  studioHeader(font, r, kids, sm)
  if m.simulateAway then nodeAt(r.w - L.pad - c.buttonWidth, L.pad, button(font, "Simulate 1 h away", m.simulateAway, "cyan", c.buttonWidth)) end
  if sm.rows then
    studioRows(font, kids, sm.rows)
    return withChildren(panel(r, nil), kids)
  end
  local y = c.rowY
  if #m.skills == 0 then
    nodeAt(L.pad, y, text(font, Screens.empty.archive.title .. ": " .. Screens.empty.archive.hint, T.small, "dim"))
    nodeAt(L.pad, y + c.rowHeight, text(font, "Use Record (from the feed) or New skill (the form) above.", T.small, "dim"))
  end
  for _, s in ipairs(m.skills) do
    local head = ("%s  (%s%s)  %s"):format(s.name, s.agentType, s.loop and ", loops" or "", table.concat(s.params, " "))
    nodeAt(L.pad, y, text(font, head, T.body, "cyan"))
    nodeAt(r.w - L.pad - 70, y, button(font, "Delete", s.delete, "dim", 70))
    y += c.rowHeight + 4
    for i, st in ipairs(s.steps) do
      nodeAt(L.pad + 12, y, text(font, ("%d. %s"):format(i, st), T.small, "text"))
      y += c.rowHeight
    end
    for _, u in ipairs(s.runners) do
      nodeAt(L.pad + 12, y, text(font, ("run by %s %s%s"):format(u.agent, u.params, u.aborted and ("  ABORTED: " .. u.aborted) or ""), T.small, u.aborted and Theme.semantic.error or "green"))
      nodeAt(r.w - L.pad - 70, y - 4, button(font, "Stop", u.stop, "dim", 70))
      if u.restart then nodeAt(r.w - L.pad - 70 - 8 - 90, y - 4, button(font, "Restart", u.restart, Theme.semantic.warning, 90)) end
      y += c.rowHeight
    end
    local x = L.pad + 12
    for _, a in ipairs(s.assigns) do
      nodeAt(x, y, button(font, a.label, a.action, "cyan", 150))
      x += 158
    end
    y += (#s.assigns > 0 and 34 or 0) + c.skillGap
  end
  if m.offline then
    local x = r.w - L.pad - c.offlineWidth
    local oy = c.offlineY + 40
    nodeAt(x, oy, text(font, m.offline.title:upper(), T.heading, "green"))
    for i, line in ipairs(m.offline.lines) do nodeAt(x, oy + 28 + (i - 1) * c.rowHeight, text(font, line, T.small, "text")) end
    nodeAt(x, oy + 36 + (#m.offline.lines) * c.rowHeight, button(font, "Dismiss", m.offline.dismiss, "cyan", c.dismissWidth))
  end
  return withChildren(panel(r, nil), kids)
end

-- Market (GR5-10, spec §6.3): price now, usual price, trend and best buyer per resource, then the latest notices.
local function marketScreen(font, r, m)
  local c = Screens.market
  local kids = {}
  local function nodeAt(x, y, node) kids[#kids + 1] = at(x, y, node) end
  nodeAt(L.pad, L.pad, text(font, "MARKET  who buys what, now (faint: usual price)", T.small, "dim"))
  local y = c.rowY
  for _, row in ipairs(m.rows) do
    local color = row.best and "green" or (row.event and Theme.semantic.warning or "text")
    nodeAt(L.pad, y, text(font, row.text .. (row.best and "  BEST" or "") .. (row.event and ("  " .. row.event) or ""), T.small, color))
    nodeAt(c.sparkX - 40, y, text(font, row.trend == "up" and "^" or (row.trend == "down" and "v" or "-"), T.small, "dim"))
    y += c.rowHeight
  end
  y += c.noticeGap
  for _, n in ipairs(m.notices) do
    nodeAt(L.pad, y, text(font, n, T.small, "dim"))
    y += c.rowHeight
  end
  return withChildren(panel(r, nil), kids)
end

-- Debug (spec §16.4, GR5-72): one row of buttons per action group, the status and result lines, then the last prompt.
local function debugScreen(font, r, m)
  local c = Screens.debug
  local kids = {}
  local function nodeAt(x, y, node) kids[#kids + 1] = at(x, y, node) end
  nodeAt(L.pad, L.pad, text(font, m.title .. "  not shipped in release builds", T.small, "dim"))
  local y = c.rowY
  for _, g in ipairs(m.groups) do
    nodeAt(L.pad, y + 6, text(font, g.label, T.small, "dim"))
    local x = L.pad + c.labelWidth
    for _, b in ipairs(g.buttons) do
      nodeAt(x, y, button(font, b.label, b.action, b.selected and "cyan" or "dim", c.buttonWidth))
      x += c.buttonWidth + c.buttonGap
    end
    y += c.rowHeight
  end
  y += c.statusGap
  nodeAt(L.pad, y, text(font, m.status, T.small, "text"))
  if m.toast then nodeAt(L.pad, y + c.toastGap, text(font, m.toast, T.small, "green")) end
  if m.promptTitle then
    y += c.promptGap + c.toastGap
    nodeAt(L.pad, y, text(font, m.promptTitle, T.small, "dim"))
    for i, line in ipairs(m.promptLines) do
      nodeAt(L.pad, y + c.toastGap + (i - 1) * c.promptLineHeight, text(font, line == "" and " " or line, T.small, "text"))
    end
  end
  return withChildren(panel(r, nil), kids)
end

-- The two text inputs, in their own tree (see config/screens.luau editor). `draft` gives their starting text.
function Shell.inputsSpec(draft, opts)
  opts = opts or {}
  local font = opts.font
  local f, e = Shell.editorFields(), Screens.editor
  local function field(rect, value: string, action: string, placeholder: string)
    return { style = { position = "absolute", left = rect.x, top = rect.y, width = rect.w, height = rect.h, justify = "center", paddingX = 8 },
      background = { color = UiTheme.color("bg"), radius = L.radius, borderColor = UiTheme.color("cyan", 0.5), borderWidth = 1 },
      text = { text = value, font = font, size = T.body, color = UiTheme.color("text") },
      input = { action = action, placeholder = placeholder } }
  end
  return { style = { position = "absolute", left = 0, top = 0, width = L.view.w, height = L.view.h },
    children = {
      field(f.directive, draft.directive, "editor.directive", e.placeholder.directive),
      field(f.order, draft.order, "editor.order", e.placeholder.order),
    } }
end

-- The HMC emergency-advance banner (spec §8.5): text and a Claim button, over the top right of the main panel.
local function noticeBanner(font, r, n)
  local c = Screens.notice
  local btn = buttonNode({ width = c.buttonWidth, height = 28, justify = "center", alignItems = "center" }, n.action, "cyan",
    { text(font, n.button, T.small, "cyan") }, true)
  local textW = c.width - c.buttonWidth - 3 * L.pad
  return withChildren(panel({ x = r.x + r.w - c.width - c.margin, y = r.y + c.margin, w = c.width, h = c.height },
    { direction = "row", alignItems = "center", gap = 12, paddingX = L.pad }, true),
    { text(font, Fit.truncate(n.text, T.small, textW), T.small, Theme.semantic.warning, { width = textW }), btn })
end

-- The whole screen as a spec for engine.ui.spawn. opts = { font, tab = "editor"|"context", logs = LogsView.new() state, skin = UiTheme.panelSkin() or nil, glitch = frame params of Glitch.update or nil }.
function Shell.spec(sim, screenId: string, opts)
  opts = opts or {}
  skin = opts.skin
  local font = opts.font
  local rects = Shell.layout()
  if not Model.screenVisible(sim.tier, screenId) then screenId = Screens.defaultScreen end
  local bar = Model.topBar(sim)
  local children = {
    topBar(font, rects.top, bar),
    nav(font, rects.nav, Model.nav(sim.tier, screenId), screenId),
    feedStrip(font, rects.feed, Model.feed(sim)),
  }
  if screenId == Screens.defaultScreen then
    -- The map panel is transparent over the world: planets are drawn behind it, labels and routes in front.
    local mapPanel = panel(rects.main, nil, true)
    mapPanel.background.color = UiTheme.color("panel", 0)
    children[#children + 1] = mapPanel
    for _, n in ipairs(mapOverlay(font, rects.main, Model.map(sim), opts)) do children[#children + 1] = n end
  elseif screenId == "agents" and sim.agents[Screens.editor.agent] then
    local id = Screens.editor.agent
    local a, b
    if opts.tab == "context" then
      a, b = contextScreen(font, rects.main, ComputeView.contextPanel(sim, id))
    else
      local compute = { rows = ComputeView.agentRows(sim), top = ComputeView.topBar(sim), cfg = sim.compute.cfg,
        buy = ComputeView.buyOptions(sim, Screens.compute.packs) }
      a, b = editorScreen(font, rects.main, Editor.model(sim, id, opts.draft), { toast = opts.toast, presets = Editor.presets(sim), compute = compute, state = sim.agents[id].state, time = opts.time })
    end
    children[#children + 1] = a
    children[#children + 1] = b
  elseif screenId == "logs" and LogsView.total(sim) > 0 then
    local m = LogsView.model(sim, opts.logs or LogsView.new())
    if m.compare then
      children[#children + 1] = compareScreen(font, rects.main, m.compare)
    else
      local a, b = logsScreen(font, rects.main, m)
      children[#children + 1] = a
      children[#children + 1] = b
    end
  elseif screenId == "shop" then
    children[#children + 1] = shopScreen(font, rects.main, ShopView.model(sim))
  elseif screenId == "fleet" and sim.tier >= 4 then
    children[#children + 1] = fleetScreen(font, rects.main, FleetView.model(sim), opts.time or 0)
  elseif screenId == "team" then
    children[#children + 1] = teamScreen(font, rects.main, TeamView.model(sim), opts.time or 0)
  elseif screenId == "missions" then
    children[#children + 1] = missionsScreen(font, rects.main, MissionsView.model(sim))
  elseif screenId == "branches" and sim.tier >= 2 then
    children[#children + 1] = branchesScreen(font, rects.main, BranchesView.model(sim), opts.time or 0)
  elseif screenId == "alerts" and sim.tier >= 5 then
    children[#children + 1] = alertsScreen(font, rects.main, AlertsView.model(sim))
  elseif screenId == "archive" then
    children[#children + 1] = archiveScreen(font, rects.main, ArchiveView.model(sim), Studio.model(sim, opts.studio or Studio.new()))
  elseif screenId == "station" and sim:hasWarehouse() then
    children[#children + 1] = stationScreen(font, rects.main, StationView.model(sim, opts.station), opts.time or 0)
  elseif screenId == "debug" and Model.screenVisible(sim.tier, "debug") then
    children[#children + 1] = debugScreen(font, rects.main, DebugPanel.model(sim, opts.debug or DebugPanel.new()))
  elseif screenId == "market" and sim:hasWarehouse() then
    children[#children + 1] = marketScreen(font, rects.main, MarketView.model(sim))
  else
    children[#children + 1] = empty(font, rects.main, screenId)
  end
  local notice = Model.notification(sim)
  if notice then children[#children + 1] = noticeBanner(font, rects.main, notice) end
  for _, n in ipairs(Glow.glitch(opts.glitch, rects)) do children[#children + 1] = n end
  local shift = opts.glitch and opts.glitch.slices[1] and opts.glitch.slices[1].shift or 0
  return Fit.apply({
    style = { position = "absolute", left = shift, top = 0, width = L.view.w, height = L.view.h },
    children = children,
  }, L.view.w), screenId
end

-- Glitch hook: the shell glitches only when an agent enters paused_error (art direction). Anything else is refused by
-- render/vfx/glitch.luau. Call `Shell.update` every frame and pass the result to Shell.spec as `opts.glitch`.
function Shell.new() return { screen = Screens.defaultScreen, glitch = Glitch.new(), focus = nil } end

-- Map hover / select: "map.focus.<id>" focuses a planet or market (its routes glow); the same click again clears it.
function Shell.act(state, action): boolean
  if type(action) ~= "string" then return false end
  local id = action:match("^map%.focus%.([%w_]+)$")
  if not id then return false end
  state.focus = (state.focus ~= id) and id or nil
  return true
end
function Shell.onSimEvent(state, event) if event.name == "agent_paused_error" then return Glitch.trigger(state.glitch, "ai_error") end return false end
function Shell.update(state, dt: number) return Glitch.update(state.glitch, dt) end

-- Nav click: "nav.logs" -> "logs" when that screen is visible at this tier.
function Shell.parseAction(action, tier: number)
  if type(action) ~= "string" or string.sub(action, 1, 4) ~= "nav." then return nil end
  local id = string.sub(action, 5)
  return Model.screenVisible(tier, id) and id or nil
end

function Shell.spawn(commands, sim, screenId: string, opts)
  opts = opts or {}
  opts.font = opts.font or UiTheme.font()
  opts.skin = opts.skin or UiTheme.panelSkin()
  local spec, shown = Shell.spec(sim, screenId, opts)
  return engine.ui.spawn(commands, spec), shown
end

return Shell
