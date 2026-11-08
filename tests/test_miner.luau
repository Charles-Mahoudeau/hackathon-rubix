-- Run from repo root: luau tests/test_miner.luau
-- GR5-4: the Miner agent. Directive -> stub decision -> mine/return/sell, Compute per decision, feed, errors.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local AiConfig = require("@scripts/config/ai")
local Compute = require("@scripts/sim/compute")
local Persistence = require("@scripts/sim/persistence")

local PRECISE = "Mine cobalt on K3 until the hold is 100%, then sell at HMC."

local function near(a, b, eps, msg) assert(math.abs(a - b) <= (eps or 1e-6), (msg or "near") .. ": " .. a .. " vs " .. b) end

local function newSim(directive, opts)
  local s = Sim.new(opts)
  s:setDecider(Ai.decide)
  s:setDirective("miner", directive or "")
  return s
end

local function feedCalls(s)
  local out = {}
  for _, e in ipairs(s.feed) do if e.kind == "call" then out[#out + 1] = e end end
  return out
end

-- 1. a precise directive mines, returns and sells; Compute drops per decision; every call is in the feed with its result
do
  local s = newSim(PRECISE)
  local credits0, compute0 = s.resources.credits, s.resources.compute
  s:run(6000)
  assert(s.resources.credits > credits0, "credits grow")
  local spent = compute0 - s.resources.compute
  assert(spent > 0, "Compute decreases")
  local sum = 0
  for _, e in ipairs(s.compute.spend) do sum += e.cost end
  near(spent, sum, 0.05, "the ledger explains every Compute point")
  local calls = feedCalls(s)
  assert(#calls >= 3, "several calls in the feed: " .. #calls)
  local sold = false
  for _, e in ipairs(s.feed) do
    if e.kind == "call" and e.status ~= "running" then
      assert(e.text:find(" -> ", 1, true), "result on every finished call: " .. e.text)
      assert(not e.text:find("[\128-\255]"), "feed text is ASCII, the UI font has no other glyphs: " .. e.text)
    end
    if e.kind == "info" and e.text:find("sold", 1, true) then sold = true end
  end
  assert(calls[1].text:find("^mine%(K3, 100%%%) %-> %+%d+ cobalt %(%d+ s%)$"), "mine line: " .. calls[1].text)
  assert(sold, "the sale is listed")
  local Model = require("@scripts/ui/shell_model")
  s.feed[#s.feed + 1] = { text = "old save \226\134\146 line", status = "ok" }
  assert(Model.feed(s)[#Model.feed(s)].text == "old save -> line", "an arrow from an old save is shown as ASCII")
  -- the feed has one line per decision: decisions == calls
  assert(#s.compute.spend >= #calls and #s.compute.spend <= #calls + 1, "one feed call per decision")
end

-- 2. no Compute: one badge, one message; a pack (5 Compute for 200 cr) brings the agent back
do
  local s = newSim(PRECISE)
  s.resources.compute = 0.05
  s:run(100)
  local miner = s.agents.miner
  assert(miner.state == "no_compute" and miner.blockReason, "badge: " .. tostring(miner.state))
  local msgs = 0
  for _, e in ipairs(s.feed) do if e.text:find("no_compute", 1, true) then msgs += 1 end end
  assert(msgs == 1, "one feed message, got " .. msgs)
  s:run(100)
  msgs = 0
  for _, e in ipairs(s.feed) do if e.text:find("no_compute", 1, true) then msgs += 1 end end
  assert(msgs == 1, "still one message")
  local cr, cp = s.resources.credits, s.resources.compute
  assert(s:buyCompute(1))
  near(s.resources.credits, cr - 200); near(s.resources.compute, cp + 5, 0.06, "pack")
  s:run(200)
  assert(s.agents.miner.state ~= "no_compute" and #feedCalls(s) >= 1, "agent decides again")
end

-- 3. vague vs precise: at least 2x credits per minute (summed over seeds, gross and net of Compute at the pack price)
do
  local pg, vg, pc, vc = 0, 0, 0, 0
  for seed = 1, 6 do
    for _, case in ipairs({ { PRECISE, "p" }, { "", "v" } }) do
      local s = newSim(case[1], { seed = seed })
      s.resources.compute, s.resources.credits = 10000, 100000
      s:run(6000)
      local gain, used = s.resources.credits - 100000, 10000 - s.resources.compute
      if case[2] == "p" then pg += gain; pc += used else vg += gain; vc += used end
    end
  end
  local price = AiConfig.compute.priceCredits / AiConfig.compute.packSize
  local gross, net = pg / vg, (pg - pc * price) / (vg - vc * price)
  print(("vague vs precise: gross x%.2f, net of Compute x%.2f"):format(gross, net))
  assert(gross >= 2 and net >= 2, "precise must earn >= 2x vague")
end

-- 4. bailout only under the 8.5 conditions
do
  local s = newSim(PRECISE)
  s.resources.compute, s.resources.credits = 1, 100
  s:step()
  assert(s.offer and s.offer.kind == "emergency_advance", "offered when poor and idle")
  s.resources.credits = 250; s:step()
  assert(s.offer == nil, "not when credits suffice")
  s.resources.credits = 100; s.ships.s1.cargo = 10; s:step()
  assert(s.offer == nil, "not while the hold has cargo")
  s.ships.s1.cargo = 0; s.agents.miner.mode = "skill"; s:step()
  assert(s.offer == nil, "not while a skill runs")
  s.agents.miner.mode = "default"; s.resources.compute = 5; s:step()
  assert(s.offer == nil, "not when Compute suffices")
end

-- 5. error pauses (spec 8.4)
do
  local function pausedAfter(decider, aiConfig)
    local s = Sim.new({ aiConfig = aiConfig })
    s.resources.compute = 100
    s:setDecider(decider)
    s:run(600)
    return s
  end
  local s = pausedAfter(function() return { name = "dig", args = {} } end)
  assert(s.agents.miner.state == "paused_error", "2 invalid responses pause: " .. s.agents.miner.state)
  local n = 0
  for _, l in ipairs(s.logs) do if l.msg:find("rejected dig", 1, true) then n += 1 end end
  assert(n == 2, "stopped after 2, got " .. n)
  s:setDirective("miner", "mine cobalt")
  s:setDecider(Ai.decide)
  s:run(100)
  assert(s.agents.miner.state == "paused_error", "stays paused until resumed")
  assert(s:resumeAgent("miner") and s.agents.miner.state == "idle")
  s:run(200)
  assert(#feedCalls(s) >= 1, "plays again after resume")

  s = pausedAfter(function() return { name = "mine", args = { vein = "K99" } } end, { errorRules = { invalidResponses = 99, providerErrors = 3, sameFailingCall = 2 } })
  assert(s.agents.miner.state == "paused_error" and s.agents.miner.blockReason:find("same call"), "same failing call twice")

  local p = Sim.new()
  p:noteFailure("miner", "provider"); p:noteFailure("miner", "provider")
  assert(p.agents.miner.state ~= "paused_error", "2 provider errors are tolerated")
  p:noteFailure("miner", "provider")
  assert(p.agents.miner.state == "paused_error", "3 provider errors pause")

  local ok = Sim.new()
  ok:noteFailure("miner", "invalid"); ok:noteSuccess("miner"); ok:noteFailure("miner", "invalid")
  assert(ok.agents.miner.state ~= "paused_error", "a good decision resets the streak")
end

-- 6. determinism, thrash guard intact, save/load keeps directive and feed
do
  local a, b = newSim(PRECISE), newSim(PRECISE)
  a:run(3000); b:run(3000)
  assert(a.resources.credits == b.resources.credits and #a.feed == #b.feed, "same seed, same game")
  local x, y = newSim(""), newSim("")
  x:run(3000); y:run(3000)
  assert(x.resources.credits == y.resources.credits and x.rng.stub == y.rng.stub, "stub stream deterministic")
  local data = Persistence.decode(Persistence.encode(Persistence.serialize(a, 0)))
  local r = Persistence.restore(data)
  assert(r.agents.miner.directive == PRECISE and #r.feed == #a.feed and r.feedSeq == a.feedSeq, "directive and feed saved")
end

print("miner OK")
