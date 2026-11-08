-- GR5-3 gate: the 8-colour theme is the only colour source; the shell's nav, map, unlocks and empty states behave as the
-- spec says (§4.2, §6.6, §6.7); the UI specs only use styles the engine accepts. Headless: no engine calls.
local Theme = require("@scripts/config/theme")
local Screens = require("@scripts/config/screens")
local World = require("@scripts/config/world")
local Planets = require("@scripts/config/planets")
local Bodies = require("@scripts/config/bodies")
local Backgrounds = require("@scripts/config/background")
local Vfx = require("@scripts/config/vfx")
local Sim = require("@scripts/sim/sim")
local UiTheme = require("@scripts/ui/theme")
local Model = require("@scripts/ui/shell_model")
local Shell = require("@scripts/ui/shell")
local Remap = require("@scripts/client/remap")
local SystemMap = require("@scripts/client/system_map")
local IconStyle = require("@scripts/ui/icon_style")

local function count(t) local n = 0 for _ in pairs(t) do n += 1 end return n end
local function has(list, id) for _, e in ipairs(list) do if e.id == id then return e end end return nil end

-- the theme lists at most 8 colours, and every colour name used by a config exists in it
assert(count(Theme.palette) <= 8 and UiTheme.count() <= 8, "palette has more than 8 colours")
local function known(name, where) assert(Theme.palette[name], where .. ": '" .. tostring(name) .. "' is not in the theme palette") end
for id, p in pairs(Planets.planets) do
  for _, k in ipairs({ "land", "water", "cloud" }) do for _, n in ipairs(p[k]) do known(n, "planet " .. id) end end
end
for _, k in ipairs({ "land", "water", "cloud" }) do for _, n in ipairs(Planets.locked[k]) do known(n, "locked") end end
for _, n in ipairs(Theme.remapRamp) do if n ~= "$neon" then known(n, "remapRamp") end end
for corp, neon in pairs(Theme.corps) do known(neon, "corps." .. corp) end
for k, n in pairs(Theme.semantic) do known(n, "semantic." .. k) end
for _, key in ipairs({ "safe", "risky" }) do known(Vfx.route[key], "vfx.route." .. key) end
for _, state in ipairs({ "idle", "pending", "executing" }) do known(Vfx.halo[state].color, "vfx.halo." .. state) end
known(Vfx.trail.color, "vfx.trail")
assert(Theme.alpha.line and Theme.font.path:find("jetbrains_mono"), "single font wired through the theme")
assert(count(Theme.corps) == 3 and Theme.corps.player == "cyan", "one neon per corporation")
assert(type(Bodies) == "table" and type(Backgrounds) == "table")

