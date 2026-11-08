-- Run from repo root: luau tests/test_results.luau
-- GR5-75 / spec §11: every tool call leaves a real result table in the agent history; the `recent` context rows and the
-- Logs detail are built from it (no fixture).
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Skills = require("@scripts/sim/skills")
local Market = require("@scripts/sim/market")
local Builder = require("@scripts/sim/context_builder")
local Renderer = require("@scripts/sim/context_renderer")
local Persistence = require("@scripts/sim/persistence")
local Json = require("./support/engine_json")
local LogsView = require("@scripts/ui/logs_view")

local function eq(a, b, msg) if a ~= b then error((msg or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end end

local function lastOf(s, agent, tool)
  local h = s.agents[agent].history
  for i = #h, 1, -1 do if not tool or h[i].tool == tool then return h[i] end end
end
local function runUntil(s, max, cond)
  for _ = 1, max do s:step(); if cond() then return end end
  error("condition never met")
end
local function recentText(s, agent) return Renderer.compact(Builder.build(s, agent)) end

-- 1. Miner: mine -> return -> sell, then a manual recall, store, report and scan
do
  local s = Sim.new()
  s:enterTier(3)
  s.lifetimeRevenue = 30000
  s.resources.credits = 200000
  assert(s:buyUpgrade("warehouse"))
  s.upgrades.tradingPost, s.upgrades.scanner = true, true
  Market.quiet(s.market)
  local ship = s.ships.s1
  local function docked() return ship.state == "idle" end
  local function call(name, args) assert(s:apply("miner", { name = name, args = args or {} })) end

  call("mine", { vein = "K3", stop_at_hold_pct = 90 })
  local mine = lastOf(s, "miner", "mine")
  eq(next(mine.result), nil, "still running: no result yet")
  runUntil(s, 4000, function() return mine.result.mined ~= nil end)
  assert(mine.result.mined.cobalt >= 90, "mined cobalt")
  assert(mine.result.hold_pct >= 90 and mine.result.vein_reserve_pct >= 0 and mine.result.duration_s > 0)
  eq(mine.result.stopped_because, "hold_target")
  eq(type(mine.result.crowded_by), "table")

  runUntil(s, 4000, docked)
  local ret = lastOf(s, "miner", "return")
  eq(ret.ok, true)
  eq(ret.result.docked_at, s.home)
  assert(ret.result.hold.cobalt >= 90, "return reports the hold")

  -- the Miner context renders the real `recent` rows in the spec's compact shape
  local text = recentText(s, "miner")
  local row = text:match("\n(mine vein=K3,pct=90 [^\n]+)")
  assert(row and row:match("^mine vein=K3,pct=90 y mined=cobalt:%d+,hold_pct=%d+,vein_reserve_pct=%d+,duration_s=%d+,stopped_because=hold_target,crowded_by=%-$"), tostring(row) .. "\n" .. text)
  assert(text:match("\nreturn %- y docked_at=%S+,hold=cobalt:%d+\n"), "return row:\n" .. text)

  call("sell", { buyer = "orbis" })
  local sell = lastOf(s, "miner", "sell")
  assert(sell.result.sold >= 90 and sell.result.unit_price > 0 and sell.result.total > 0, "sell result")
  assert(recentText(s, "miner"):match("\nsell buyer=orbis y sold=%d+,unit_price=[%d.]+,total=%d+"), "sell row")

  call("mine", { vein = "K3" })
  runUntil(s, 600, function() return ship.state == "mining" end)
  for _ = 1, 100 do s:step() end
  call("return")
  runUntil(s, 4000, docked)
  eq(lastOf(s, "miner", "mine").result.stopped_because, "recalled")
  call("store", { resource = "cobalt" })
  local st = lastOf(s, "miner", "store").result
  assert(st.stored > 0 and st.partial == false and st.warehouse_free > 0, "store result")
  call("report", { message = "all good" })
  eq(lastOf(s, "miner", "report").result.delivered, true)
  call("scan", { planet = "kessa" })
  runUntil(s, 4000, docked)
  assert(next(lastOf(s, "miner", "scan").result.veins), "scan lists veins")
  assert(recentText(s, "miner"):match("\nscan planet=kessa y veins=%S+"), "scan row")

  local bad, err = s:apply("miner", { name = "sell", args = { buyer = "orbis" } })
  assert(not bad)
  eq(lastOf(s, "miner", "sell").result.error, err, "a refused call keeps its error")
end

-- 2. a stub-AI run fills the decision log and the Logs detail shows the result
do
  local s = Sim.new()
  s:setDecider(Ai.decide)
  s:setDirective("miner", "Mine cobalt on K3 until the hold is 100%, then sell at HMC.")
  s:run(6000)
  local found
  for _, r in ipairs(s.records.miner) do
    if r.tool_call and r.tool_call.tool == "mine" and r.result and r.result.data then found = r end
  end
  assert(found and found.result.data.mined and found.result.data.stopped_because, "mine record carries its result")
  local view = LogsView.new()
  view.selected = found.id
  local detail = LogsView.model(s, view).detail
  assert(detail and detail.result:find("mined=cobalt:", 1, true) and detail.result:find("stopped_because=", 1, true), detail and detail.result)
  local h = lastOf(s, "miner", "return") -- the stub lets the dock sell, so the return row carries the sale
  assert(h and h.result.sold and h.result.docked_at, "the return row says what was sold")
  assert(recentText(s, "miner"):find("sold=", 1, true), "recent shows what was sold")
  local loaded = Persistence.restore(Json.decode(Json.encode(Persistence.serialize(s, 0))))
  eq(lastOf(loaded, "miner", "return").result.total, h.result.total, "results survive a save")
end

-- 3. Logistician: sell and ship results
do
  local s = Sim.new()
  s:enterTier(3)
  s.lifetimeRevenue = 30000
  s.resources.credits = 200000
  assert(s:buyUpgrade("warehouse"))
  Market.quiet(s.market)
  assert(s:buyUpgrade("engine_mk2") and s:buyUpgrade("engine_mk3"))
  assert(s:buyUpgrade("logistics_hub"))
  assert(s:hireLogistician("kessa"))
  assert(s:buyFreighter("kessa"))
  s.warehouse.cobalt = 500
  assert(s:apply("logistician", { name = "ship", args = { resource = "cobalt", qty = 300, destination = "halcyon" } }))
  local ship = lastOf(s, "logistician", "ship").result
  eq(ship.freighter_id, "F1"); assert(ship.eta_s > 0)
  assert(s:apply("logistician", { name = "sell", args = { resource = "cobalt", qty = 100 } }))
  local sold = lastOf(s, "logistician", "sell").result
  eq(sold.sold, 100); assert(sold.total > 0 and sold.unit_price > 0)
  assert(recentText(s, "logistician"):match("\nship resource=cobalt,qty=300,destination=halcyon y freighter_id=F1,eta_s=%d+"), "ship row")
end

-- 4. Monitor: order_set, assigned, previous_error; run_skill: skill_ended_because
do
  local s = Sim.new()
  s.tier = 4
  for _, a in pairs(s.agents) do a.tier = 4 end
  s.lifetimeRevenue = s.b.reputationLevels[2]
  s.resources.credits = 250000
  s.resources.compute = 200
  Market.quiet(s.market)
  assert(Skills.save(s, { name = "One trip", agent_type = "miner", loop = false, params = { vein = { kind = "vein", filter = { resource = "titanium" } } },
    steps = { { tool = "mine", args = { vein = "$vein" } }, { tool = "return" }, { tool = "sell" } } }))
  assert(s:buyUpgrade("command_center") and s:hireMonitor())
  assert(s:apply("miner", { name = "run_skill", args = { name = "One trip", params = { vein = "K1" } } }))
  local run = lastOf(s, "miner", "run_skill")
  eq(next(run.result), nil, "the skill is still running")
  runUntil(s, 6000, function() return run.result.skill_ended_because ~= nil end)
  eq(run.result.skill_ended_because, "completed")

  assert(s:apply("monitor_1", { name = "set_order", args = { agent = "miner", text = "mine cobalt" } }))
  eq(lastOf(s, "monitor_1", "set_order").result.order_set, true)
  assert(s:apply("monitor_1", { name = "assign_skill", args = { agent = "miner", skill = "One trip", params = { vein = "K1" } } }))
  eq(lastOf(s, "monitor_1", "assign_skill").result.assigned, "One trip")
  s:pauseAgent("miner", "invalid_tool_call")
  assert(s:apply("monitor_1", { name = "resume_agent", args = { agent = "miner" } }))
  eq(lastOf(s, "monitor_1", "resume_agent").result.previous_error, "invalid_tool_call")
end

print("results OK")
