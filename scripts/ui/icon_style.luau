-- Global IconStyle (no require in AYLO; IconSet is loaded first by sorted order). Resolves icon tint + glow from state. Colors come ONLY from the shared theme table (GR5-3);
-- the fallback below is a placeholder until that table lands (same keys: dim, text, cyan, warn, danger, ok).

IconStyle = {}

local FALLBACK_THEME = {
	dim = "#5b6b7a", text = "#c9d6e2", cyan = "#19e6ff", ok = "#3dff9a", warn = "#ffb020", danger = "#ff3860",
}

-- Active neon per icon kind; status icons may override via opts.status ("ok"|"warn"|"danger").
local ACTIVE_KEY = { resource = "cyan", tool = "cyan", agent = "cyan" }

-- Returns { file, color, glow, glow_color } for an icon key like "tool.mine".
-- Idle: flat dim color, glow = false. Active: neon color, glow = true (the ONLY case with bloom).
function IconStyle.resolve(key, active, theme, opts)
	local def = IconSet.icons[key]
	assert(def, "unknown icon: " .. tostring(key))
	theme = theme or FALLBACK_THEME
	local kind = string.match(key, "^(%w+)%.")
	if not active then
		return { file = def.file, color = theme.dim, glow = false }
	end
	local neon = theme[(opts and opts.status) or ACTIVE_KEY[kind] or "cyan"]
	return { file = def.file, color = neon, glow = true, glow_color = neon }
end

