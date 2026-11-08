-- Async AI provider (spec §10.1) backed by Axis. The sim submits request(), the host pumps update() every frame with real
-- time, and the sim drains validated responses at the start of each tick. Concurrency cap with Monitor first (§10.4),
-- hourly token budget (§10.4), per-turn timeout (§8.4), validation (§10.3) and a record per decision (§12.1).
local Axis = require("@scripts/ai/axis")
local Tokens = require("@scripts/ai/tokens")
local Validator = require("@scripts/ai/validator")

local Provider = {}
Provider.__index = Provider

local HOUR = 3600

-- deps: { transport, now = function() -> real seconds, run = string (conversation suffix) }
function Provider.new(cfg, deps)
  local self = setmetatable({}, Provider)
  self.cfg, self.now, self.run = cfg, deps.now, deps.run or "main"
  self.axis = Axis.new(cfg, deps.transport)
  self.nextId, self.seq = 1, 0
  self.queue, self.active = {}, {} -- active[turnId] = request
  self.out, self.records, self.usage = {}, {}, {}
  self.inFlight = 0
  return self
end

local function budgetUsed(self, now)
  local used, keep = 0, {}
  for _, u in ipairs(self.usage) do
    if now - u.t < HOUR then keep[#keep + 1] = u; used += u.tokens end
  end
  self.usage = keep
  return used
end

local function record(self, rec)
  local r = self.records
  r[#r + 1] = rec
  if #r > self.cfg.recordsMax then table.remove(r, 1) end
end

local function respond(self, req, fields)
  local res = { id = req.id, agent_id = req.agent_id, estimated_tokens = req.estimated }
  for k, v in pairs(fields) do res[k] = v end
  self.out[#self.out + 1] = res
  record(self, { id = req.id, agent_id = req.agent_id, estimated_tokens = req.estimated, input_tokens = res.input_tokens,
    output_tokens = res.output_tokens, kind = res.kind, validation = res.ok and "ok" or res.error, seconds = res.seconds })
end

-- req: { agent_id, prompt = Prompt.build(...) result, max_output_tokens?, priority? } -> request id
function Provider:request(req)
  local now = self.now()
  req.id = self.nextId
  self.nextId += 1
  self.seq += 1
  req.seq, req.queuedAt = self.seq, now
  req.max_output_tokens = req.max_output_tokens or self.cfg.maxOutputTokens
  req.estimated = Tokens.estimate(req.prompt.system) + Tokens.estimate(req.prompt.user) + req.max_output_tokens
  req.priority = req.priority or (req.agent_id == "monitor" and 1 or 0)
  if budgetUsed(self, now) + req.estimated > self.cfg.tokensPerHour then
    respond(self, req, { ok = false, kind = "budget", error = "Server AI budget reached" })
  else
    self.queue[#self.queue + 1] = req
  end
  return req.id
end

local function start(self, req, now)
  local p = req.prompt
  local tid = self.axis:start({
    agentId = req.agent_id, conversation = ("%s-%s-%s"):format(self.cfg.axis.idPrefix, req.agent_id, self.run),
    userId = self.cfg.axis.idPrefix .. ":" .. self.cfg.axis.userName,
    system = p.system, user = p.user, note = p.note, maxTokens = req.max_output_tokens,
  }, now)
  req.startedAt = now
  self.active[tid] = req
  self.inFlight += 1
end

local function takeNext(self)
  local best, bi
  for i, q in ipairs(self.queue) do
    if not best or q.priority > best.priority or (q.priority == best.priority and q.seq < best.seq) then best, bi = q, i end
  end
  if bi then table.remove(self.queue, bi) end
  return best
end

local function finishTurn(self, result, now)
  local req = self.active[result.turn]
  self.active[result.turn] = nil
  self.inFlight -= 1
  local base = { seconds = result.seconds, input_tokens = result.input_tokens, output_tokens = result.output_tokens, raw_text = result.text }
  if not result.ok then
    base.ok, base.kind, base.error = false, "provider_error", result.error
    return respond(self, req, base)
  end
  local used = (result.input_tokens or 0) + (result.output_tokens or 0)
  self.usage[#self.usage + 1] = { t = now, tokens = used > 0 and used or req.estimated }
  local ok, call, err = Validator.parse(result.text, req.prompt.tools, self.cfg)
  if ok then base.ok, base.tool_call = true, call
  else base.ok, base.kind, base.error = false, "invalid", err end
  respond(self, req, base)
end

-- Call every frame. Starts queued requests, advances the Axis turns, expires queued requests past the timeout.
function Provider:update()
  local now = self.now()
  while self.inFlight < self.cfg.maxConcurrent and #self.queue > 0 do start(self, takeNext(self), now) end
  for _, result in ipairs(self.axis:update(now)) do finishTurn(self, result, now) end
  for i = #self.queue, 1, -1 do
    local q = self.queue[i]
    if now - q.queuedAt >= self.cfg.timeoutSeconds then
      table.remove(self.queue, i)
      respond(self, q, { ok = false, kind = "provider_error", error = "timeout" })
    end
  end
  -- A turn that just ended frees a slot: refill it in the same frame.
  while self.inFlight < self.cfg.maxConcurrent and #self.queue > 0 do start(self, takeNext(self), now) end
end

-- Hand the responses over (oldest first) and forget them.
function Provider:drain()
  local out = self.out
  self.out = {}
  return out
end

function Provider:tokensThisHour() return budgetUsed(self, self.now()) end

return Provider
