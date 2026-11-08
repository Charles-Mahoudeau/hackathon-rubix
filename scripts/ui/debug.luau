-- Debug panel view (spec §16.4). Client side. `entries` is the panel as data; `spawn` draws it with rtype.Ui and needs
-- the "rtype.Ui" plugin. Each button's action is "debug.<name>"; the click handler maps it with parseAction and sends the
-- `debug_<name>` message to the server, which calls Debug.run (scripts/sim/debug.luau). Not yet run inside the engine.
local DebugPanel = {}

DebugPanel.entries = {
  { name = "addCredits", label = "+ Credits" },
  { name = "addCompute", label = "+ Compute" },
  { name = "setTier", label = "Set tier" },
  { name = "revealVeins", label = "Reveal all veins" },
  { name = "triggerShortage", label = "Trigger shortage" },
  { name = "simulateAway", label = "Simulate 1 h away", args = { hours = 1 } },
  { name = "setProvider", label = "Provider: stub / rubix" },
  { name = "lastPrompt", label = "Show last prompt" },
  { name = "resetSave", label = "Reset save" },
}

local PREFIX = "debug."

function DebugPanel.actionOf(entry) return PREFIX .. entry.name end

-- "debug.addCredits" -> "addCredits"; nil for any other action.
function DebugPanel.parseAction(action)
  if type(action) ~= "string" or string.sub(action, 1, #PREFIX) ~= PREFIX then return nil end
  local name = string.sub(action, #PREFIX + 1)
  for _, e in ipairs(DebugPanel.entries) do if e.name == name then return name end end
  return nil
end

-- style = { font, text, panel, button, hovered } (colours as { r, g, b, a }); the theme (GR5-3) supplies them.
function DebugPanel.spawn(commands, style)
  local children = {}
  for _, e in ipairs(DebugPanel.entries) do
    children[#children + 1] = {
      style = { padding = 6, justify = "center" },
      background = { color = style.button, radius = 4 },
      button = { action = DebugPanel.actionOf(e), normal = style.button, hovered = style.hovered },
      children = { { text = { text = e.label, font = style.font, size = 14, color = style.text } } },
    }
  end
  return engine.ui.spawn(commands, {
    style = { position = "absolute", right = 16, bottom = 16, padding = 8, gap = 6 },
    background = { color = style.panel, radius = 6 },
    children = children,
  })
end

return DebugPanel
