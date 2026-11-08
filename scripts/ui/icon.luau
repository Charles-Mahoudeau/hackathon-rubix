-- Icons in the UI (GR5-53): a square image node from ui/icon_set.luau, tinted from the palette through UiImage.color. The
-- PNGs are white, so the tint is the whole colour: dim at rest, a neon when the thing is active or in trouble.
local IconSet = require("@scripts/ui/icon_set")
local UiTheme = require("@scripts/ui/theme")

local Icon = {}

-- The engine's texture loader (set by Shell.spawn on the client). Without one (headless tests) the texture is the file path.
-- A local, not a field: the engine freezes loaded module tables, so Icon.loader = x would fail at runtime.
local loader = nil
function Icon.useLoader(fn) loader = loader or fn end

local textures = {}
function Icon.texture(file: string)
	if not loader then return file end
	textures[file] = textures[file] or loader(file)
	return textures[file]
end

local function keyOf(kind: string, name)
	local key = kind .. "." .. tostring(name)
	return IconSet.icons[key] and key or nil
end

function Icon.toolKey(tool) return keyOf("tool", tool) end
function Icon.agentKey(agentType) return keyOf("agent", agentType) end
function Icon.resourceKey(resource) return keyOf("resource", resource) end

-- Where an agent log / feed line says "miner_1": the type is its name without the number.
function Icon.agentKeyOfId(id) return Icon.agentKey(string.match(tostring(id), "^(%a+)")) end

-- The icon, `size` px square, tinted `colorName` (a palette name). A missing key gives an empty box of the same size, so
-- a column of icons stays aligned when one row has none.
function Icon.node(key, size: number, colorName: string?, alpha: number?)
	local style = { width = size, height = size, shrink = 0, ignorePointer = true }
	if not key then return { style = style } end
	local def = IconSet.icons[key]
	assert(def, "unknown icon: " .. tostring(key))
	return { style = style, image = { texture = Icon.texture(def.file), color = UiTheme.color(colorName or "dim", alpha) } }
end

-- The same, at an absolute position (view or parent pixels).
function Icon.at(key, x: number, y: number, size: number, colorName: string?, alpha: number?)
	local node = Icon.node(key, size, colorName, alpha)
	node.style = { node.style, { position = "absolute", left = x, top = y } }
	return node
end

return Icon
