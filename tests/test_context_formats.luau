-- Spec 9.2.3 and 9.2.5: golden Logistician and format sizes for every agent type.
local Sim = require("@scripts/sim/sim")
local Renderer = require("@scripts/sim/context_renderer")
local Builder = require("@scripts/sim/context_builder")
local Prompt = require("@scripts/sim/prompt")
local Log = require("@scripts/sim/decision_log")
local Compute = require("@scripts/sim/compute")
local Ai = require("@scripts/config/ai")

local m = Renderer.map
local fixture = {
  { key = "time", kind = "scalar", value = "01:10:05" },
  { key = "station", kind = "object", fields = { { "id", "main@kessa" }, { "cap", 2000 } } },
  { key = "stock", kind = "map", map = m({ { "cobalt", 820 }, { "iridium", 140 } }) },
  { key = "freighters", kind = "table", cols = { "id", "state", "cargo", "dest", "eta_s" }, rows = {
    { "F1", "docked", "-", "-", "-" }, { "F2", "travelling", "cobalt:500", "halcyon", 132 } } },
  { key = "others_here", kind = "scalar", value = { "logistician_2" } },
  { key = "prices", kind = "maps", subs = {
    { "orbis", m({ { "titanium", 6.1 }, { "cobalt", 14.2 }, { "iridium", 36 } }) },
    { "halcyon", m({ { "titanium", 13 }, { "cobalt", 28.8 }, { "iridium", 54 } }) },
    { "meridian", m({ { "titanium", 6 }, { "iridium", 78 }, { "crystal", 210 } }) } } },
  { key = "inbox", kind = "strings", items = { "from logistician_2: I take iridium, you take cobalt" } },
  { key = "credits", kind = "scalar", value = 22840 },
  { key = "compute", kind = "scalar", value = 31 },
}
local golden = [[time: 01:10:05
station: id=main@kessa cap=2000
stock: cobalt=820 iridium=140
freighters[2] id state cargo dest eta_s
F1 docked - - -
F2 travelling cobalt:500 halcyon 132
others_here: logistician_2
prices.orbis: titanium=6.1 cobalt=14.2 iridium=36
prices.halcyon: titanium=13 cobalt=28.8 iridium=54
prices.meridian: titanium=6 iridium=78 crystal=210
inbox[1]
- from logistician_2: I take iridium, you take cobalt
credits: 22840
compute: 31.0]]
assert(Renderer.compact(fixture) == golden, Renderer.compact(fixture))
assert(Compute.estimateTokens(Ai, golden) < Compute.estimateTokens(Ai, Renderer.json(fixture)))

local s = Sim.new()
s:enterTier(3)
s.lifetimeRevenue = 60000
s.resources.credits, s.resources.compute = 1000000, 500
assert(s:buyUpgrade("warehouse") and s:buyUpgrade("trading_post"))
assert(s:buyUpgrade("engine_mk2"))
s:enterTier(4)
assert(s:buyUpgrade("logistics_hub") and s:hireLogistician("kessa"))
assert(s:openBranch("refining") and s:openBranch("salvage") and s:openBranch("raiding"))
s.lifetimeRevenue = s.b.reputationLevels[2]
assert(s:buyUpgrade("command_center") and s:hireMonitor())
for _, role in ipairs({ "miner", "logistician", "monitor", "refiner", "scavenger", "privateer" }) do
  local data = Builder.build(s, role)
  local compact, json = Renderer.compact(data), Renderer.json(data)
  local compactSize, jsonSize = Compute.estimateTokens(Ai, compact), Compute.estimateTokens(Ai, json)
  assert(compactSize < jsonSize, role .. ": compact must be smaller")
  local rec = Log.open(s, role, Prompt.build(s, role), 0)
  assert(rec.context_sizes.compact == Compute.estimateTokens(Ai, "[CONTEXT]\n" .. compact)
    and rec.context_sizes.json == Compute.estimateTokens(Ai, "[CONTEXT]\n" .. json), role .. ": logged sizes")
end
print("context formats OK")
