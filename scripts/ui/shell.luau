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
  local gauge = { style = { direction = "column", gap = 4, justify = "center", width = 190 },
    children = {
      text(font, "Compute  " .. bar.computeText, T.small, "dim"),
      { style = { height = 8, width = "100%" }, background = { color = UiTheme.color("dim", Theme.alpha.line), radius = 2 },
        children = { { style = { height = "100%", width = ("%d%%"):format(math.floor(bar.computeFraction * 100)) },
          background = { color = UiTheme.color(bar.budgetReached and Theme.semantic.warning or gaugeColor), radius = 2 } } } },
    } }
  return withChildren(panel(r, { direction = "row", alignItems = "center", gap = 32, paddingX = L.pad }), {
    text(font, "GRIDMIND", T.heading, "cyan", { marginRight = 16 }),
    cell("Credits", bar.creditsText, "text"),
    gauge,
    cell("Reputation", repLine, "text"),
    cell("Tier", bar.tierText, "green"),
  })
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

local function editorScreen(font, r, m, opts)
  local e = Screens.editor
  local counterColor = function(c) return c.amber and Theme.semantic.warning or "dim" end
  local left = {}
  local function nodeAt(x, y, node) left[#left + 1] = at(x, y, node) end
  nodeAt(L.pad, L.pad, text(font, "AGENT EDITOR  " .. m.agentId, T.small, "dim"))
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
  local leftPanel = panel({ x = r.x, y = r.y, w = e.leftWidth, h = r.h }, nil)
  withChildren(leftPanel, left)

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
  for _, f in ipairs(m.formats) do
    rows[#rows + 1] = text(font, ("Context %-7s %5d tokens%s"):format(f.format, f.context, f.active and "  (in use)" or ""), T.small, f.active and "cyan" or "dim")
  end
  rows[#rows + 1] = text(font, "", T.small, "dim")
  rows[#rows + 1] = text(font, "TOOLS (each one is paid in every prompt)", T.small, "dim")
  for _, t in ipairs(m.tools) do rows[#rows + 1] = text(font, ("%-8s %4d tokens"):format(t.name, t.tokens), T.small, "text") end
  rows[#rows + 1] = text(font, ("Skill slots %d / %d"):format(m.skills.used, m.skills.slots), T.small, "dim")
  local rightPanel = panel({ x = r.x + e.costX, y = r.y, w = r.w - e.costX, h = r.h }, { direction = "column", gap = 4, padding = L.pad, overflow = "hidden" })
  return leftPanel, withChildren(rightPanel, rows)
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

-- The whole screen as a spec for engine.ui.spawn. opts = { font, skin = UiTheme.panelSkin() or nil, glitch = frame params of Glitch.update or nil }.
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
    local a, b = editorScreen(font, rects.main, Editor.model(sim, id, opts.draft), { toast = opts.toast, presets = Editor.presets(sim) })
    children[#children + 1] = a
    children[#children + 1] = b
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
