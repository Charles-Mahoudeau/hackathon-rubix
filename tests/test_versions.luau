-- Run from repo root: luau tests/test_versions.luau
-- GR5-13: prompt versions. Changing the directive, the equipped tools or a context setting starts a new version, the
-- per-version totals match a manual calculation over the decision records, short versions are flagged, and the compare
-- screen shows the rates and the directive diff.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Json = require("@scripts/sim/json")
local Persistence = require("@scripts/sim/persistence")
local DecisionLog = require("@scripts/sim/decision_log")
local Versions = require("@scripts/sim/versions")
local Shell = require("@scripts/ui/shell")
local View = require("@scripts/ui/logs_view")

local function eq(a, b, msg) if a ~= b then error((msg or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end end
local function near(a, b, msg) if math.abs(a - b) > 1e-6 then error((msg or "near") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end end

local PRECISE = "Mine cobalt on K3 until the hold is 100%, then sell at HMC."
local OTHER = "Mine cobalt on K3 until the hold is 80%, then sell at Orbis. Scan first."

local function newSim()
  local s = Sim.new()
  s:setDecider(Ai.decide)
  return s
end

-- 1. every change of directive / tools / context settings starts a version; going back resumes the old one
local s = newSim()
s:setDirective("miner", PRECISE)
s:run(10)
eq(#s.versions.miner, 1, "one version to start with")
local v1 = s.versions.miner[1]
eq(v1.directive, PRECISE, "the text is kept"); eq(v1.number, 1)
assert(#v1.tools > 0 and v1.settings.format == "compact", "tools and settings are kept")
s:setDirective("miner", OTHER)
s:run(10)
eq(#s.versions.miner, 2, "new directive, new version")
assert(s.versions.miner[2].id ~= v1.id)
assert(s:setContextSetting("miner", "format", "json"))
s:run(10)
eq(#s.versions.miner, 3, "new context setting, new version")
eq(s.versions.miner[3].settings.format, "json"); eq(s.versions.miner[2].settings.format, "compact", "old text untouched")
s:setDirective("miner", PRECISE)
assert(s:setContextSetting("miner", "format", "compact"))
s:run(10)
eq(#s.versions.miner, 3, "same text again is the same version")
eq(s.versions.miner[1].ticks, 20, "the first version resumed")
local tools = #s:equippedTools("miner")
s.upgrades.scanner = true
s:enterTier(2)
s:run(10)
assert(#s:equippedTools("miner") > tools, "the Scanner equips scan")
eq(#s.versions.miner, 4, "a new tool, new version")
assert(table.find(s.versions.miner[4].tools, "scan"))
local total = 0
for _, v in ipairs(s.versions.miner) do total += v.ticks end
eq(total, s.tick, "every tick belongs to exactly one version")

-- 2. totals per version match a hand calculation over the records
local run = newSim()
run:setDirective("miner", PRECISE)
run:run(3000)
run:setDirective("miner", "mine")
run:run(3000)
assert(run:setContextSetting("miner", "recent_results", 0))
run:run(3000)
eq(#run.versions.miner, 3)
local price = run.aiConfig.compute.priceCredits
local sumCredits, sumTicks = 0, 0
for _, v in ipairs(run.versions.miner) do
  local decisions, compute, credits, errors = 0, 0, 0, 0
  for _, rec in ipairs(run.records.miner) do
    if rec.prompt_version == v.id then
      decisions += 1
      compute += rec.compute_spent
      credits += rec.credits_delta
      if DecisionLog.isError(rec) then errors += 1 end
    end
  end
  local m = Versions.metrics(run, v)
  eq(m.decisions, decisions, "decisions"); near(m.compute, compute, "compute"); eq(m.credits, credits, "credits"); eq(m.errors, errors, "errors")
  local hours = v.ticks * run.b.tickSeconds / 3600
  near(m.seconds, v.ticks * run.b.tickSeconds, "active time")
  near(m.creditsPerHour, credits / hours, "credits/h"); near(m.computePerHour, compute / hours, "Compute/h")
  near(m.netPerHour, credits / hours - compute / hours * price, "net/h"); near(m.errorsPerHour, errors / hours, "errors/h")
  sumCredits += m.credits; sumTicks += v.ticks
end
eq(sumTicks, run.tick, "ticks add up")
eq(sumCredits, run.lifetimeRevenue, "all revenue lands on a version")
assert(sumCredits > 0, "the run earned something")

-- an invalid call and a failed action each count once as an error of the version that made them
local err = newSim()
local ok = err:apply("miner", { name = "mine", args = { vein = "nope" } }, { skill = "probe" })
assert(not ok)
eq(err.versions.miner[1].errors, 1, "refused call counted")
eq(err.versions.miner[1].decisions, 1)
local rec = err.records.miner[1]
DecisionLog.finished(err, rec.id, "late failure", false)
eq(err.versions.miner[1].errors, 1, "one record is one error")
assert(err.versions.miner[1].errors == Versions.metrics(err, err.versions.miner[1]).errors)

-- 3. versions with under 3 game minutes are flagged
local short = newSim()
short:setDirective("miner", PRECISE)
short:run(1000) -- 100 s
short:setDirective("miner", OTHER)
short:run(2000) -- 200 s
local mShort = Versions.metrics(short, short.versions.miner[1])
local mLong = Versions.metrics(short, short.versions.miner[2])
assert(not mShort.enoughData and mLong.enoughData, "100 s is not enough, 200 s is")
local model = View.model(short, { agent = "all", source = "all", errorsOnly = false, page = 0, compare = true }).compare
eq(model.notEnoughData, true); assert(model.a.note and model.a.note:find("not enough data", 1, true), "flagged on the older side")
eq(model.b.note, nil); assert(model.rows[1].better == nil, "no winner while a side is short")

-- 4. the diff marks only the words that differ
local da, db = Versions.diff("mine cobalt on K3 now", "mine iridium on K3")
local function joined(segs, changed)
  local out = {}
  for _, seg in ipairs(segs) do if seg.changed == changed then out[#out + 1] = (seg.text:gsub("%s+$", "")) end end
  return table.concat(out, "|")
end
eq(joined(da, true), "cobalt|now"); eq(joined(db, true), "iridium")
eq(joined(da, false), "mine|on K3"); eq(joined(db, false), "mine|on K3")
local same1, same2 = Versions.diff("a b c", "a b c")
eq(#same1, 1); eq(same1[1].changed, false); eq(#same2, 1)
local e1, e2 = Versions.diff("", "new text")
eq(#e1, 0); eq(joined(e2, true), "new text")

-- 5. save and load keep the versions and their totals, and the run is deterministic
local storage = Persistence.memoryStorage()
assert(Persistence.save(run, storage, "v.json", 1))
local back = assert(Persistence.load(storage, "v.json"))
eq(Json.encode(back.versions), Json.encode(run.versions), "versions survive a save")
back:setDecider(Ai.decide)
back:run(10)
eq(#back.versions.miner, 3, "no spurious version after a load")
local a, b = newSim(), newSim()
for _, x in ipairs({ a, b }) do x:setDirective("miner", PRECISE); x:run(500); x:setDirective("miner", OTHER); x:run(500) end
eq(Json.encode(a.versions), Json.encode(b.versions), "deterministic")

-- 6. the screen: version pickers, rates, the diff
local view = View.new()
view.compare = true
local spec = Shell.spec(run, "logs", { logs = view })
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
assert(has(spec, "COMPARE PROMPT VERSIONS") and has(spec, "Credits / h") and has(spec, "Net credits / h") and has(spec, "Errors / h"), "compare screen")
assert(has(spec, "DIRECTIVE A") and has(spec, "v3 "), "directives and version buttons")
local cm = View.model(run, view).compare
eq(cm.a.title:sub(1, 2), "v2", "default A is the previous version"); eq(cm.b.title:sub(1, 2), "v3", "default B is the latest")
assert(View.act(view, "logs.cmpa." .. run.versions.miner[1].id)); assert(View.act(view, "logs.cmpb." .. run.versions.miner[2].id))
cm = View.model(run, view).compare
eq(cm.a.title:sub(1, 2), "v1"); eq(cm.b.title:sub(1, 2), "v2")
local changedWords = 0
for _, line in ipairs(cm.directiveA) do for _, w in ipairs(line) do if w.changed then changedWords += 1 end end end
assert(changedWords > 0, "differences are highlighted")
assert(View.act(view, "logs.compare")); eq(View.model(run, view).compare, nil, "back to the list")
print("versions OK")
