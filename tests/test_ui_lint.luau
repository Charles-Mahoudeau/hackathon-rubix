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

local long = string.rep("a very long feed line that keeps going ", 8)
local function stress(sim)
  sim.feed = sim.feed or {}
  for i = 1, 8 do sim.feed[#sim.feed + 1] = { text = long .. i, status = (i % 3 == 0) and "failed" or "ok", agent = "miner_with_a_long_name" } end
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
