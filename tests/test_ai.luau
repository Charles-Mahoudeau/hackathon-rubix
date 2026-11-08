-- Run from repo root: luau tests/test_ai.luau   (the `@scripts` alias comes from .luaurc)
-- GR5-15: Axis provider. A fake Axis/Relais server stands in for the network; nothing here touches the internet.
local Json = require("./support/engine_json")
local Validator = require("@scripts/ai/validator")
local Compute = require("@scripts/sim/compute")
local Tools = require("@scripts/config/tools").schemas
local AiConfig = require("@scripts/config/ai")
local Provider = require("@scripts/ai/provider")
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")

local function eq(a, b, msg) if a ~= b then error((msg or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end end

-- ---- JSON ----
eq(Json.encode({ b = 1, a = { 1, 2, "x\n\"y\"" }, c = true }), '{"a":[1,2,"x\\n\\"y\\""],"b":1,"c":true}', "encode sorted")
eq(Json.encode(0.5), "0.5"); eq(Json.encode(3), "3")
local d = Json.tryDecode('{"a": [1, 2.5, -3e2, "\\u00e9\\ud83d\\ude00"], "b": {"c": null, "d": false}}')
eq(d.a[2], 2.5); eq(d.a[3], -300); eq(d.a[4], "é😀"); eq(d.b.d, false)
for _, bad in ipairs({ "", "{", '{"a":}', "[1,]", '{"a":1} x', '"abc', "nope", '{"a":"\\x"}' }) do
  local v, err = Json.tryDecode(bad)
  assert(v == nil and type(err) == "string", "decode must fail: " .. bad)
end
local deep = string.rep("[", 100) .. string.rep("]", 100)
assert(Json.tryDecode(deep) == nil, "depth limit")

-- ---- Validator (spec §10.3) ----
local equipped = { mine = Tools.mine, wait = Tools.wait, report = Tools.report }
local cfg = { reasoningMaxChars = 10 }
local function parse(text) return Validator.parse(text, equipped, cfg) end
local ok, call = parse('Sure!\n```json\n{"reasoning":"abcdefghijklmnop","tool":"mine","args":{"vein":"K1"}}\n```')
assert(ok and call.tool == "mine" and call.args.vein == "K1" and call.reasoning == "abcdefghij", "fenced reply + truncation")
for text, why in pairs({
  [""] = "empty", ["no json here"] = "no JSON", ['{"tool":"mine"']  = "bad JSON", ['{"args":{}}'] = "missing 'tool'",
  ['{"tool":"dig","args":{}}'] = "unknown or unequipped", ['{"tool":"scan","args":{"planet":"varn"}}'] = "unknown or unequipped",
  ['{"tool":"mine","args":{}}'] = "missing arg", ['{"tool":"mine","args":{"vein":4}}'] = "must be a string",
  ['{"tool":"wait","args":{"seconds":5}}'] = "below", ['{"tool":"wait","args":{"seconds":99999}}'] = "above",
  ['{"tool":"wait","args":{"seconds":12.5}}'] = "integer", ['{"tool":"mine","args":{"vein":"K1","x":1}}'] = "unexpected arg",
  ['{"tool":"mine","args":"K1"}'] = "'args' must be",
}) do
  local okk, _, err = parse(text)
  assert(not okk and err:find(why, 1, true), ("%q should fail with %q, got %s"):format(text, why, tostring(err)))
end
assert(parse('{"tool":"wait","args":{"seconds":60}}'), "wait ok")
assert(parse('{"tool":"wait"}') == false, "wait without seconds") -- required arg missing

eq(Compute.estimateTokens(AiConfig, "abcdefgh"), 2); eq(Compute.estimateTokens(AiConfig, ""), 0)
eq(Compute.cost(AiConfig, 1), 0.1); eq(Compute.cost(AiConfig, 1500), 1.5)

-- ---- Fake network ----
local clock = 0
local function now() return clock end

-- handler(req) -> status, body, delaySeconds. Responses are delivered by poll() once the clock reaches them.
local function fakeTransport(handler)
  local t = { sent = {}, inflight = {}, nextId = 1, cancelled = {} }
  function t.send(req)
    local id = t.nextId
    t.nextId += 1
    t.sent[#t.sent + 1] = req
    local status, body, delay = handler(req)
    if status ~= "never" then t.inflight[#t.inflight + 1] = { id = id, due = clock + (delay or 0), status = status, body = body } end
    return id
  end
  function t.cancel(id) t.cancelled[id] = true end
  function t.poll()
    local out, rest = {}, {}
    for _, r in ipairs(t.inflight) do
      if r.due <= clock then
        out[#out + 1] = { id = r.id, ok = r.status >= 200 and r.status < 300, status = r.status, body = r.body,
          error = r.status == 0 and (r.body or "network") or "" }
      else rest[#rest + 1] = r end
    end
    t.inflight = rest
    return out
  end
  return t
end

local function axisServer(model, delay)
  return function(req)
    if req.url:find("/v1/agentic-config/", 1, true) then return 200, Json.encode({ slug = "x", system_prompt = "You are Theo." }), delay
    elseif req.url:find("/turns", 1, true) then return 200, '{"turn_count":1}', delay
    elseif req.url:find("/session", 1, true) then return 200, Json.encode({ block = "# SESSION\nlast: mined" }), delay
    elseif req.url:find("/v1/observe", 1, true) then return 202, '{"accepted":true}', delay
    elseif req.url:find("relais", 1, true) then return model(req) end
    error("unexpected url " .. req.url)
  end
end

local function modelSays(text, inTok, outTok)
  return function() return 200, Json.encode({ content = { { type = "text", text = text } }, usage = { input_tokens = inTok or 700, output_tokens = outTok or 40 } }), 0 end
end

-- Runs the provider and the sim like the server does: pump the network every 0.1 s of real time, then step the sim.
local function run(sim, provider, seconds)
  for _ = 1, math.floor(seconds / 0.1) do
    clock += 0.1
    provider:update()
    sim:step()
  end
end

local function newSetup(model, delay, cfgOverride)
  clock = 0
  local c = setmetatable(cfgOverride or {}, { __index = AiConfig })
  local net = fakeTransport(axisServer(model, delay))
  local provider = Provider.new(c, { transport = net, now = now, run = "t1" })
  local sim = Sim.new({ aiConfig = cfgOverride })
  sim:setDecider(Ai.decide) -- the stub is the fallback
  sim:setProvider(provider)
  return sim, provider, net
end

local function logHas(sim, level, text)
  for _, l in ipairs(sim.logs) do if l.level == level and l.msg:find(text, 1, true) then return true end end
  return false
end

-- ---- Happy path: five calls, a decision applied, real tokens compared with the estimate ----
do
  local sim, provider, net = newSetup(modelSays('{"reasoning":"K1 is close","tool":"mine","args":{"vein":"K1"}}', 700, 40))
  run(sim, provider, 3)
  eq(sim.ships.s1.state == "idle", false, "the AI's mine order is running")
  assert(sim.ships.s1.vein and sim.ships.s1.vein.id == "K1", "mined the vein the AI chose")
  local kinds = {}
  for _, r in ipairs(net.sent) do
    kinds[#kinds + 1] = r.method .. " " .. r.url:gsub("%?.*", ""):gsub("^https://[^/]+", "")
  end
  eq(#net.sent, 6, "config, user turn, session, model, assistant turn, observe")
  assert(net.sent[1].url:find("^https://api.platform.lacale%-atlantle.com/v1/agentic%-config/harponneur%-theo%?resolve=true"), "config url")
  assert(net.sent[2].url:find("/v1/conversations/g5%-miner%-t1/turns$"), "g5- conversation id: " .. net.sent[2].url)
  eq(Json.tryDecode(net.sent[2].body).user_id, "g5:player")
  eq(Json.tryDecode(net.sent[2].body).role, "user")
  assert(net.sent[3].url:find("/v1/conversations/g5%-miner%-t1/session$"), "session read")
  assert(net.sent[4].url:find("^https://relais.lacale%-atlantle.com/v1/messages$"), "model call")
  local model = Json.tryDecode(net.sent[4].body)
  eq(model.model, "claude-haiku-4-5"); eq(model.max_tokens, 150)
  assert(model.system:find("You control one agent", 1, true) and model.system:find("You are Theo.", 1, true)
    and model.system:find("# SESSION", 1, true), "system = rules + agent prompt + memory block")
  assert(model.messages[1].role == "user" and model.messages[1].content:find("[TOOLS]", 1, true), "user message carries context and tools")
  eq(Json.tryDecode(net.sent[5].body).role, "assistant", "assistant turn recorded")
  assert(net.sent[6].url:find("/v1/observe$"), "observe sent")
  eq(Json.tryDecode(net.sent[6].body).trajectory.tokens.input, 700)
  assert(logHas(sim, "INFO", "ai miner: tokens est"), "token comparison logged")
  assert(logHas(sim, "INFO", "real 740"), "real tokens logged")
  eq(provider.records[1].input_tokens, 700); assert(provider.records[1].estimated_tokens > 0)
  -- keys never appear anywhere: headers only name env vars
  for _, r in ipairs(net.sent) do
    assert(not Json.encode(r):find("apk-", 1, true) and not Json.encode(r):find("sk-", 1, true), "no key material")
    assert(r.headers.Authorization:find("^Bearer {{env:AXIS_[A-Z_]+}}$"), "key is an env reference: " .. r.headers.Authorization)
    assert(r.timeout > 0 and r.timeout <= 20, "per-request timeout bounded by the turn: " .. tostring(r.timeout))
  end
  eq(net.sent[4].headers["anthropic-version"], "2023-06-01")
  assert(sim.resources.compute < 10, "compute charged")
end

-- ---- Agent system prompt is cached between turns ----
do
  local sim, provider, net = newSetup(modelSays('{"tool":"wait","args":{"seconds":10}}'))
  run(sim, provider, 40)
  local configs = 0
  for _, r in ipairs(net.sent) do if r.url:find("agentic%-config") then configs += 1 end end
  eq(configs, 1, "agentic-config fetched once within the TTL")
  assert(#provider.records >= 2, "several decisions")
end

-- ---- Failures never crash and fall back to the stub ----
local function failureCase(name, handler, expectLog, delay, cfgOverride, seconds, noFallback)
  local sim, provider, net = newSetup(handler, delay, cfgOverride)
  local okRun, err = pcall(run, sim, provider, seconds or 8)
  assert(okRun, name .. " crashed: " .. tostring(err))
  assert(logHas(sim, "ERROR", expectLog), name .. ": expected an ERROR log containing '" .. expectLog .. "'")
  assert(noFallback or logHas(sim, "WARN", "fell back to stub"), name .. ": stub fallback")
  assert(sim.ships.s1.state ~= "idle" or sim.ships.s1.cargo > 0 or sim.tick > 0, name)
  return sim, provider, net
end

failureCase("http 500", function() return 500, "boom", 0 end, "model_http_500")
failureCase("network error", function() return 0, "could not resolve host", 0 end, "could not resolve host")
failureCase("bad json body", function() return 200, "<html>", 0 end, "model_bad_response")
failureCase("empty reply", modelSays(""), "empty reply")
failureCase("prose reply", modelSays("I would mine titanium."), "no JSON object")
failureCase("unknown tool", modelSays('{"tool":"dig","args":{}}'), "unknown or unequipped")
failureCase("bad args", modelSays('{"tool":"mine","args":{"vein":7}}'), "must be a string")
-- Schema-valid but refused by the sim: logged by apply(), no stub; the agent re-decides after the cooldown.
failureCase("valid call the sim refuses", modelSays('{"tool":"mine","args":{"vein":"K99"}}'), "rejected mine (unknown vein)", nil, nil, nil, true)
-- A reply that never comes: the turn times out after timeoutSeconds, then the stub plays.
do
  local sim, provider, net = failureCase("timeout", function() return "never" end, "timeout", 0, { timeoutSeconds = 5 }, 8)
  assert(next(provider.axis.turns) == nil, "timed-out turn forgotten")
  assert(next(net.cancelled) ~= nil, "in-flight request cancelled")
end
-- A slow reply that lands after the deadline is dropped, not applied.
do
  local sim, provider = newSetup(function() return 200, Json.encode({ content = { { type = "text", text = '{"tool":"mine","args":{"vein":"K1"}}' } } }), 7 end,
    nil, { timeoutSeconds = 3 })
  run(sim, provider, 12)
  assert(logHas(sim, "ERROR", "timeout"), "slow answer is a timeout")
end

-- ---- Budget guard: the sim's AiQueue is the one authority, the provider is never asked ----
do
  local sim, provider, net = newSetup(modelSays('{"tool":"wait","args":{"seconds":10}}'), 0, { tokensPerHour = 500 })
  run(sim, provider, 30)
  eq(sim.agents.miner.state, "no_compute", "budget stops the agent")
  eq(sim.agents.miner.blockReason, AiConfig.budgetMessage)
  local sentAtStop = #net.sent
  run(sim, provider, 10)
  eq(#net.sent, sentAtStop, "no request leaves once the budget is reached")
end

-- ---- The AiQueue gates what is sent: at most maxConcurrent turns are in flight ----
do
  local sim, provider = newSetup(modelSays('{"tool":"wait","args":{"seconds":10}}'), 0, { maxConcurrent = 1 })
  local peak = 0
  for _ = 1, 100 do
    clock += 0.1
    provider:update(); sim:step()
    peak = math.max(peak, provider.inFlight)
  end
  assert(peak == 1, "one turn in flight, got " .. peak)
end

-- ---- Toggle: stub <-> axis from config / debug panel ----
do
  local sim, provider = newSetup(modelSays('{"tool":"wait","args":{"seconds":10}}'), 5)
  run(sim, provider, 0.5)
  assert(sim.agents.miner.pending and sim.agents.miner.pending.provider, "decision in flight with the provider")
  sim:setProvider(nil)
  assert(sim.agents.miner.pending == nil, "pending AI decision dropped on switch")
  assert(logHas(sim, "WARN", "provider switched"))
  sim:run(3000)
  assert(sim.resources.credits > 500, "stub plays on after the switch")
end

-- ---- Stub path is untouched (no provider = no network) ----
do
  local a, b = Sim.new(), Sim.new()
  a:setDecider(Ai.decide); b:setDecider(Ai.decide)
  a:run(2000); b:run(2000)
  assert(a.resources.credits == b.resources.credits and #a.logs == #b.logs, "stub deterministic")
  eq(AiConfig.provider, "stub", "config default is the stub")
end

print("AI tests OK")
