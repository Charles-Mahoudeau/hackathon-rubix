-- Resolves icon tint + glow from state. Colors come ONLY from the shared theme (config/theme.luau, GR5-3), as sRGB
-- { r, g, b, a } through ui/theme.luau; `theme` may override with a table of the same keys.
local IconSet = require("@scripts/ui/icon_set")
local UiTheme = require("@scripts/ui/theme")
local Theme = require("@scripts/config/theme")

local IconStyle = {}

-- Status keys -> palette names; the neon of an icon is picked from here.
local KEYS = { dim = "dim", text = "text", cyan = "cyan", ok = Theme.semantic.success, warn = Theme.semantic.warning,
	danger = Theme.semantic.error }
local function themed(key) return UiTheme.rgba(KEYS[key]) end

-- Active neon per icon kind; status icons may override via opts.status ("ok"|"warn"|"danger").
local ACTIVE_KEY = { resource = "cyan", tool = "cyan", agent = "cyan" }

-- Returns { file, color, glow, glow_color } for an icon key like "tool.mine".
-- Idle: flat dim color, glow = false. Active: neon color, glow = true (the ONLY case with bloom).
function IconStyle.resolve(key, active, theme, opts)
	local def = IconSet.icons[key]
	assert(def, "unknown icon: " .. tostring(key))
	local kind = string.match(key, "^(%w+)%.")
	if not active then
		return { file = def.file, color = theme and theme.dim or themed("dim"), glow = false }
	end
	local key2 = (opts and opts.status) or ACTIVE_KEY[kind] or "cyan"
	local neon = theme and theme[key2] or themed(key2)
	return { file = def.file, color = neon, glow = true, glow_color = neon }
end

return IconStyle
