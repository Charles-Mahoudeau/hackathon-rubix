-- M9 art pass: the design tokens stay inside the palette, glows and the error glitch are drawn as the spec says, and the
-- map animates. Presentation only; nothing here touches the sim beyond reading it. Headless.
local Theme = require("@scripts/config/theme")
local Screens = require("@scripts/config/screens")
local Vfx = require("@scripts/config/vfx")
local Sim = require("@scripts/sim/sim")
local UiTheme = require("@scripts/ui/theme")
local Shell = require("@scripts/ui/shell")
local Glow = require("@scripts/ui/glow")
local Halo = require("@scripts/render/vfx/halo")
local Glitch = require("@scripts/render/vfx/glitch")

local function walk(spec, fn) fn(spec) for _, c in ipairs(spec.children or {}) do walk(c, fn) end end
local function collect(spec, pred) local out = {} walk(spec, function(n) if pred(n) then out[#out + 1] = n end end) return out end

-- tokens: every value is a palette colour; every branch and every agent state has one
for group, tokens in pairs(Theme.tokens) do
  for name, colour in pairs(tokens) do assert(Theme.palette[colour], ("tokens.%s.%s = '%s' is not in the palette"):format(group, name, tostring(colour))) end
end
local sim = Sim.new()
for _, def in ipairs(sim.registry.list) do assert(Theme.tokens.branch[def.id], "no accent for branch " .. def.id) end
for _, state in ipairs({ "idle", "acting", "paused_error" }) do assert(Theme.tokens.state[state], "no light for state " .. state) end
assert(Glow.colorOf("never_heard_of_it") == Theme.tokens.state.idle and Glow.haloOf(nil) == "idle", "unknown states fall back to idle")

-- halos: idle / active / error are distinct, error pulses, and every halo + state mapping names a real halo and colour
for name, h in pairs(Vfx.halo) do assert(Theme.palette[h.color], "halo " .. name) end
for state, halo in pairs(Vfx.haloOfState) do assert(Vfx.halo[halo], "haloOfState." .. state .. " -> " .. halo) end
assert(Glow.haloOf("paused_error") == "error" and Glow.haloOf("acting") == "active" and Glow.haloOf("idle") == "idle")
assert(Halo.style("error", 0).color[1] > Halo.style("active", 0).color[1], "error is warm, active is cool")
assert(Halo.style("error", 0.1).alpha ~= Halo.style("error", 0.3).alpha, "the error halo pulses")
assert(Halo.style("active", 0.1).alpha == Halo.style("active", 0.3).alpha, "the active halo is steady")

-- glow nodes never steal a click
for _, n in ipairs(Glow.light({ x = 50, y = 50 }, "paused_error", 0.2)) do assert(n.style.ignorePointer, "a glow ignores the pointer") end
assert(#Glow.light({ x = 0, y = 0 }, "idle", 0) == Vfx.glow.layers + 1, "layers plus the light itself")

-- map: planets glow and pulse, the focus lights its routes, active dashes move, idle ones do not
sim.tier = 3
local function dots(opts)
  local spec = Shell.spec(sim, "map", opts)
  local size = Screens.map.routeThickness * (opts.focus and Vfx.glow.focusScale or 1)
  return collect(spec, function(n) return n.style and type(n.style.width) == "number" and math.abs(n.style.width - size) < 1e-9 and n.background and n.background.radius == size / 2 end)
end
local function key(list) local parts = {} for i, n in ipairs(list) do parts[i] = ("%.2f,%.2f"):format(n.style.left, n.style.top) end return table.concat(parts, ";") end
local rings = collect(Shell.spec(sim, "map", { time = 0 }), function(n) return n.background and n.background.borderWidth == 2 and n.style.ignorePointer end)
assert(#rings >= Vfx.glow.layers, "lit planets and market nodes carry a glow ring")
assert(key(dots({ time = 0 })) == key(dots({ time = 0.4 })), "an idle route does not move")
assert(key(dots({ time = 0, focus = "orbis" })) ~= key(dots({ time = 0.4, focus = "orbis" })), "a focused route animates")
assert(#dots({ time = 0, focus = "orbis" }) > 0 and #collect(Shell.spec(sim, "map", { focus = "orbis" }), function(n) return n.button and n.button.action == "map.focus.orbis" end) == 1)
local function ringAlpha(t)
  local list = collect(Shell.spec(sim, "map", { time = t }), function(n) return n.background and n.background.borderWidth == 2 and n.style.ignorePointer end)
  return list[1].background.borderColor[4]
end
assert(ringAlpha(0) ~= ringAlpha(2), "the planet glow pulses")
local state = Shell.new()
assert(Shell.act(state, "map.focus.orbis") and state.focus == "orbis" and Shell.act(state, "map.focus.orbis") and state.focus == nil, "focus toggles")
assert(not Shell.act(state, "nav.logs"), "other actions are left alone")

-- error glitch: brief, drawn over the top bar and the main panel only, never over the feed strip, and no click is blocked
local rects = Shell.layout()
local g = Glitch.new()
assert(Glitch.trigger(g, "ai_error"))
local frame = Glitch.update(g, 0.02)
local bars = Glow.glitch(frame, rects)
assert(#bars > 0 and #bars <= Vfx.glitchOverlay.maxBars * 3, "a few bars")
for _, b in ipairs(bars) do
  assert(b.style.ignorePointer, "the glitch blocks no click")
  assert(b.style.height <= Vfx.glitchOverlay.barHeight + Vfx.glitchOverlay.splitHeight, "hair thin")
  assert(b.background.color[4] <= Vfx.glitch.scanlineAlpha + 1e-9, "faint")
  assert(b.style.top + b.style.height <= rects.feed.y, "the feed strip, where the error reason is written, stays clear")
  assert(b.style.top >= rects.top.y)
end
assert(#Glow.glitch(nil, rects) == 0, "no frame, no glitch")
local plain, glitched = Shell.spec(sim, "map", {}), Shell.spec(sim, "map", { glitch = frame })
assert(#glitched.children == #plain.children + #bars, "the overlay is the only addition")
local function texts(spec) return #collect(spec, function(n) return n.text ~= nil end) end
assert(texts(plain) == texts(glitched), "no text is removed by the glitch")

-- agent lights: a paused agent shows the error light in the Team list and in the Agents editor header
sim.tier = 2
local amber = UiTheme.color("amber", 1)
local function hasLight(spec, colour)
  return #collect(spec, function(n) local c = n.background and n.background.color return c and c[1] == colour[1] and c[2] == colour[2] and c[3] == colour[3] and c[4] == 1 and n.style.ignorePointer end) > 0
end
assert(not hasLight(Shell.spec(sim, "team", {}), amber), "a healthy agent has no error light")
sim.agents.miner.state = "paused_error"
assert(hasLight(Shell.spec(sim, "team", {}), amber), "team list shows the error light")
assert(hasLight(Shell.spec(sim, "agents", {}), amber), "editor header shows the error light")

-- branches panel: one accent bar per branch, in the branch colour
local branches = Shell.spec(sim, "branches", {})
local accents = collect(branches, function(n) return n.style and n.style.ignorePointer and n.style.width == Vfx.glow.accentBar end)
assert(#accents == #sim.registry.list, "one accent per branch")

-- fleet panel draws state lights too
sim.tier = 4
assert(#collect(Shell.spec(sim, "fleet", {}), function(n) return n.style and n.style.ignorePointer end) > 0, "fleet lights")
print("art OK")
