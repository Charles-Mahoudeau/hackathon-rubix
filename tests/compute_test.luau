-- Run from repo root: luau tests/compute_test.luau
-- GR5-6: Compute economy, context renderer/settings/weights, hourly AI budget, view-models.
local Ai = require("@scripts/config/ai")
local Sim = require("@scripts/sim/sim")
local AiStub = require("@scripts/sim/ai")
local Compute = require("@scripts/sim/compute")
local Prompt = require("@scripts/sim/prompt")
local Renderer = require("@scripts/sim/context_renderer")
local Settings = require("@scripts/sim/context_settings")
local View = require("@scripts/ui/compute_view")

local function near(a, b, msg) assert(math.abs(a - b) < 1e-6, (msg or "near") .. ": " .. tostring(a) .. " vs " .. tostring(b)) end
local function copy(t)
  local o = {}
  for k, v in pairs(t) do
    o[k] = type(v) == "table" and copy(v) or v
  end
  return o
end

-- §6.4 token estimate and decision cost
assert(Compute.estimateTokens(Ai, "") == 0 and Compute.estimateTokens(Ai, "abcd") == 1 and Compute.estimateTokens(Ai, "abcde") == 2)
assert(Compute.estimateTokens(Ai, "ééé") == 1, "utf8 length, not bytes")
near(Compute.cost(Ai, 1000), 1.0); near(Compute.cost(Ai, 1), 0.1); near(Compute.cost(Ai, 1001), 1.1); near(Compute.cost(Ai, 2999), 3.0)
near(Compute.cost(Ai, 100), 0.1); near(Compute.cost(Ai, 101), 0.2)
assert(Compute.creditsFor(Ai, 1) == 40 and Compute.packPrice(Ai, 1) == 200)

-- buying: packs of 5 for 200 cr, at any Compute level, no cap
local s = Sim.new()
assert(s:buyCompute(1) and s.resources.credits == 300 and s.resources.compute == 15)
assert(not s:buyCompute(2) and s.resources.credits == 300, "cannot afford 2 packs (400 cr)")
assert(not s:buyCompute(0) and not s:buyCompute(1.5))
s.resources.compute, s.resources.credits = 100000, 400
assert(s:buyCompute(2) and s.resources.compute == 100010 and s.resources.credits == 0, "no cap on Compute")

-- charge on send with the estimate, corrected on response; a failed response is still billed
local r = { credits = 0, compute = 10 }
local t = 0
local led = Compute.new(r, Ai, function() return t end)
local id, cost = led:charge("a", 900)
near(cost, Compute.cost(Ai, 900 + Ai.estimatedOutputTokens)); near(r.compute, 10 - cost)
led:settle(id, 900, 100) -- real output larger than estimated
near(r.compute, 10 - Compute.cost(Ai, 1000))
assert(led:settle(id, 900, 100) == nil, "a charge settles once")
local id2 = led:charge("a", 500)
led:settle(id2, 500, 0) -- failed response: output 0, still billed for the input
near(r.compute, 10 - Compute.cost(Ai, 1000) - Compute.cost(Ai, 500))
near(led.lifetime.a, 10 - r.compute, "lifetime tracks spend")