-- palette remap: one ramp per corporation from the same greyscale sprite, ending on the corporation's neon
local seen = {}
for corp, neon in pairs(Theme.corps) do
  local ramp = Remap.ramp(corp)
  assert(#ramp == 4 and ramp[1] == "bg" and ramp[2] == "panel" and ramp[3] == neon and ramp[4] == "text", "ramp " .. corp)
  seen[ramp[3]] = true
end
assert(count(seen) == 3, "three distinct ramps")

-- colour helpers: sRGB for tints, linear for the UI
local cyan, lin = UiTheme.rgba("cyan"), UiTheme.color("cyan")
assert(math.abs(cyan[1] - 0x19 / 255) < 1e-9 and lin[1] < cyan[1] and lin[3] == 1 and lin[4] == 1, "colour spaces")
assert(not pcall(UiTheme.color, "hotpink"), "an unknown colour is refused")
assert(IconStyle.resolve("tool.mine", true, nil, { status = "danger" }).color[1] == 1, "icons take the theme")

-- layout fits the view and the panels do not overlap
local r, v = Shell.layout(), Theme.layout.view
for name, box in pairs(r) do assert(box.x >= 0 and box.y >= 0 and box.x + box.w <= v.w and box.y + box.h <= v.h, name .. " outside the view") end
assert(r.nav.x + r.nav.w <= r.main.x and r.main.y + r.main.h <= r.feed.y and r.top.y + r.top.h <= r.nav.y, "panels overlap")

-- nav: Map/Agents/Logs/Missions at T1, more panels by tier (§6.6), hidden ones refused
local sim = Sim.new()
local function ids(tier) local out = {} for _, e in ipairs(Model.nav(tier, "map")) do out[#out + 1] = e.id end return out end
for _, id in ipairs({ "map", "agents", "logs", "missions" }) do assert(has(Model.nav(1, "map"), id), id .. " missing at T1") end
assert(not has(Model.nav(1, "map"), "shop") and has(Model.nav(2, "map"), "shop"), "shop gated at T2")
assert(not has(Model.nav(2, "map"), "station") and has(Model.nav(3, "map"), "station"), "station gated at T3")
assert(not has(Model.nav(3, "map"), "fleet") and has(Model.nav(4, "map"), "fleet"), "fleet gated at T4")
assert(#ids(5) == #Screens.nav and #ids(1) < #ids(2) and #ids(2) < #ids(3), "nav grows with the tier")
assert(Model.nav(1, "logs")[3].active and not Model.nav(1, "logs")[1].active, "active entry")
assert(Shell.parseAction("nav.logs", 1) == "logs" and Shell.parseAction("nav.fleet", 1) == nil and Shell.parseAction("debug.x", 5) == nil)

-- empty states: every nav screen except the map has a title and a hint
for _, e in ipairs(Screens.nav) do
  if e.id ~= Screens.defaultScreen then
    local s = Model.emptyState(e.id)
    assert(s and #s.title > 0 and #s.hint > 0, "empty state missing: " .. e.id)
  end
end

-- the map at T1: Kessa lit, the three others greyed with their unlock condition (§4.2), no market yet
local map = Model.map(sim)
assert(#map.planets == 4 and #map.markets == 0 and #map.routes == 0 and #map.convoys == 0, "T1 map")
assert(map.planets[1].id == "kessa" and map.planets[1].lit and map.planets[1].condition == nil, "Kessa lit")
for i = 2, 4 do assert(not map.planets[i].lit and map.planets[i].condition, map.planets[i].id .. " should be locked") end
assert(map.planets[2].condition == "Engine Mk2", map.planets[2].condition)
assert(map.planets[3].condition == "Engine Mk3", map.planets[3].condition)
assert(map.planets[4].condition:find("Mk3") and map.planets[4].condition:find("Deep"), map.planets[4].condition)
assert(#map.planets[1].ores >= 1, "ores of a lit planet listed")

-- a better engine lights Varn; Lumen Rift also needs deep navigation
sim.ships.s1.engineMark = 3
map = Model.map(sim)
assert(map.planets[2].lit and map.planets[3].lit and not map.planets[4].lit, "engine unlocks")
sim.deepNav = true
assert(Model.map(sim).planets[4].lit, "deep nav unlocks Lumen Rift")
assert(SystemMap.look("varn", true) == Planets.planets.varn and SystemMap.look("varn", false).land == Planets.locked.land, "locked look")
assert(SystemMap.look("varn", false).seed == Planets.planets.varn.seed, "same planet, greyed")
assert(SystemMap.signature(sim) ~= SystemMap.signature(Sim.new()), "world respawns on unlock")

-- markets appear with their tier: Orbis at T3, Halcyon and Meridian at T4 (§4.4), with their routes
sim.tier = 2
assert(#Model.map(sim).markets == 0, "no market at T2")
sim.tier = 3
map = Model.map(sim)
assert(#map.markets == 1 and map.markets[1].id == "orbis" and map.markets[1].tier == 3 and #map.routes == 1, "Orbis at T3")
assert(map.routes[1].color == "safe" and map.routes[1].seconds == World.freighterRoutes.kessa.orbis, "safe blue route")
sim.tier = 4
map = Model.map(sim)
assert(#map.markets == 3 and #map.routes == 3 and map.markets[2].tier == 4, "all markets at T4")
assert(map.routes[2].color == "risky", "risky route is orange")

-- convoys: one dot per freighter on the way out, between 0 and 1
sim:addFreighter("kessa")
local f = sim.freighters[1]
f.state, f.load = "out", { resource = "titanium", qty = 10, destination = "orbis" }
f.timer = sim:ticks(World.freighterRoutes.kessa.orbis) // 2
local convoy = Model.map(sim).convoys[1]
assert(convoy and convoy.to == "orbis" and convoy.t > 0.3 and convoy.t < 0.7, "convoy dot")

-- top bar: Credits, Compute gauge, Reputation, Tier
local top = Model.topBar(sim)
assert(top.creditsText == "500 cr" and top.tierText == "T4" and top.reputationText == "Rep 0" and top.computeFraction >= 0)
assert(Model.thousands(1234567) == "1,234,567" and Model.thousands(12) == "12" and Model.thousands(1000) == "1,000")
assert(Model.thousands(-504) == "-504" and Model.thousands(-1440) == "-1,440" and Model.thousands(0) == "0", "negative numbers keep the sign in front")
sim.lifetimeRevenue = 80000
local rep = Model.reputation(sim)
assert(rep.level == 2 and rep.next == 200000 and rep.fraction > 0 and rep.fraction < 0.1, "reputation level")
sim.lifetimeRevenue = 5e6
assert(Model.reputation(sim).level == 5 and Model.reputation(sim).fraction == 1)

-- every screen builds as a spec the engine accepts: known style keys and enum values only
local ENUMS = {
  display = { flex = 1, none = 1 }, position = { relative = 1, absolute = 1 },
  direction = { column = 1, ["column-reverse"] = 1, row = 1, ["row-reverse"] = 1 },
  wrap = { nowrap = 1, wrap = 1, ["wrap-reverse"] = 1 },
  justify = { start = 1, center = 1, ["end"] = 1, ["space-between"] = 1, ["space-around"] = 1, ["space-evenly"] = 1 },
  alignItems = { auto = 1, start = 1, center = 2, ["end"] = 1, stretch = 1, baseline = 1 },
  overflow = { visible = 1, hidden = 1, scroll = 1 },
}
local NUMERIC = {}
for _, k in ipairs({ "basis", "width", "height", "minWidth", "minHeight", "maxWidth", "maxHeight", "left", "top", "right", "bottom",
  "marginLeft", "marginTop", "marginRight", "marginBottom", "paddingLeft", "paddingTop", "paddingRight", "paddingBottom",
  "margin", "marginX", "marginY", "padding", "paddingX", "paddingY", "gap", "grow", "shrink", "aspectRatio", "border", "rowGap",
  "columnGap", "zIndex" }) do NUMERIC[k] = true end
local function checkStyle(style, where)
  for k, val in pairs(style) do
    if type(k) == "number" then checkStyle(val, where)
    elseif ENUMS[k] then assert(ENUMS[k][val], where .. ": bad " .. k .. " = " .. tostring(val))
    elseif k == "ignorePointer" then assert(type(val) == "boolean")
    else
      assert(NUMERIC[k], where .. ": unknown style '" .. k .. "'")
      assert(type(val) == "number" or (type(val) == "string" and (val == "auto" or val:match("^-?[%d%.]+%%$"))), where .. ": bad length " .. k .. " = " .. tostring(val))
    end
  end
end
local function checkColor(c, where) assert(type(c) == "table" and #c == 4, where .. ": colour must be { r, g, b, a }") end
local nodes = 0
local function walk(spec, where)
  nodes += 1
  if spec.style then checkStyle(spec.style, where) end
  if spec.background then
    checkColor(spec.background.color, where)
    if spec.background.borderColor then checkColor(spec.background.borderColor, where) end
  end
  if spec.text then assert(type(spec.text.text) == "string" and spec.text.size, where .. ": text") checkColor(spec.text.color, where) end
  if spec.button then assert(spec.button.action and (spec.button.action:match("^nav%.") or spec.button.action:match("^editor%.") or spec.button.action:match("^shop%.") or spec.button.action:match("^fleet%.") or spec.button.action:match("^compute%.") or spec.button.action:match("^context%.") or spec.button.action:match("^speed%.") or spec.button.action:match("^studio%.") or spec.button.action:match("^archive%.") or spec.button.action:match("^offline%.") or spec.button.action:match("^team%.") or spec.button.action:match("^map%.") or spec.button.action:match("^missions%.") or spec.button.action:match("^debug%.") or spec.button.action:match("^alerts%.")), where .. ": button action") end
  for _, child in ipairs(spec.children or {}) do walk(child, where) end
end
for tier = 1, 5 do
  sim.tier = tier
  for _, e in ipairs(Model.nav(tier, "map")) do
    local spec, shown = Shell.spec(sim, e.id, {})
    assert(shown == e.id)
    walk(spec, ("T%d/%s"):format(tier, e.id))
  end
end
local _, fallback = Shell.spec(Sim.new(), "fleet", {})
assert(fallback == Screens.defaultScreen, "a hidden screen falls back to the map")
assert(nodes > 100, "the shell builds")

-- panels: a skin makes them nine-patch images tinted by the theme; without one they stay hairline nodes; the map stays see-through
local skin = { texture = "fake-texture", slice = Theme.panelSkin.slice, color = UiTheme.color(Theme.panelSkin.tint, Theme.alpha.panelFill) }
local skinned = Shell.spec(Sim.new(), "map", { skin = skin })
local function countWhere(spec, pred) local n = pred(spec) and 1 or 0 for _, c in ipairs(spec.children or {}) do n += countWhere(c, pred) end return n end
assert(countWhere(skinned, function(n) return n.image and n.image.slice ~= nil end) == 3, "top bar, nav and feed use the skin")
assert(countWhere(skinned, function(n) return n.image and n.image.slice ~= nil and n.background and n.background.color[4] == Theme.alpha.chromeFill and not n.background.borderColor end) == 3, "a skinned panel has an opaque borderless backing")
assert(countWhere(Shell.spec(Sim.new(), "map", {}), function(n) return n.image and n.image.slice ~= nil end) == 0, "no skin, no nine-patch")
assert(#Theme.panelSkin.slice == 4 and Theme.palette[Theme.panelSkin.tint], "panel skin config")

-- route dashes skip the planet discs and stay on the line
local dashes = Shell.dashes({ x = 0, y = 0 }, { x = 400, y = 0 }, 50, 14, 14)
assert(#dashes > 20 and dashes[1].x > 50 and dashes[#dashes].x < 386 and dashes[1].y == 0, "dashes")

-- change detection: the signature moves with credits, tier and feed, and not otherwise
local a, b = Sim.new(), Sim.new()
assert(Model.signature(a, "map") == Model.signature(b, "map"), "same state, same signature")
b.resources.credits += 100
assert(Model.signature(a, "map") ~= Model.signature(b, "map"), "credits change the signature")
assert(Model.signature(a, "map") ~= Model.signature(a, "logs"), "screen changes the signature")

-- glitch: only an agent in paused_error triggers it, once, then it fades
local shell = Shell.new()
assert(Shell.onSimEvent(shell, { name = "feed_event" }) == false and Shell.update(shell, 0.016) == nil, "no glitch by default")
assert(Shell.onSimEvent(shell, { name = "agent_paused_error", data = { agent = "miner" } }) == true, "paused_error glitches")
local frame = Shell.update(shell, 0.016)
assert(frame and frame.rgbSplitPx > 0, "glitch frame")
local _, _ = Shell.spec(sim, "map", { glitch = frame })
local guard = 0
while Shell.update(shell, 0.1) and guard < 100 do guard += 1 end
assert(guard < 100 and Shell.update(shell, 0.1) == nil, "glitch ends")

-- Emergency advance notification (GR5-74, spec §8.5): shown only while the sim offers it, Claim adds 3 Compute and
-- starts the cooldown, then the banner is gone.
do
  local Debug = require("@scripts/sim/debug")
  local Balance = require("@scripts/config/balance")
  local function claimButtons(spec, out)
    if spec.button and spec.button.action == "notice.claim" then out[#out + 1] = spec end
    for _, c in ipairs(spec.children or {}) do claimButtons(c, out) end
    return out
  end
  local s = Sim.new()
  s:step()
  assert(Model.notification(s) == nil and #claimButtons(Shell.spec(s, "map"), {}) == 0, "hidden when not offered")
  local sigBefore = Model.signature(s, "map")
  assert(Debug.run(s, "setStuck"), "debug panel sets the stuck state")
  s:step()
  local n = Model.notification(s)
  assert(n and n.action == "notice.claim" and n.compute == Balance.bailout.grantCompute and n.button:find("%+3"), "offer in the shell model")
  assert(Model.signature(s, "map") ~= sigBefore, "the shell redraws when the offer appears")
  for _, screen in ipairs({ "map", "missions" }) do
    assert(#claimButtons(Shell.spec(s, screen), {}) == 1, "Claim button on " .. screen)
  end
  local before = s.resources.compute
  local handled, ok = Model.act(s, "notice.claim")
  assert(handled and ok and s.resources.compute == before + 3, "claiming adds 3 Compute")
  assert(s.lastAdvanceTick == s.tick and Model.notification(s) == nil and #claimButtons(Shell.spec(s, "map"), {}) == 0, "cooldown started, banner hidden")
  s.resources.compute = 0
  s:run(5)
  assert(Model.notification(s) == nil, "no new offer during the cooldown")
  local h2, ok2 = Model.act(s, "notice.claim")
  assert(h2 and not ok2 and s.resources.compute == 0, "a late click grants nothing")
  assert(not Model.act(s, "nav.map"), "foreign actions are not handled")
end

-- GR5-104: the map choreography overlay renders what the fleet hands it, and the motion switch is a real action.
do
  local function texts(spec, out)
    out = out or {}
    if spec.text and spec.text.text then out[#out + 1] = spec.text.text end
    for _, c in ipairs(spec.children or {}) do texts(c, out) end
    return out
  end
  local function joined(spec) return table.concat(texts(spec), "|") end
  local hull = { x = 400, y = 300, w = 28, h = 28 }
  local life = {
    chips = {
      { key = "ship:s1", focusId = "ship_s1", badge = { tone = "green", shape = "square", label = "WORK" }, selected = true, clickable = true,
        hull = hull, x = 380, y = 278, w = 72, h = 16 },
      { key = "ship:s2", focusId = "ship_s2", badge = { tone = "amber", shape = "bar", label = "WARN" }, hull = hull, clickable = false,
        x = 440, y = 330, w = 14, h = 14, number = 1 },
    },
    aggregates = { { id = "kessa", count = 3, x = 100, y = 300, w = 30, h = 16 } },
    hidden = 3, away = { { key = "scav:j1", where = "Tessar", badge = { tone = "green", shape = "square", label = "WORK" } } },
    reduced = false,
  }
  local sim = Sim.new()
  sim.alertTrack.stations[SystemMap.stations(sim)[1].sid] = true
  walk((Shell.spec(sim, "map", { mapLife = life, mapStations = SystemMap.stationLabels(sim) })), "map life")
  local on = joined((Shell.spec(sim, "map", { mapLife = life })))
  assert(on:find("WORK") and on:find("+3") and on:find("OFF MAP") and on:find("Tessar") and on:find("MOTION: FULL"), "overlay shows chips, +N, off-map list and the motion switch")
  assert(on:find("%\+3 more ships not drawn"), "the legend counts the hidden hulls")
  life.reduced = true
  assert(joined((Shell.spec(sim, "map", { mapLife = life }))):find("MOTION: REDUCED"), "the switch shows reduced motion")
  local shellState = Shell.new()
  assert(Shell.act(shellState, "map.motion") and shellState.reduced == true, "map.motion turns reduced motion on")
  assert(Shell.act(shellState, "map.motion") and shellState.reduced == false, "and off again")
  assert(Shell.act(shellState, "map.focus.ship_s1") and shellState.focus == "ship_s1", "a ship can be focused")
  assert(#texts((Shell.spec(sim, "map", {}))) > 0 and not joined((Shell.spec(sim, "map", {}))):find("MOTION"), "no life layer without opts.mapLife")
end

print("shell OK")
