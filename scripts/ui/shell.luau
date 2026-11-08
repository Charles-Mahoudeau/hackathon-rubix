-- The UI shell (GR5-3): top bar, left nav, main panel, bottom agent feed, and the system map drawn over the main panel.
-- Everything here is a pure description (engine.ui specs) built from ui/shell_model.luau, so it can be tested headless;
-- only Shell.spawn touches the engine. Colours come from config/theme.luau through ui/theme.luau, nothing else.
-- Panels are a Pixel Holo UI nine-patch image tinted by the theme (opts.skin, from UiTheme.panelSkin). Without a skin
-- (headless tests) they fall back to a translucent node with a hairline border. Neither bakes a glow: the only bloom is
-- the neon of a lit thing (spec art rule), never a panel (see DECISIONS.md, Pixel Holo UI).
local Theme = require("@scripts/config/theme")
local Screens = require("@scripts/config/screens")
local UiTheme = require("@scripts/ui/theme")
local Model = require("@scripts/ui/shell_model")
local Editor = require("@scripts/ui/agent_editor")
local ComputeView = require("@scripts/ui/compute_view")
local LogsView = require("@scripts/ui/logs_view")
local ShopView = require("@scripts/ui/shop_view")
local MissionsView = require("@scripts/ui/missions_view")
local ArchiveView = require("@scripts/ui/archive_view")
local MarketView = require("@scripts/ui/market_view")
local Glitch = require("@scripts/render/vfx/glitch")

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
  local node = { style = { rect(r), extra }, children = {} }
  if skin and not plain then
    node.image = { texture = skin.texture, slice = skin.slice, color = skin.color }
  else
    node.background = { color = UiTheme.panel(), radius = L.radius, borderColor = UiTheme.line(), borderWidth = 1 }
  end
  return node
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
      { style = { height = 8, width = "100%" }, background = { color = UiTheme.color("dim", Theme.alpha.line), radius = 2 },
        children = { { style = { height = "100%", width = ("%d%%"):format(math.floor(bar.computeFraction * 100)) },
          background = { color = UiTheme.color(bar.budgetReached and Theme.semantic.warning or gaugeColor), radius = 2 } } } },
    } }
  -- Always offered: the button is greyed, never hidden, when the credits do not cover the pack (it then does nothing).
  local buyColor = bar.buy.affordable and "cyan" or "dim"
  local buy = { style = { width = 176, height = 28, justify = "center", alignItems = "center" },
    background = { color = UiTheme.color("panel"), radius = L.radius, borderColor = UiTheme.color(buyColor, 0.6), borderWidth = 1 },
    button = { action = bar.buy.action, hovered = UiTheme.hover(buyColor), pressed = UiTheme.pressed(buyColor) },
    children = { text(font, bar.buy.text, T.small, buyColor) } }
  local children = {
    text(font, "GRIDMIND", T.heading, "cyan", { marginRight = 16 }),
    cell("Credits", bar.creditsText, "text"),
    gauge,
    buy,
    cell("Reputation", repLine, "text"),
    cell("Tier", bar.tierText, "green"),
  }
  if bar.budgetReached then children[#children + 1] = text(font, bar.budgetMessage, T.small, Theme.semantic.warning) end
  return withChildren(panel(r, { direction = "row", alignItems = "center", gap = 24, paddingX = L.pad }), children)
end

local function nav(font, r, entries, screenId)
  local items = {}
  for _, e in ipairs(entries) do
    items[#items + 1] = {
      style = { paddingX = L.pad, paddingY = 8, direction = "row", alignItems = "center" },
      background = { color = e.active and UiTheme.hover("cyan") or UiTheme.color("panel", 0), radius = L.radius,
        borderColor = e.active and UiTheme.color("cyan", Theme.alpha.line) or nil, borderWidth = e.active and 1 or nil },
      button = { action = "nav." .. e.id, hovered = UiTheme.hover("cyan"), pressed = UiTheme.pressed("cyan") },
      children = { text(font, e.label, T.body, e.active and "cyan" or "text") },
    }
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
  for _, l in ipairs(lines) do
    local color = l.status == "failed" and Theme.semantic.error or (l.status == "running" and "dim" or "text")
    rows[#rows + 1] = text(font, (l.agent and (l.agent .. "  ") or "") .. l.text, T.small, color)
  end
  return withChildren(panel(r, { direction = "column", padding = L.gap, overflow = "hidden" }), rows)
end

-- Dash positions along a route A -> B, skipping the planet discs at both ends. Pure; spacing in view pixels.
function Shell.dashes(a, b, skipA: number, skipB: number, spacing: number)
  local dx, dy = b.x - a.x, b.y - a.y
  local len = math.sqrt(dx * dx + dy * dy)
  local out = {}
  if len < 1 then return out end
  local n = math.floor(len / spacing)
  for i = 1, n - 1 do
    local d = i * spacing
    if d > skipA and d < len - skipB then out[#out + 1] = { x = a.x + dx * d / len, y = a.y + dy * d / len } end
  end
  return out
end

local function dot(center, size: number, colorName: string, alpha: number?)
  return { style = { position = "absolute", left = center.x - size / 2, top = center.y - size / 2, width = size, height = size },
    background = { color = UiTheme.color(colorName, alpha), radius = size / 2 } }
end

local function mapOverlay(font, r, map)
  local cfg = Screens.map
  local nodes = {}
  local points = {}
  for _, p in ipairs(map.planets) do points[p.id] = Shell.mapPoint(p.x, p.y) end
  for _, m in ipairs(map.markets) do points[m.id] = Shell.mapPoint(m.x, m.y) end
  local routeColor = { safe = "cyan", risky = Theme.semantic.warning }

  for _, route in ipairs(map.routes) do
    local a, b = points[route.from], points[route.to]
    for _, d in ipairs(Shell.dashes(a, b, cfg.planetRadius + 6, 14, cfg.routeSpacing)) do
      nodes[#nodes + 1] = dot(d, cfg.routeThickness, routeColor[route.color], 0.55)
    end
  end
  for _, c in ipairs(map.convoys) do
    local a, b = points[c.from], points[c.to]
    nodes[#nodes + 1] = dot({ x = a.x + (b.x - a.x) * c.t, y = a.y + (b.y - a.y) * c.t }, cfg.convoyDot, "text")
  end

  local function label(center, name, sub, colorName, subColor, below)
    return { style = { position = "absolute", left = center.x - 90, top = center.y + below, width = 180, alignItems = "center", direction = "column", gap = 2 },
      children = { text(font, name, T.body, colorName), sub and text(font, sub, T.small, subColor or "dim") or nil } }
  end
  for _, p in ipairs(map.planets) do
    local c = points[p.id]
    local sub = p.lit and table.concat(p.ores, ", ") or ("Locked: " .. p.condition)
    nodes[#nodes + 1] = label(c, p.name, sub, p.lit and "text" or "dim", p.lit and "dim" or Theme.semantic.warning, cfg.planetRadius + 8)
  end
  for _, m in ipairs(map.markets) do
    local c = points[m.id]
    nodes[#nodes + 1] = { style = { position = "absolute", left = c.x - 9, top = c.y - 9, width = 18, height = 18 },
      background = { color = UiTheme.color("panel"), radius = 3, borderColor = UiTheme.color("cyan"), borderWidth = 1 } }
    nodes[#nodes + 1] = label(c, m.name, ("T%d market"):format(m.tier), "text", "dim", 14)
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
  return { style = { width = w, height = 28, justify = "center", alignItems = "center" },
    background = { color = UiTheme.color("panel"), radius = L.radius, borderColor = UiTheme.color(colorName, 0.6), borderWidth = 1 },
    button = { action = action, hovered = UiTheme.hover(colorName), pressed = UiTheme.pressed(colorName) },
    children = { text(font, label, T.small, colorName) } }
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
      button = { action = row.action, hovered = UiTheme.hover("cyan"), pressed = UiTheme.pressed("cyan") },
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
      nodeAt(L.pad, c.barY, { style = { height = c.barHeight, width = c.barWidth },
        background = { color = UiTheme.color("dim", Theme.alpha.line), radius = 2 },
        children = { { style = { height = "100%", width = ("%d%%"):format(cur.percent) },
          background = { color = UiTheme.color(barColor), radius = 2 } } } })
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
  return withChildren(panel(r, nil), kids)
end

-- Archive (GR5-10, spec §13/§14): company-wide skills with who runs them, the slot count, the demo "Simulate 1 h away"
-- button and the "While you were away" box.
local function archiveScreen(font, r, m)
  local c = Screens.archive
  local kids = {}
  local function nodeAt(x, y, node) kids[#kids + 1] = at(x, y, node) end
  nodeAt(L.pad, L.pad, text(font, "ARCHIVE  " .. m.slots.text .. "  skills run with zero Compute", T.small, "dim"))
  if m.simulateAway then nodeAt(r.w - L.pad - c.buttonWidth, L.pad, button(font, "Simulate 1 h away", m.simulateAway, "cyan", c.buttonWidth)) end
  local y = c.rowY
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
      if u.restart then nodeAt(r.w - L.pad - 90, y - 4, button(font, "Restart", u.restart, Theme.semantic.warning, 90)) end
      y += c.rowHeight
    end
    y += c.skillGap
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
    for _, n in ipairs(mapOverlay(font, rects.main, Model.map(sim))) do children[#children + 1] = n end
  elseif screenId == "agents" and sim.agents[Screens.editor.agent] then
    local id = Screens.editor.agent
    local a, b
    if opts.tab == "context" then
      a, b = contextScreen(font, rects.main, ComputeView.contextPanel(sim, id))
    else
      local compute = { rows = ComputeView.agentRows(sim), top = ComputeView.topBar(sim), cfg = sim.compute.cfg,
        buy = ComputeView.buyOptions(sim, Screens.compute.packs) }
      a, b = editorScreen(font, rects.main, Editor.model(sim, id, opts.draft), { toast = opts.toast, presets = Editor.presets(sim), compute = compute })
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
  elseif screenId == "missions" then
    children[#children + 1] = missionsScreen(font, rects.main, MissionsView.model(sim))
  elseif screenId == "archive" and (sim.skills and next(sim.skills) or sim.lastOfflineReport) then
    children[#children + 1] = archiveScreen(font, rects.main, ArchiveView.model(sim))
  elseif screenId == "market" and sim:hasWarehouse() then
    children[#children + 1] = marketScreen(font, rects.main, MarketView.model(sim))
  else
    children[#children + 1] = empty(font, rects.main, screenId)
  end
  local shift = opts.glitch and opts.glitch.slices[1] and opts.glitch.slices[1].shift or 0
  return {
    style = { position = "absolute", left = shift, top = 0, width = L.view.w, height = L.view.h },
    children = children,
  }, screenId
end

-- Glitch hook: the shell glitches only when an agent enters paused_error (art direction). Anything else is refused by
-- render/vfx/glitch.luau. Call `Shell.update` every frame and pass the result to Shell.spec as `opts.glitch`.
function Shell.new() return { screen = Screens.defaultScreen, glitch = Glitch.new() } end
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