-- context renderer: golden compact output (spec §9.2.2) and compact < json
local m = Renderer.map
local fixture = {
  { key = "time", kind = "scalar", value = "00:42:10" },
  { key = "ship", kind = "object", fields = { { "at", "K3@kessa" }, { "hold", m({ { "cobalt", 64 } }) }, { "cap", 100 },
    { "hold%", 64 }, { "drill", 2 }, { "engine", 0.7 }, { "range", { "kessa", "varn" } } } },
  { key = "veins", kind = "table", cols = { "id", "planet", "res", "rich", "jumps", "res%", "travel_s" },
    rows = { { "K1", "kessa", "titanium", "1.0", 1, 88, 10 }, { "V1", "varn", "cobalt", "medium", 1, nil, 52 } } },
  { key = "prices", kind = "maps", subs = {
    { "hmc@kessa", m({ { "titanium", 3 }, { "cobalt", 7.2 } }) },
    { "hmc@varn", m({ { "titanium", 2.5 }, { "cobalt", 6 } }) },
    { "orbis", m({ { "titanium", 6.2 }, { "cobalt", 13.9 }, { "iridium", 35.1 } }) } } },
  { key = "station", kind = "object", fields = { { "id", "main@kessa" }, { "cap", 2000 } } },
  { key = "stock", kind = "map", map = m({ { "cobalt", 420 } }) },
  { key = "recent", kind = "table", cols = { "tool", "args", "ok", "result" }, rows = {
    { "mine", m({ { "vein", "K3" }, { "pct", 90 } }), true, m({ { "mined", m({ { "cobalt", 90 } }) }, { "duration_s", 75 } }) } } },
  { key = "inbox", kind = "strings", items = { "Cobalt shortage on Halcyon: +50%" } },
  { key = "credits", kind = "scalar", value = 3210 },
  { key = "compute", kind = "scalar", value = 14.5 },
}
local golden = [[time: 00:42:10
ship: at=K3@kessa hold=cobalt:64 cap=100 hold%=64 drill=2 engine=0.7 range=kessa,varn
veins[2] id planet res rich jumps res% travel_s
K1 kessa titanium 1.0 1 88 10
V1 varn cobalt medium 1 ? 52
prices.hmc@kessa: titanium=3 cobalt=7.2
prices.hmc@varn: titanium=2.5 cobalt=6
prices.orbis: titanium=6.2 cobalt=13.9 iridium=35.1
station: id=main@kessa cap=2000
stock: cobalt=420
recent[1] tool args ok result
mine vein=K3,pct=90 y mined=cobalt:90,duration_s=75
inbox[1]
- Cobalt shortage on Halcyon: +50%
credits: 3210
compute: 14.5]]
assert(Renderer.compact(fixture) == golden, "compact render differs from the spec example:\n" .. Renderer.compact(fixture))
local js = Renderer.json(fixture)
assert(#js > #golden and js:find('"res_pct":null', 1, true) and js:find('"hold_pct":64', 1, true))
assert(Compute.estimateTokens(Ai, golden) < Compute.estimateTokens(Ai, js), "compact must be cheaper than json")
assert(Renderer.compact(fixture) == Renderer.compact(fixture), "deterministic")

-- the first decision is billed exactly what the Context panel promised
local a = Sim.new()
a:setDecider(AiStub.decide)
local panel = View.contextPanel(a, "miner")
local before = a.resources.compute
a:step()
near(before - a.resources.compute, panel.cost.compute, "billed == panel estimate")
local sum = 0
for _, v in pairs(panel.sections) do sum = sum + v end
assert(sum == panel.inputTokens, "section tokens add up to the billed input")
assert(a.agents.miner.state == "thinking")
-- on response the estimate is corrected to the real counts
local pend = a.agents.miner.pending
a:run(a:ticks(Ai.maxOutputTokens)) -- well past the 2-4 s delay
assert(a.agents.miner.state ~= "thinking" or a.agents.miner.pending ~= pend)
assert(#a.agents.miner.history >= 1)
assert(View.agentRows(a)[1].computePerHour > 0, "per-agent Compute/h is live")
assert(math.abs(View.agentRows(a)[1].computePerHour - a.compute:agentRatePerHour("miner")) < 0.05, "rate matches the ledger")
assert(View.agentRows(a)[1].thinksMost)

-- toggles: the next prompt weighs exactly what the panel said
local w = Sim.new()
w.ships.s1.engineMark = 2 -- Varn in range, so "all reachable" differs from "current planet"
local base = Prompt.build(w, "miner").input
local p0 = View.contextPanel(w, "miner")
local function optionWeight(panelRows, key, value)
  for _, row in ipairs(panelRows) do
    if row.key == key then for _, o in ipairs(row.options) do if o.value == value then return o.weight end end end
  end
  error("no option")
end
local hmcAll, hmcCur = optionWeight(p0.rows, "prices_hmc", "all"), optionWeight(p0.rows, "prices_hmc", "current")
assert(hmcAll > hmcCur and hmcCur > 0, "more prices cost more tokens")
assert(w:setContextSetting("miner", "prices_hmc", "all"))
local after = Prompt.build(w, "miner").input
assert(after - base == hmcAll - hmcCur, "toggle weight == real prompt delta")
assert(not w:setContextSetting("miner", "prices_hmc", "bogus") and not w:setContextSetting("miner", "nope", true))
assert(not w:setContextSetting("miner", "recent_results", 11))
w:setContextSetting("miner", "veins", "all")
local pAll = View.contextPanel(w, "miner")
assert(optionWeight(pAll.rows, "veins", "all") > optionWeight(pAll.rows, "veins", "planet"))
assert(pAll.formats.json.context > pAll.formats.compact.context, "both formats shown, json heavier")
assert(pAll.cost.credits == pAll.cost.compute * 40 and pAll.cost.text:find("Compute"))
-- turning every optional section off makes the decision cheaper
local cheap = copy(w.agents.miner.contextSettings)
for k, v in pairs(Settings.minimal) do cheap[k] = v end
assert(Prompt.build(w, "miner", { settings = cheap }).input < Prompt.build(w, "miner").input)
-- locked toggles are reported, markets are absent from the prompt until unlocked
local rowsByKey = {}
for _, row in ipairs(pAll.rows) do rowsByKey[row.key] = row end
assert(not rowsByKey.prices_orbis.available and rowsByKey.prices_orbis.unlockTier == 3 and rowsByKey.prices_hmc.available)
assert(not Prompt.build(w, "miner").contextText:find("prices.orbis", 1, true))
w.tier = 3
assert(Prompt.build(w, "miner").contextText:find("prices.orbis", 1, true), "orbis prices appear once unlocked")

-- no_compute: one feed message, buying a pack resumes the agent
local n = Sim.new()
n:setDecider(AiStub.decide)
n.resources.compute = 0
n:run(50)
assert(n.agents.miner.state == "no_compute" and n.agents.miner.blockedReason == "no_compute")
local warns = 0
for _, l in ipairs(n.logs) do if l.level == "WARN" then warns = warns + 1 end end
assert(warns == 1, "exactly one feed message, got " .. warns)
assert(View.topBar(n).level == "empty")
assert(n:buyCompute(1))
n:run(5)
assert(n.agents.miner.state == "thinking", "buying Compute wakes the agent")

-- hourly AI budget: reached -> no_compute with the server message; frees after the real hour slides
local cfg = copy(Ai)
cfg.budget.tokensPerHour = 3000
local realNow = 0
local b = Sim.new({ ai = cfg, realClock = function() return realNow end })
b.compute.cfg = cfg
b:setDecider(AiStub.decide)
b.resources.compute = 1000
b:run(8000)
assert(b.agents.miner.state == "no_compute" and b.agents.miner.blockedReason == "budget", tostring(b.agents.miner.state))
assert(b.compute:budgetUsed() <= 3000 and b.compute:budgetUsed() > 0)
local found = false
for _, l in ipairs(b.logs) do if l.msg:find("Server AI budget reached", 1, true) then found = true end end
assert(found, "budget message logged")
local top = View.topBar(b)
assert(top.budget.left < 3000 and top.budget.fraction > 0.5)
local spent = b.resources.compute
b:run(100)
assert(b.resources.compute == spent, "nothing billed while the budget is reached")
realNow = 3601
assert(b.compute:budgetUsed() == 0)
b:run(10)
assert(b.agents.miner.state == "thinking", "budget frees after a real hour")

-- determinism: same seed, same Compute trail
local d1, d2 = Sim.new(), Sim.new()
d1:setDecider(AiStub.decide); d2:setDecider(AiStub.decide)
d1:run(3000); d2:run(3000)
assert(d1.resources.compute == d2.resources.compute and d1.compute.lifetimeTotal == d2.compute.lifetimeTotal)
print("compute ok", "spent", d1.compute.lifetimeTotal, "left", d1.resources.compute)
print("OK")
