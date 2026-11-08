-- Glow and glitch as UI nodes (M9). Pure descriptions over config/vfx.luau, like the rest of the shell, so they test headless.
-- A halo is a stack of translucent discs or rings; every node ignores the pointer, so a glow never steals a click.
local Vfx = require("@scripts/config/vfx")
local Theme = require("@scripts/config/theme")
local Halo = require("@scripts/render/vfx/halo")
local UiTheme = require("@scripts/ui/theme")

local Glow = {}

local G = Vfx.glow

-- Halo name of an agent / ship state ("acting" -> "active", "paused_error" -> "error", unknown -> "idle").
function Glow.haloOf(state: string?): string
	return Vfx.haloOfState[state or "idle"] or "idle"
end

-- Palette name of the light of a state (config/theme.luau tokens.state).
function Glow.colorOf(state: string?): string
	return Theme.tokens.state[state or "idle"] or Theme.tokens.state.idle
end

local function circle(cx: number, cy: number, r: number, background)
	return { style = { position = "absolute", left = cx - r, top = cy - r, width = r * 2, height = r * 2, ignorePointer = true },
		background = background }
end

-- Stack of layers around `center`. filled = discs (state lights), else border rings (round things that must stay visible
-- under it: planets, nodes). `colorName` overrides the halo colour (a planet glows in its own neon).
function Glow.halo(center, radius: number, haloName: string, t: number, filled: boolean, colorName: string?)
	local style = Halo.style(haloName, t)
	local name = colorName or Vfx.halo[haloName].color
	local out = {}
	for i = G.layers, 1, -1 do
		local r = radius * style.radius + (i - 1) * G.spread
		local alpha = style.alpha * G.alphaStep ^ i
		out[#out + 1] = circle(center.x, center.y, r, filled and { color = UiTheme.color(name, alpha), radius = r }
			or { color = UiTheme.color(name, 0), radius = r, borderColor = UiTheme.color(name, alpha), borderWidth = 2 })
	end
	return out
end

-- The state light next to a row: a dot in the state's colour, with its halo (idle has a faint one, error pulses).
function Glow.light(center, state: string?, t: number)
	local nodes = Glow.halo(center, G.dot / 2, Glow.haloOf(state), t, true, Glow.colorOf(state))
	local r = G.dot / 2
	nodes[#nodes + 1] = circle(center.x, center.y, r, { color = UiTheme.color(Glow.colorOf(state)), radius = r })
	return nodes
end

-- Slow pulsing ring around a lit planet, in the planet's own neon.
function Glow.planetRing(center, planetRadius: number, colorName: string, t: number)
	local pulse = 0.7 + 0.3 * math.sin(t * G.planet.pulseHz * 2 * math.pi)
	local r = planetRadius + G.planet.pad
	local base = Vfx.halo.idle.alpha * pulse
	local out = {}
	for i = G.layers, 1, -1 do
		local ri = r + (i - 1) * G.spread
		out[#out + 1] = circle(center.x, center.y, ri, { color = UiTheme.color(colorName, 0), radius = ri,
			borderColor = UiTheme.color(colorName, base * G.alphaStep ^ (i - 1)), borderWidth = 2 })
	end
	return out
end

-- Accent bar at the left of a branch row, in the branch colour; `alpha` says open / available / locked.
function Glow.accentBar(x: number, y: number, h: number, branch: string, alpha: number)
	local name = Theme.tokens.branch[branch] or Theme.tokens.text.secondary
	return { style = { position = "absolute", left = x, top = y, width = G.accentBar, height = h, ignorePointer = true },
		background = { color = UiTheme.color(name, alpha), radius = 1 } }
end

-- The error glitch drawn over the shell: a few hair-thin amber bars with a cyan / magenta split under each, shifted by the
-- frame's slices. It stays above the top bar and the main panel and never enters the feed strip, where the error reason is
-- written, and it ignores the pointer, so it hides no text and blocks no click. rects = Shell.layout(), frame = Glitch.update.
function Glow.glitch(frame, rects)
	local c = Vfx.glitchOverlay
	local out = {}
	if not frame then return out end
	local top, bottom = rects.top.y, rects.feed.y - c.barHeight - c.splitHeight - 1
	local left, width = rects.nav.x, rects.main.x + rects.main.w - rects.nav.x
	for i, slice in ipairs(frame.slices) do
		if i > c.maxBars then break end
		local y = top + slice.y * (bottom - top)
		local x = left + slice.shift
		local function bar(dy: number, h: number, dx: number, colorName: string, alpha: number)
			out[#out + 1] = { style = { position = "absolute", left = x + dx, top = y + dy, width = width, height = h, ignorePointer = true },
				background = { color = UiTheme.color(colorName, alpha) } }
		end
		bar(0, c.barHeight, 0, "amber", frame.scanlineAlpha)
		bar(c.barHeight, c.splitHeight, frame.rgbSplitPx, "cyan", c.flashAlpha * frame.scanlineAlpha)
		bar(c.barHeight, c.splitHeight, -frame.rgbSplitPx, "magenta", c.flashAlpha * frame.scanlineAlpha)
	end
	return out
end

return Glow
