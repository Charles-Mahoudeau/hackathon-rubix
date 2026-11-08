-- Run from repo root: luau tests/test_archive_ui.luau
-- GR5-10: Archive, Market and "While you were away" view-models, the editor skill counter and the shell screens.
local Sim = require("@scripts/sim/sim")
local Skills = require("@scripts/sim/skills")
local Market = require("@scripts/sim/market")
local Editor = require("@scripts/ui/agent_editor")
local ArchiveView = require("@scripts/ui/archive_view")
local MarketView = require("@scripts/ui/market_view")
local OfflineView = require("@scripts/ui/offline_view")
local Shell = require("@scripts/ui/shell")

local s = Sim.new()
s.resources.credits = 100000
Market.quiet(s.market)

-- empty Archive, no demo button yet
local m = ArchiveView.model(s)
assert(#m.skills == 0 and not m.canSimulateAway and m.simulateAway == nil and m.offline == nil)
assert(m.slots.used == 0 and m.slots.max == s:archiveCapacity())
assert(Editor.model(s, "miner").skills.used == 0)

-- record two calls of the feed and save them
assert(s:apply("miner", { name = "mine", args = { vein = "K1" } }))
repeat s:step() until s.ships.s1.state == "idle"
assert(s:apply("miner", { name = "mine", args = { vein = "K1" } }))
repeat s:step() until s.ships.s1.state == "idle"
local calls = ArchiveView.recordable(s, "miner")
assert(select(2, ArchiveView.recordAndSave(s, "miner", calls[1].id, calls[1].id, "x")) == "bad_length")
assert(select(2, ArchiveView.recordAndSave(s, "miner", calls[1].id, calls[1].id, "x")) == "bad_length")
local ok, name = ArchiveView.recordAndSave(s, "miner", calls[1].id, calls[2].id, "dig")
assert(ok and name == "dig", tostring(name))
m = ArchiveView.model(s)
assert(#m.skills == 1 and m.skills[1].steps[1] == "mine vein=K1" and m.skills[1].createdFrom == "recording")
assert(m.canSimulateAway and m.simulateAway == "archive.away", "demo button appears once a skill exists")
assert(Editor.model(s, "miner").skills.used == 1)

-- a parameterized, looping skill with a runner
s.upgrades.archive = 3
assert(ArchiveView.saveForm(s, { name = "ore-run", agent_type = "miner", loop = true, params = { vein = { kind = "vein" } },
  steps = { { tool = "mine", args = { vein = "$vein" } }, { tool = "return" }, { tool = "sell" } } }))
assert(ArchiveView.assign(s, "miner", "ore-run", { vein = "K1" }))
m = ArchiveView.model(s)
local run = m.skills[2].runners[1]
assert(m.skills[2].params[1] == "$vein" and run.agent == "miner" and run.params == "vein=K1" and not run.aborted)

-- the demo button runs the offline sim and the report shows
local sig = ArchiveView.signature(s)
local handled, ok2 = ArchiveView.act(s, "archive.away")
assert(handled and ok2)
assert(ArchiveView.signature(s) ~= sig)
local ov = OfflineView.model(s)
assert(ov and ov.title == "While you were away" and ov.report.simulated_seconds == 3600 and #ov.lines >= 3)
assert(ArchiveView.model(s).offline ~= nil)
assert(OfflineView.act(s, "offline.dismiss") and OfflineView.model(s) == nil)
assert(not OfflineView.act(s, "other") and not ArchiveView.act(s, 5))

-- delete
handled, ok2 = ArchiveView.act(s, "archive.delete.dig")
assert(handled and ok2 and s.skills.dig == nil)

-- Market view: Orbis hidden until the trading post, best buyer flagged, history present
local mv = MarketView.model(s)
for _, r in ipairs(mv.rows) do assert(r.market ~= "orbis", "Orbis needs the trading post") end
s.tier = 4
s.upgrades.warehouse, s.upgrades.tradingPost = true, true
mv = MarketView.model(s)
local seenOrbis, bests = false, 0
for _, r in ipairs(mv.rows) do
  if r.market == "orbis" then seenOrbis = true end
  if r.best then bests += 1 end
  assert(r.price > 0 and r.usual > 0 and (r.trend == "up" or r.trend == "down" or r.trend == "flat") and r.text:find("usual"))
end
assert(seenOrbis and bests == 4 and mv.bestBuyer.titanium == "halcyon")
for _ = 1, 100 do s:step() end
assert(MarketView.signature(s) ~= nil)

-- Shell screens build headless
for _, id in ipairs({ "archive", "market", "agents", "missions" }) do
  local spec, shown = Shell.spec(s, id, {})
  assert(spec and shown == id, id)
end
s.skills = {}
assert(Shell.spec(s, "archive", {}))
print("archive ui OK")
