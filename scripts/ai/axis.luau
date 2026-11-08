-- Axis turn loop (GR5-15, doc "axis-boucle-memoire"): one decision = agent system prompt + record user turn + read memory
-- block + model call through Relais + record assistant turn (+ optional observe). Pure state machine over an injected
-- transport, so it runs headless:
--   transport.send({ method, url, headers = {name=value}, body, timeout }) -> id
--   transport.poll() -> { { id, ok, status, body, error }, ... }     (the engine's rtype.HttpResponse, mapped)
-- Keys are never here: headers name them as `{{env:NAME}}` and the engine fills them in when it sends.
local Json = require("@scripts/sim/json")

local Axis = {}
Axis.__index = Axis

local function urlEncode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

function Axis.new(cfg, transport)
  local self = setmetatable({}, Axis)
  self.cfg, self.axis, self.transport = cfg, cfg.axis, transport
  self.turns, self.reqs, self.nextTurn, self.finished = {}, {}, 1, {}
  self.promptCache = nil -- { text, fetchedAt }
  return self
end

local function platformHeaders(self)
  return { Authorization = "Bearer {{env:" .. self.axis.secrets.platform .. "}}", ["Content-Type"] = "application/json" }
end

local function send(self, turn, kind, req, now)
  req.timeout = req.timeout or math.max(1, turn.deadline - now)
  local id = self.transport.send(req)
  self.reqs[id] = { turn = turn, kind = kind }
  turn.open += 1
  return id
end

local TAIL_TIMEOUT = 10 -- memory write and observe outlive the turn's deadline

local function platformRequest(self, turn, kind, method, path, body, now)
  local tail = kind == "record_assistant" or kind == "observe"
  return send(self, turn, kind, { method = method, url = self.axis.platformUrl .. path, headers = platformHeaders(self),
    body = body and Json.encode(body) or nil, timeout = tail and TAIL_TIMEOUT or nil }, now)
end

local function recordTurn(self, turn, kind, role, content, now)
  return platformRequest(self, turn, kind, "POST", "/v1/conversations/" .. urlEncode(turn.conversation) .. "/turns",
    { role = role, content = content, user_id = turn.userId }, now)
end

local function finish(self, turn, result)
  if turn.done then return end
  turn.done = true
  result.turn = turn.id
  result.seconds = turn.elapsed
  self.finished[#self.finished + 1] = result
  -- Requests still open are abandoned: their late responses find no turn and are dropped.
  for id, r in pairs(self.reqs) do
    if r.turn == turn and r.kind ~= "record_assistant" and r.kind ~= "observe" then
      self.reqs[id] = nil
      if self.transport.cancel then self.transport.cancel(id) end
    end
  end
  self.turns[turn.id] = nil
end

local function fail(self, turn, err) finish(self, turn, { ok = false, error = err }) end

local function callModel(self, turn, block, now)
  local system = turn.system
  if turn.agentPrompt and turn.agentPrompt ~= "" then system = system .. "\n\n" .. turn.agentPrompt end
  if block and block ~= "" then system = system .. "\n\n" .. block end
  turn.phase = "model"
  send(self, turn, "model", {
    method = "POST", url = self.axis.relaisUrl,
    headers = { Authorization = "Bearer {{env:" .. self.axis.secrets.relais .. "}}", ["Content-Type"] = "application/json",
      ["anthropic-version"] = self.axis.anthropicVersion },
    body = Json.encode({ model = self.axis.model, max_tokens = turn.maxTokens, system = system,
      messages = { { role = "user", content = turn.user } } }),
  }, now)
end

local function onModel(self, turn, res, now)
  local data = Json.tryDecode(res.body or "")
  if type(data) ~= "table" or type(data.content) ~= "table" then return fail(self, turn, "model_bad_response") end
  local parts = {}
  for _, block in ipairs(data.content) do
    if type(block) == "table" and block.type == "text" and type(block.text) == "string" then parts[#parts + 1] = block.text end
  end
  local text = table.concat(parts)
  local usage = type(data.usage) == "table" and data.usage or {}
  local inTok, outTok = tonumber(usage.input_tokens), tonumber(usage.output_tokens)
  finish(self, turn, { ok = true, text = text, input_tokens = inTok, output_tokens = outTok })
  -- Memory for the next decision, and telemetry: both fire-and-forget, never part of the result.
  if text ~= "" then recordTurn(self, turn, "record_assistant", "assistant", text, now) end
  if self.axis.observe then
    local ms = math.floor(turn.elapsed * 1000)
    local run = string.format("%08x-0000-4000-8000-%012x", turn.id % 0xFFFFFFFF, math.floor(now * 1000) % 0xFFFFFFFFFFFF)
    platformRequest(self, turn, "observe", "POST", "/v1/observe", {
      schema_version = 2, run_id = run,
      agent = { slug = self.axis.agentSlug, user_id = turn.userId },
      trajectory = { steps = { { tool = "chat:answer", status = "ok" } },
        tokens = { input = inTok or 0, output = outTok or 0 }, duration_ms = ms, status = "completed" },
      deliverable = { kind = "text", content = text },
    }, now)
  end
end

local function advance(self, turn, kind, res, now)
  turn.open -= 1
  if kind == "record_assistant" or kind == "observe" then return end -- result already delivered
  if not res.ok then
    if res.status == 0 then return fail(self, turn, (res.error and res.error ~= "") and res.error or "network") end
    return fail(self, turn, kind .. "_http_" .. tostring(res.status))
  end
  if kind == "agent_config" then
    local data = Json.tryDecode(res.body or "")
    if type(data) ~= "table" or type(data.system_prompt) ~= "string" then return fail(self, turn, "agent_config_bad_response") end
    turn.agentPrompt = data.system_prompt
    self.promptCache = { text = data.system_prompt, fetchedAt = now }
    turn.prep -= 1
  elseif kind == "record_user" then
    turn.prep -= 1
  elseif kind == "session" then
    local data = Json.tryDecode(res.body or "")
    if type(data) ~= "table" then return fail(self, turn, "session_bad_response") end
    return callModel(self, turn, type(data.block) == "string" and data.block or "", now)
  elseif kind == "model" then
    return onModel(self, turn, res, now)
  end
  if turn.phase == "prep" and turn.prep == 0 then
    turn.phase = "session"
    platformRequest(self, turn, "session", "GET", "/v1/conversations/" .. urlEncode(turn.conversation) .. "/session", nil, now)
  end
end

-- turn: { conversation, userId, system, user, note, maxTokens, agentId }. Returns the turn id.
function Axis:start(turn, now)
  turn.id = self.nextTurn
  self.nextTurn += 1
  turn.deadline = now + self.cfg.timeoutSeconds
  turn.startedAt = now
  turn.open, turn.prep, turn.phase = 0, 1, "prep"
  self.turns[turn.id] = turn
  local ttl = self.axis.systemPromptTtlSeconds
  local cache = self.promptCache
  if cache and ttl > 0 and now - cache.fetchedAt < ttl then
    turn.agentPrompt = cache.text
  else
    turn.prep += 1
    local path = ("/v1/agentic-config/%s?resolve=true&worker_class=%s&user_id=%s&task=%s"):format(urlEncode(self.axis.agentSlug),
      urlEncode(self.axis.workerClass), urlEncode(turn.userId), urlEncode(turn.note:sub(1, 200)))
    platformRequest(self, turn, "agent_config", "GET", path, nil, now)
  end
  recordTurn(self, turn, "record_user", "user", turn.note:sub(1, self.axis.memoryNoteMaxChars), now)
  return turn.id
end

-- Pump: feed in the responses, expire turns past their deadline. Returns the finished results (ok or not).
function Axis:update(now)
  self.finished = {}
  for _, res in ipairs(self.transport.poll()) do
    local r = self.reqs[res.id]
    if r then
      self.reqs[res.id] = nil
      local turn = r.turn
      turn.elapsed = now - turn.startedAt
      if not turn.done or r.kind == "record_assistant" or r.kind == "observe" then advance(self, turn, r.kind, res, now) end
    end
  end
  for _, turn in pairs(self.turns) do
    turn.elapsed = now - turn.startedAt
    if now >= turn.deadline then fail(self, turn, "timeout") end
  end
  return self.finished
end

function Axis:pending() return next(self.turns) ~= nil end

return Axis
