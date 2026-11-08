-- Run from repo root: luau tests/test_logs.luau
-- GR5-8: the decision log. Every decision (AI or skill step) leaves one record, invalid calls carry their reason, the
-- header stats match a hand calculation, filters and paging work, records are capped and survive a save.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Json = require("./support/engine_json")
local Persistence = require("@scripts/sim/persistence")
local DecisionLog = require("@scripts/sim/decision_log")
local Shell = require("@scripts/ui/shell")
local View = require("@scripts/ui/logs_view")

local PRECISE = "Mine cobalt on K3 until the hold is 100%, then sell at HMC."
local function newRun(ticks)
  local s = Sim.new()
  s:setDecider(Ai.decide)
  s:setDirective("miner", PRECISE)
  s:run(ticks)
  return s
end
local function eq(a, b, msg) if a ~= b then error((msg or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end end
local function all(sim)
  local out = {}
  for _, l in pairs(sim.records) do for _, r in ipairs(l) do out[#out + 1] = r end end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

-- every AI decision of a stub run leaves one fully filled record
local sim = newRun(6000)
local recs = all(sim)
assert(#recs > 5, "decisions were logged")
for i, r in ipairs(recs) do
  eq(r.id, i, "ids are sequential")
  eq(r.source, "ai"); assert(r.prompt_version and #r.prompt_version == 6, "prompt version")
  for _, k in ipairs({ "rules", "directive", "order", "context", "tools", "output", "total" }) do assert(type(r.tokens[k]) == "number", "token " .. k) end
  assert(r.tokens.total >= r.tokens.rules + r.tokens.context, "total covers the input")
  assert(r.compute_spent > 0, "AI decisions cost Compute")
  assert(r.t_real_sent and r.t_real_received and r.t_real_received >= r.t_real_sent, "real stamps")
  assert(r.validation ~= "pending" or i >= #recs - 1, "only the newest can still be pending")
  if r.validation == "ok" then assert(r.tool_call and r.tool_call.tool, "accepted record has its call") end
end
-- both context sizes, compact lighter than json
local sizes = recs[1].context_sizes
assert(sizes.compact and sizes.json and sizes.compact < sizes.json, "compact < json")
-- some action ended and got its result text
local withResult = 0
for _, r in ipairs(recs) do if r.result then withResult += 1 end end
assert(withResult > 0, "results filled")

-- an invalid call is recorded with the validation reason and counts as an error
local bad = Sim.new()
local ok, why = bad:apply("miner", { name = "mine", args = { vein = "nope" } }, { skill = "probe" })
assert(not ok)
local r = all(bad)[1]
eq(r.validation, why); assert(DecisionLog.isError(r) and DecisionLog.errorReason(r) == why)
eq(r.source, "skill:probe"); eq(r.compute_spent, 0, "skill steps are free")
local m = View.model(bad, View.new())
assert(m.rows[1].isError and m.rows[1].text:find(why, 1, true), "error row shows the reason")

-- a valid skill step too
local good = Sim.new()
assert(good:apply("miner", { name = "wait", args = { seconds = 30 } }, { skill = "idle" }))
local g = all(good)[1]
eq(g.source, "skill:idle"); eq(g.validation, "ok"); eq(g.compute_spent, 0); eq(g.tool_call.tool, "wait")

-- filters, newest first, paging
local v = View.new()
local full = View.model(sim, v)
for i = 2, #full.rows do assert(full.rows[i - 1].id > full.rows[i].id, "newest first") end
eq(full.total, #recs)
v.source = "skill"; eq(View.model(sim, v).shown, 0)
v.source = "ai"; eq(View.model(sim, v).shown, #recs)
v.agent = "nobody"; eq(View.model(sim, v).shown, 0)
local mixed = Sim.new()
mixed:apply("miner", { name = "mine", args = { vein = "nope" } }, { skill = "a" })
mixed:apply("miner", { name = "wait", args = { seconds = 30 } }, { skill = "b" })
local ev = View.new()
assert(View.act(ev, "logs.errors")); eq(View.model(mixed, ev).shown, 1)
assert(View.act(ev, "logs.errors")); assert(View.act(ev, "logs.source.skill")); eq(View.model(mixed, ev).shown, 2)
assert(View.act(ev, "logs.select.2")); eq(View.model(mixed, ev).detail.id, 2)
assert(View.act(ev, "logs.select.2")); eq(View.model(mixed, ev).detail, nil)
assert(not View.act(ev, "nav.map"))

-- header stats match a manual calculation over the window
local st = newRun(6000)
local span = st.compute:span()
local tNow = st.tick * st.b.tickSeconds
local credits = 0
for _, e in ipairs(st.earnings.miner or {}) do if e.t >= tNow - span then credits += e.amount end end
local stats = DecisionLog.stats(st, "miner")
assert(math.abs(stats.credits_per_hour - credits / span * 3600) < 1e-9, "credits/h")
assert(math.abs(stats.compute_per_hour - st.compute:agentRatePerHour("miner")) < 1e-9, "Compute/h")
assert(math.abs(stats.net_per_hour - (stats.credits_per_hour - stats.compute_per_hour * st.aiConfig.compute.priceCredits)) < 1e-9, "net/h")
local perAgentSum = 0
for _, id in ipairs(st.agentOrder) do perAgentSum += DecisionLog.stats(st, id).credits_per_hour end
assert(perAgentSum > 0, "some revenue in the window")

-- cap per agent
local cap = Sim.new()
cap.aiConfig.recordsMax = 3
for _ = 1, 7 do cap:apply("miner", { name = "wait", args = { seconds = 30 } }, { skill = "x" }) end
eq(#cap.records.miner, 3); eq(cap.records.miner[1].id, 5, "oldest dropped")

-- save round trip keeps the records, and the run stays deterministic
local storage = Persistence.memoryStorage()
assert(Persistence.save(sim, storage, "s.json", 1))
local back = assert(Persistence.load(storage, "s.json"))
eq(Json.encode(back.records), Json.encode(sim.records), "records survive a save")
eq(back.recordSeq, sim.recordSeq)
local a, b = newRun(2000), newRun(2000)
eq(Json.encode(a.records), Json.encode(b.records), "deterministic")

-- the screen: empty state with no records, list and detail once there are some
eq(View.total(Sim.new()), 0)
local function texts(node, out)
  out = out or {}
  if node.text then out[#out + 1] = node.text.text end
  for _, c in ipairs(node.children or {}) do texts(c, out) end
  return out
end
local function has(spec, needle)
  for _, t in ipairs(texts(spec)) do if t:find(needle, 1, true) then return true end end
  return false
end
local screenView = View.new()
screenView.selected = 1
local spec = Shell.spec(sim, "logs", { logs = screenView })
assert(has(spec, "DECISION LOG") and has(spec, "REASONING") and has(spec, "TOKENS"), "logs screen with detail")
assert(has(spec, "compact"), "both context sizes shown")
assert(has(Shell.spec(mixed, "logs", { logs = View.new() }), mixed.records.miner[1].validation), "error reason on screen")
print("logs OK")
