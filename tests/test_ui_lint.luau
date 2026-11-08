-- Run from repo root: luau tests/test_ui_lint.luau
-- UI lint: every screen's spec tree, at every tier and with long / worst-case texts, keeps its text inside a bounded width,
-- wraps every text with spaces, and keeps absolute boxes inside the 1280x720 view. Headless: widths use JetBrains Mono's
-- 0.6 em advance (ui/fit.luau).
local Theme = require("@scripts/config/theme")
local Screens = require("@scripts/config/screens")
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Model = require("@scripts/ui/shell_model")
local Shell = require("@scripts/ui/shell")
local Fit = require("@scripts/ui/fit")

local view = Theme.layout.view

-- Fit unit checks
assert(Fit.truncate("hello world", 12, 7.2 * 5) == "he...", Fit.truncate("hello world", 12, 7.2 * 5))
assert(Fit.truncate("short", 12, 200) == "short" and Fit.truncate("abcdef", 12, 7.2 * 6) == "abcdef")
assert(Fit.lineCount("aaa bbb ccc", 10, 6 * 7) == 2 and Fit.lineCount("a\nb", 10, 100) == 2)
local bad = Fit.check({ style = { width = 100 }, children = { { style = { position = "absolute", left = 1200, top = 0, width = 100, height = 10 } },
  { text = { text = "two words", size = 12 } } } }, view)
assert(#bad == 2, table.concat(bad, "\n"))
local fixed = Fit.apply({ style = { width = 100 }, children = { { text = { text = "two words and more words", size = 12 } } } }, view.w)
assert(fixed.children[1].text.wrap and #Fit.check(fixed, view) == 0, "apply wraps and bounds a flow text")

-- GR5-54: two single-line texts on one row may not run into each other (the Market "BEST" / trend glyph collision)
local function abs(left, top, str) return { style = { position = "absolute", left = left, top = top, width = 300 }, text = { text = str, size = 12 } } end
local clash = Fit.check({ style = { width = 400, height = 100 }, children = { abs(0, 10, "0123456789"), abs(60, 10, "x"), abs(60, 40, "y") } }, view)
assert(#clash == 1 and string.find(clash[1], "runs into", 1, true), table.concat(clash, "\n"))
assert(#Fit.check({ style = { width = 400, height = 100 }, children = { abs(0, 10, "0123456789"), abs(80, 10, "x") } }, view) == 0, "a gap is not an overlap")

-- GR5-54: the Credits and Reputation cells of the top bar keep a minimum width, so the cells after them (speed buttons) do
-- not shift as the numbers grow a digit
do
  local spec = Shell.spec(Sim.new(), "map", {})
  local minWidths = {}
  local function walk(n)
    for _, k in ipairs(n.children or {}) do
      local head = k.children and k.children[1]
      local label = head and head.children and head.children[2] and head.children[2].text and head.children[2].text.text
      if (label == "Credits" or label == "Reputation") and k.style then minWidths[label] = k.style.minWidth end
      walk(k)
    end
  end
  walk(spec)
  assert(minWidths.Credits and minWidths.Credits >= 120 and minWidths.Reputation and minWidths.Reputation >= 240, "top bar cells have a minimum width")
end

-- Glyph lint: the UI font only has U+0020-007E and U+00A0-00FF; anything else would draw as "?"
assert(#Fit.missingGlyphs("mine(K1, 10%) -> +10 titanium (20 s) \194\176 caf\195\169") == 0, "ASCII and Latin-1 are in the font")
assert(Fit.missingGlyphs("a \226\134\146 b")[1] == 0x2192, "the arrow glyph is not in the font")
assert(#Fit.check({ style = { width = 100 }, children = { { text = { text = "a \226\134\146 b", size = 12, wrap = true } } } }, view) == 1, "the lint reports a missing glyph")

local long = string.rep("a very long feed line that keeps going ", 8)
local function stress(sim)
  sim.feed = sim.feed or {}
  for i = 1, 8 do sim.feed[#sim.feed + 1] = { text = long .. i, status = (i % 3 == 0) and "failed" or "ok", agent = "miner_with_a_long_name" } end
  sim.feed[#sim.feed + 1] = { text = "mine(K1, 10%) \226\134\146 +10 titanium (20 s)", status = "ok", agent = "miner" } -- an old save
  sim.resources.credits = 987654321
end

local failures, checked = {}, 0
local function lint(sim, screenId, opts, label)
  local spec = Shell.spec(sim, screenId, opts or {})
  checked += 1
  for _, p in ipairs(Fit.check(spec, view)) do failures[#failures + 1] = label .. " " .. p end
end

local function sims()
  local out = {}
  for tier = 1, 5 do
    local s = Sim.new()
    s.tier = tier
    s.upgrades.warehouse = tier >= 3 or nil -- the Station and Market screens need the warehouse
    s.upgrades.hub = tier >= 4 or nil
    stress(s)
    out[#out + 1] = { s, "T" .. tier }
  end
  local ran = Sim.new()
  ran:setDecider(Ai.decide)
  ran:setDirective("miner", "Mine cobalt on K3 until the hold is 100%, then sell at HMC.")
  ran:run(6000)
  ran.tier = 5
  stress(ran)
  out[#out + 1] = { ran, "T5run" }
  return out
end

for _, pair in ipairs(sims()) do
  local sim, name = pair[1], pair[2]
  for _, e in ipairs(Screens.nav) do
    lint(sim, e.id, {}, name .. "/" .. e.id)
  end
  if sim.upgrades.warehouse then
    for _, id in ipairs(sim.stationOrder) do lint(sim, "station", { station = { station = id } }, name .. "/station-" .. id) end
  end
  lint(sim, "agents", { tab = "context" }, name .. "/agents-context")
  lint(sim, "agents", { toast = "Saved. " .. long }, name .. "/agents-toast")
end

if #failures > 0 then
  print(#failures .. " UI lint problem(s):")
  for i, f in ipairs(failures) do if i <= 60 then print("  " .. f) end end
  error("ui lint failed")
end
assert(checked > 60, "linted every screen")
print("ui lint OK (" .. checked .. " screens)")
