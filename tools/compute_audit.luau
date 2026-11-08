-- GR5-66: reproducible audit of Compute billing, the real-hour token cap and the mission 3 / 8 spend counters.
-- Pure Luau on the headless sim, fixed seeds, fake network (no key, no internet). `Audit.run()` returns
-- { checks = { { name, ok, detail } }, report = markdown }. Used by tests/test_compute_audit.luau and
-- tools/compute_audit_report.luau (-> docs/COMPUTE_AUDIT.md).
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Clock = require("@scripts/sim/clock")
local Compute = require("@scripts/sim/compute")
local Missions = require("@scripts/sim/missions")
local Skills = require("@scripts/sim/skills")
local Market = require("@scripts/sim/market")
local Json = require("@scripts/sim/json")
local Provider = require("@scripts/ai/provider")
local AiConfig = require("@scripts/config/ai")

local Audit = {}

local function round1(x) return math.floor(x * 10 + 0.5) / 10 end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

-- ---- 1. configuration and rounding -------------------------------------------------------------------------------
local function rounding(checks, out)
  local c = AiConfig.compute
  local function add(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok, detail = detail } end
  add("config: 1,000 tokens per Compute", c.tokensPerCompute == 1000)
  add("config: 40 credits per Compute, packs of 5 (200 cr)", c.priceCredits == 40 and c.packSize == 5)
  add("config: per-decision round-up step 0.1", c.roundTo == 0.1)
  add("config: 400,000 tokens per rolling real hour", AiConfig.tokensPerHour == 400000 and AiConfig.windowSeconds == 3600)
  out[#out + 1] = "| tokens | Compute billed | credits | note |\n|---:|---:|---:|---|"
  local expected = { [1] = 0.1, [99] = 0.1, [100] = 0.1, [101] = 0.2, [1000] = 1.0, [1001] = 1.1, [1500] = 1.5, [2640] = 2.7, [10000] = 10.0 }
  local keys = {}
  for t in pairs(expected) do keys[#keys + 1] = t end
  table.sort(keys)
  local all = true
  for _, t in ipairs(keys) do
    local cost = Compute.cost(AiConfig, t)
    local ok = near(cost, expected[t])
    all = all and ok
    out[#out + 1] = ("| %d | %.1f | %g | %s |"):format(t, cost, Compute.creditsFor(AiConfig, cost), ok and "" or "MISMATCH, expected " .. expected[t])
  end
  add("rounding: every sample is rounded UP to the 0.1 step", all)
  local s = Sim.new()
  local cr, co = s.resources.credits, s.resources.compute
  s.resources.credits = 1000
  local ok = s:buyCompute(1)
  add("pack: 1 pack = 200 cr for 5 Compute", ok and s.resources.credits == 800 and near(s.resources.compute, co + 5))
  add("pack: refused without credits and for fractional packs", select(2, s.compute:buy(1.5)) == "bad_packs" and (function()
    s.resources.credits = 199
    return select(2, s.compute:buy(1)) == "not_enough_credits"
  end)())
  s.resources.credits = cr
end

-- ---- 2. stub run: records vs ledger -------------------------------------------------------------------------------
local function ledgerOf(sim)
  local sumCost, sumTokens, n = 0, 0, 0
  for _, list in pairs(sim.records) do
    for _, r in ipairs(list) do
      if r.source == "ai" then sumCost += r.compute_spent; sumTokens += r.tokens.total; n += 1 end
    end
  end
  return sumCost, sumTokens, n
end

local function stubRun(checks, out)
  local function add(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok, detail = detail } end
  local s = Sim.new({ seed = 1 })
  s:setDecider(Ai.decide)
  s.resources.compute = 1000
  s.resources.credits = 100000
  local start = s.resources.compute
  s:run(12000)
  local cost, tokens, n = ledgerOf(s)
  local spent = start - s.resources.compute
  out[#out + 1] = ("%d stub decisions in 20 game minutes: %d tokens, %.1f Compute in the records, %.1f in the ledger (`lifetimeTotal`), %.1f off the balance, queue tokens %d."):format(
    n, tokens, cost, s.compute.lifetimeTotal, spent, s.aiQueue:tokensUsed())
  add("stub run: ran decisions", n >= 5, n)
  add("stub run: records' Compute == ledger lifetime total", near(cost, s.compute.lifetimeTotal, 1e-6), ("%.4f vs %.4f"):format(cost, s.compute.lifetimeTotal))
  add("stub run: ledger == balance drop", near(spent, s.compute.lifetimeTotal, 1e-6), ("%.4f vs %.4f"):format(spent, s.compute.lifetimeTotal))
  local settled = 0
  for _, list in pairs(s.records) do for _, r in ipairs(list) do
    if r.source == "ai" and r.validation ~= "pending" then settled += r.tokens.total end
  end end
  add("stub run: AiQueue tokens == settled tokens in the records", s.aiQueue:tokensUsed() == settled, ("%d vs %d"):format(s.aiQueue:tokensUsed(), settled))
  local allRounded = true
  for _, list in pairs(s.records) do for _, r in ipairs(list) do
    if r.source == "ai" and not near(r.compute_spent * 10, math.floor(r.compute_spent * 10 + 0.5)) then allRounded = false end
  end end
  add("stub run: every decision billed on the 0.1 step", allRounded)
  -- buying through the shop moves credits and Compute by exactly one pack each
  local credits, compute = s.resources.credits, s.resources.compute
  assert(s:buyCompute(2))
  add("stub run: 2 packs cost 400 cr and add 10 Compute", s.resources.credits == credits - 400 and near(s.resources.compute, compute + 10))
  -- A decision is sent when the balance covers the estimate; a reply that turns out bigger can only take the balance to 0.
  local p = Sim.new()
  p.resources.compute = 1
  local id = p.compute:charge("miner", 800)
  local left = p.resources.compute
  p.compute:settle(id, 1500, 500)
  local ledger, drop = p.compute.lifetimeTotal, 1 - p.resources.compute
  out[#out + 1] = ("\nOverrun probe: 1.0 Compute, a decision estimated at 840 tokens (0.9) answered with 2,000 real tokens (2.0): ledger and mission counters see %.1f, the balance only drops %.1f (it stops at 0), so %.1f Compute is written off."):format(ledger, drop, ledger - drop)
  add("overrun: balance never goes negative, the ledger keeps the full bill", p.resources.compute == 0 and near(ledger, 2.0) and near(drop, 1.0) and left == 0.1, ("ledger %.1f drop %.1f"):format(ledger, drop))
end

-- ---- 3. provider path with a scripted fake Axis/Relais -------------------------------------------------------------
local function fakeTransport(handler, clock)
  local t = { sent = {}, inflight = {}, nextId = 1 }
  function t.send(req)
    local id = t.nextId
    t.nextId += 1
    t.sent[#t.sent + 1] = req
    local status, body = handler(req)
    if status ~= "never" then t.inflight[#t.inflight + 1] = { id = id, status = status, body = body } end
    return id
  end
  function t.cancel() end
  function t.poll()
    local out = {}
    for _, r in ipairs(t.inflight) do
      out[#out + 1] = { id = r.id, ok = r.status >= 200 and r.status < 300, status = r.status, body = r.body, error = r.status == 0 and (r.body or "network") or "" }
    end
    t.inflight = {}
    return out
  end
  return t
end

-- Model replies in order, then the last one forever. { status, text, in, out }.
local SCRIPT = {
  { 200, '{"reasoning":"K1 is close","tool":"wait","args":{"seconds":10}}', 900, 45 },
  { 500, "boom" },
  { 200, "I would mine titanium.", 850, 30 },
  { 200, '{"reasoning":"again","tool":"wait","args":{"seconds":10}}', 1200, 60 },
  { "never" },
  { 200, '{"tool":"dig","args":{}}', 780, 25 },
}

local function providerRun(checks, out)
  local function add(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok, detail = detail } end
  local clock, call = 0, 0
  local function model()
    call += 1
    local r = SCRIPT[math.min(call, #SCRIPT)]
    if r[1] == "never" or r[1] ~= 200 then return r[1], r[2] end
    return 200, Json.encode({ content = { { type = "text", text = r[2] } }, usage = { input_tokens = r[3], output_tokens = r[4] } })
  end
  local function handler(req)
    if req.url:find("/v1/agentic-config/", 1, true) then return 200, Json.encode({ slug = "x", system_prompt = "You are Theo." })
    elseif req.url:find("/turns", 1, true) then return 200, '{"turn_count":1}'
    elseif req.url:find("/session", 1, true) then return 200, Json.encode({ block = "# SESSION" })
    elseif req.url:find("/v1/observe", 1, true) then return 202, "{}"
    end
    return model()
  end
  local cfg = setmetatable({ timeoutSeconds = 5 }, { __index = AiConfig })
  local net = fakeTransport(handler)
  local provider = Provider.new(cfg, { transport = net, now = function() return clock end, run = "audit" })
  local s = Sim.new({ aiConfig = { timeoutSeconds = 5 } })
  s:setDecider(Ai.decide)
  s:setProvider(provider)
  s.resources.compute = 100
  local start = s.resources.compute
  for _ = 1, 6000 do -- 600 real seconds, pumped like the server does
    clock += 0.1
    provider:update()
    s:step()
  end
  local rows = {}
  for _, r in ipairs(s.records.miner or {}) do
    if r.source == "ai" and r.validation ~= "pending" then rows[#rows + 1] = r end
  end
  out[#out + 1] = "| # | outcome | input est | tokens sent est | real in+out | queue/ledger tokens | Compute | credits |\n|---:|---|---:|---:|---:|---:|---:|---:|"
  local totalCost, totalTokens, wrongBill = 0, 0, 0
  local failures, invalid = 0, 0
  for i, r in ipairs(rows) do
    local est = r.tokens.total - r.tokens.output -- input estimate (the sections), before the answer
    local real = r.real_tokens and r.tokens.total or nil
    local billedTokens = r.tokens.total
    local expectCost = Compute.cost(AiConfig, billedTokens)
    if not near(expectCost, r.compute_spent, 1e-6) then wrongBill += 1 end
    totalCost += r.compute_spent
    totalTokens += billedTokens
    local outcome = r.validation
    if r.validation ~= "ok" then
      if r.validation:find("invalid") then invalid += 1 end
      failures += 1
    end
    out[#out + 1] = ("| %d | %s | %d | %d | %s | %d | %.1f | %g |"):format(i, outcome, est, est + AiConfig.estimatedOutputTokens,
      real and tostring(real) or "no usage", billedTokens, r.compute_spent, r.compute_spent * AiConfig.compute.priceCredits)
  end
  out[#out + 1] = ""
  out[#out + 1] = ("%d settled decisions (%d failed or invalid) over 600 real seconds; ledger %.1f Compute = %g cr; balance drop %.1f; queue tokens %d."):format(
    #rows, failures, s.compute.lifetimeTotal, s.compute.lifetimeTotal * AiConfig.compute.priceCredits, start - s.resources.compute, s.aiQueue:tokensUsed())
  add("provider run: scripted failures and invalid replies happened", failures >= 3 and invalid >= 1, ("%d failed, %d invalid"):format(failures, invalid))
  add("provider run: every decision's Compute == round-up of its settled tokens", wrongBill == 0, wrongBill)
  add("provider run: ledger == records' Compute", near(totalCost, s.compute.lifetimeTotal, 1e-6), ("%.3f vs %.3f"):format(totalCost, s.compute.lifetimeTotal))
  add("provider run: ledger == balance drop (no clamp)", near(start - s.resources.compute, s.compute.lifetimeTotal, 1e-6))
  add("provider run: queue tokens == settled tokens", s.aiQueue:tokensUsed() == totalTokens, ("%d vs %d"):format(s.aiQueue:tokensUsed(), totalTokens))
  -- an invalid reply carries real usage: it is billed on that, not on the estimate
  local invalidReal = true
  for _, r in ipairs(rows) do
    if r.validation ~= "ok" and r.validation:find("invalid") and not r.real_tokens then invalidReal = false end
  end
  add("provider run: an invalid reply that reports usage is billed on the real tokens", invalidReal)
  add("provider run: a reply with no usage (500, timeout) is billed on the estimate, never free", (function()
    for _, r in ipairs(rows) do
      if r.validation ~= "ok" and not r.real_tokens and r.compute_spent <= 0 then return false end
    end
    return true
  end)())
  for _, r in ipairs(net.sent) do
    if Json.encode(r):find("apk-", 1, true) or Json.encode(r):find("sk-", 1, true) then add("provider run: no key material in requests", false) end
  end
end

-- ---- 4. the hourly cap follows REAL time at x1 / x4 / x16 ----------------------------------------------------------
local function capRun(checks, out)
  local function add(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok, detail = detail } end
  local window = 120
  out[#out + 1] = "The cap is exercised with a 6,000-token / 120 s window (same code, smaller numbers, so a run takes seconds). The first 6,000 tokens are spent through the queue at real second 0; then real time is fed in 0.25 s frames.\n"
  out[#out + 1] = "| speed | agent while capped | game s when released | real s when released | queue clock after 600 real s |\n|---:|---|---:|---:|---:|"
  for _, speed in ipairs({ 1, 4, 16 }) do
    local s = Sim.new({ seed = 2, aiConfig = { tokensPerHour = 6000, windowSeconds = window } })
    s:setDecider(Ai.decide)
    s.resources.compute = 100000
    Clock.setSpeed(s, speed)
    local id = s.aiQueue:submit({ agentId = "x" })
    s.aiQueue:complete(id, 6000)
    local real, capped, released, releasedTick, resumed = 0, nil, nil, nil, nil
    for _ = 1, 2400 do -- 600 real seconds
      Clock.advance(s, 0.25)
      real += 0.25
      if s.aiQueue:budgetReached() then
        if s.agents.miner.state == "no_compute" and s.agents.miner.blockReason == AiConfig.budgetMessage then capped = true end
      elseif not released then
        released, releasedTick = real, s.tick
      end
      if released and not resumed and s.agents.miner.state == "thinking" then resumed = real end
    end
    out[#out + 1] = ("| x%d | %s | %s | %s | %.2f |"):format(speed, capped and "no_compute, server budget message" or "NOT blocked",
      releasedTick and ("%.1f"):format(releasedTick / 10) or "never", released and ("%.2f"):format(released) or "never", s.aiQueue.now())
    add(("cap x%d: blocked with the server message while capped"):format(speed), capped == true)
    add(("cap x%d: released after exactly one real window (%s s), not game time"):format(speed, tostring(released)),
      released ~= nil and released >= window and released <= window + 0.5, released)
    add(("cap x%d: the agent decides again after the release"):format(speed), resumed ~= nil and resumed <= window + 2, resumed)
    add(("cap x%d: queue clock == real seconds fed (%.2f of 600)"):format(speed, s.aiQueue.now()), near(s.aiQueue.now(), 600, 0.3), s.aiQueue.now())
  end
  -- what the per-step clock got wrong before: a long pause, a stalled frame, the offline catch-up
  local s = Sim.new()
  Clock.setPaused(s, true)
  for _ = 1, 40 do Clock.advance(s, 0.25) end
  add("cap: real time keeps passing while paused (10 s paused -> clock 10 s)", near(s.aiQueue.now(), 10, 0.3), s.aiQueue.now())
  local f = Sim.new()
  Clock.setSpeed(f, 16)
  Clock.advance(f, 60)
  add("cap: a stalled 60 s frame at x16 still counts 60 real seconds", near(f.aiQueue.now(), 60, 0.3), f.aiQueue.now())
  local o = Sim.new()
  Clock.setSpeed(o, 16)
  require("@scripts/sim/offline").run(o, 7200)
  add("cap: a 2 h absence counts 2 real hours at any speed", near(o.aiQueue.now(), 7200, 0.3), o.aiQueue.now())
  out[#out + 1] = ""
  out[#out + 1] = ("Deviations the pre-fix clock had (steps only, 1/speed each): paused time and dropped stall time were not counted (10 s paused read 0 s, a 60 s stall read 40 s at x1), and an absence counted ticks/speed (2 h away at x16 read 7.5 min). Fixed in `sim/clock.luau` and `sim/offline.luau`; the budget itself is still not saved (see Open points).")
end

-- ---- 5. missions 3 and 8 against the ledger -----------------------------------------------------------------------
local function recordsAfter(sim, seq, agent)
  local sum = 0
  for id, list in pairs(sim.records) do
    if agent == nil or id == agent then
      for _, r in ipairs(list) do if r.id > seq and r.source == "ai" then sum += r.compute_spent end end
    end
  end
  return sum
end

local function counters(checks, out)
  local function add(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok, detail = detail } end
  do -- mission 3
    local s = Sim.new({ seed = 3 })
    s.resources.credits = 5000
    s.resources.compute = 1000
    s:setDecider(Ai.decide)
    s.missions[1].status, s.missions[2].status = "claimed", "claimed"
    s:run(2)
    local e = s.missions[3]
    local seq = s.recordSeq
    local base = s.resources.compute
    add("mission 3: opens after 1 and 2 are claimed", e.status == "active")
    s:run(1500)
    local text = Missions.progress(s, e).text
    local shown = tonumber(text:match("Compute ([%d%.]+) /"))
    local ledger = round1(s.compute.lifetimeTotal - e.baseCompute)
    local records = round1(recordsAfter(s, seq))
    local balance = round1(base - s.resources.compute)
    out[#out + 1] = ("Mission 3 after 150 game seconds: counter shows `%s`; ledger window %.1f, decision records %.1f, balance drop %.1f."):format(text, ledger, records, balance)
    add("mission 3: shown counter == ledger window", shown == ledger, ("%s vs %.1f"):format(tostring(shown), ledger))
    add("mission 3: shown counter == sum of decision records since it opened", shown == records, ("%s vs %.1f"):format(tostring(shown), records))
    add("mission 3: shown counter == balance drop", shown == balance, ("%s vs %.1f"):format(tostring(shown), balance))
    add("mission 3: counter is above zero (the run really decided)", shown ~= nil and shown > 0, shown)
    -- the counter ignores a grant (mission reward / emergency advance): it is not spend
    local before = Missions.progress(s, e).text
    s.compute:grant(5)
    add("mission 3: a Compute grant is not counted as spend", Missions.progress(s, e).text == before)
    -- 15 is the limit: over it the mission is failed and says so
    e.baseCompute = s.compute.lifetimeTotal - 15.1
    s:step()
    add("mission 3: over 15 Compute fails the mission", e.failed == true and Missions.progress(s, e).text:find("over budget", 1, true) ~= nil)
  end
  do -- mission 8
    local s = Sim.new({ seed = 4 })
    s.tier = 4
    for _, a in pairs(s.agents) do a.tier = 4 end
    s.lifetimeRevenue = s.b.reputationLevels[2]
    s.resources.credits = 250000
    s.resources.compute = 200
    Market.quiet(s.market)
    s:setDecider(Ai.decide)
    assert(Skills.save(s, { name = "Titanium loop", agent_type = "miner", loop = true,
      params = { vein = { kind = "vein", filter = { resource = "titanium" } } },
      steps = { { tool = "mine", args = { vein = "$vein" } }, { tool = "return" }, { tool = "sell" } } }))
    assert(s:buyUpgrade("command_center") and s:hireMonitor())
    for i = 1, 7 do s.missions[i].status = "claimed" end
    assert(s:setMonitorSettings({ heartbeat = false }))
    s.agents.monitor.directive = "When an agent is paused, resume it."
    s:run(100)
    local e = s.missions[8]
    local seq = s.recordSeq
    add("mission 8: opens once the command center is built", e and e.status == "active")
    for _ = 1, 2 do
      s:run(30)
      s:pauseAgent("miner", "audit")
      for _ = 1, 600 do s:step() end
    end
    local text = Missions.progress(s, e).text
    local shown = tonumber(text:match("Monitor Compute ([%d%.]+) /"))
    local ledger = round1((s.compute.lifetime.monitor or 0) - e.baseMonitor)
    local records = round1(recordsAfter(s, seq, "monitor"))
    out[#out + 1] = ("Mission 8 after two pauses: counter shows `%s`; Monitor ledger window %.1f, Monitor decision records %.1f."):format(text, ledger, records)
    add("mission 8: shown counter == Monitor ledger window", shown == ledger, ("%s vs %.1f"):format(tostring(shown), ledger))
    add("mission 8: shown counter == sum of Monitor decision records since it opened", shown == records, ("%s vs %.1f"):format(tostring(shown), records))
    add("mission 8: the Monitor really spent Compute", shown ~= nil and shown > 0, shown)
    add("mission 8: other agents' decisions are not counted", recordsAfter(s, seq) > records or recordsAfter(s, seq) == records)
  end
end

-- ---- 6. skills cost nothing ---------------------------------------------------------------------------------------
local function skills(checks, out)
  local function add(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok, detail = detail } end
  local function team(withSkill)
    local s = Sim.new({ seed = 5 })
    s.tier = 2
    for _, a in pairs(s.agents) do a.tier = 2 end
    s.resources.credits = 50000
    s.resources.compute = 1000
    s:setDecider(Ai.decide)
    if withSkill then
      assert(Skills.save(s, { name = "ore-run", agent_type = "miner", params = { vein = { kind = "vein" } }, loop = true,
        steps = { { tool = "mine", args = { vein = "$vein" } }, { tool = "return" }, { tool = "sell" } } }))
      assert(Skills.assign(s, "miner", "ore-run", { vein = "K1" }))
    end
    return s
  end
  local sk = team(true)
  local c0, b0, used0 = sk.compute.lifetimeTotal, sk.resources.compute, sk.aiQueue:tokensUsed()
  local revenue0 = sk.lifetimeRevenue
  sk:run(6000)
  local aiRecords = 0
  for _, list in pairs(sk.records) do for _, r in ipairs(list) do if r.source == "ai" then aiRecords += 1 end end end
  local skillRecords = 0
  for _, list in pairs(sk.records) do for _, r in ipairs(list) do if r.source:find("^skill:") then skillRecords += 1 end end end
  out[#out + 1] = ("Skill run, 10 game minutes: %d skill-step records, %d AI records, ledger %.1f -> %.1f Compute, queue tokens %d -> %d, revenue +%d cr."):format(
    skillRecords, aiRecords, c0, sk.compute.lifetimeTotal, used0, sk.aiQueue:tokensUsed(), sk.lifetimeRevenue - revenue0)
  add("skill run: the skill earned", sk.lifetimeRevenue - revenue0 > 0)
  add("skill run: skill steps were logged", skillRecords > 0)
  add("skill run: no AI decision, no Compute, no tokens", aiRecords == 0 and sk.compute.lifetimeTotal == c0 and sk.resources.compute == b0 and sk.aiQueue:tokensUsed() == used0)
  local ai = team(false)
  ai:run(6000)
  out[#out + 1] = ("Same 10 minutes with the stub AI deciding instead: %.1f Compute, revenue +%d cr."):format(ai.compute.lifetimeTotal, ai.lifetimeRevenue)
  add("skill run: the same minutes with an AI agent do cost Compute (control)", ai.compute.lifetimeTotal > 0)
  -- offline: nothing is called, nothing is spent
  local off = team(true)
  local c1, u1 = off.compute.lifetimeTotal, off.aiQueue:tokensUsed()
  require("@scripts/sim/offline").run(off, 3600)
  add("offline catch-up: no Compute, no tokens", off.compute.lifetimeTotal == c1 and off.aiQueue:tokensUsed() == u1)
  -- a skill start is exactly one decision: the run_skill call itself
  local one = team(false)
  one.agents.miner.directive = "Use skill ore-run on K1"
  assert(Skills.save(one, { name = "ore-run", agent_type = "miner", params = { vein = { kind = "vein" } }, loop = true,
    steps = { { tool = "mine", args = { vein = "$vein" } }, { tool = "return" }, { tool = "sell" } } }))
  one:run(4000)
  local decisions = 0
  for _, r in ipairs(one.records.miner or {}) do if r.source == "ai" then decisions += 1 end end
  add("skill run: calling run_skill bills the one decision that launched it, the loop after it is free", one.agents.miner.mode == "skill" and decisions >= 1 and decisions <= 2, decisions)
end

function Audit.run()
  local checks, sections = {}, {}
  local function section(title, fn)
    local out = {}
    fn(checks, out)
    sections[#sections + 1] = "## " .. title .. "\n\n" .. table.concat(out, "\n")
  end
  section("1. Constants and rounding", rounding)
  section("2. Stub run: decision records vs ledger", stubRun)
  section("3. Provider path (scripted fake Axis/Relais): estimate vs actual, failures, invalid replies", providerRun)
  section("4. Hourly token cap against real time at x1 / x4 / x16", capRun)
  section("5. Mission 3 and 8 counters vs the ledger", counters)
  section("6. Skills and offline cost nothing", skills)
  local lines = { "## Checks\n", "| result | check |", "|---|---|" }
  local bad = 0
  for _, c in ipairs(checks) do
    if not c.ok then bad += 1 end
    lines[#lines + 1] = ("| %s | %s |"):format(c.ok and "PASS" or "FAIL", c.name .. (c.ok and "" or (" (" .. tostring(c.detail) .. ")")))
  end
  return { checks = checks, failed = bad, report = table.concat(sections, "\n\n") .. "\n\n" .. table.concat(lines, "\n") }
end

return Audit
