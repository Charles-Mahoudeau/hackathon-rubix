-- Async AI provider (spec §10.1) backed by Axis. The sim submits request() once the AiQueue (the one budget and
-- concurrency authority, spec §10.4) lets a decision start, the host pumps update() every frame with real time, and the
-- sim drains validated responses at the start of each tick. Per-turn timeout (§8.4), validation (§10.3) and a record per
-- decision (§12.1) live here.
local Axis = require("@scripts/ai/axis")
local Compute = require("@scripts/sim/compute")
local Validator = require("@scripts/ai/validator")

local Provider = {}
Provider.__index = Provider

-- deps: { transport, now = function() -> real seconds, run = string (conversation suffix) }
function Provider.new(cfg, deps)
  local self = setmetatable({}, Provider)
  self.cfg, self.now, self.run = cfg, deps.now, deps.run or "main"
  self.budget = nil -- the sim's AiQueue, set by Sim:setProvider: the one budget authority
  self.axis = Axis.new(cfg, deps.transport, { reserve = function(turn, tokens)
    local req = self.active[turn.id]
    if req then req.estimated = tokens end
    if not (self.budget and req and req.queue_id) then return true end
    return self.budget:reserve(req.queue_id, tokens)
  end })
  self.nextId = 1
  self.active = {} -- active[turnId] = request
  self.out, self.records = {}, {}
  self.inFlight = 0
  return self
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

-- req: { agent_id, prompt = Prompt.forProvider(...) result, max_output_tokens?, queue_id? (AiQueue id) } -> request id. Starts the turn at once.
function Provider:request(req)
  local now = self.now()
  local p = req.prompt
  req.id = self.nextId
  self.nextId += 1
  req.max_output_tokens = req.max_output_tokens or self.cfg.maxOutputTokens
  req.estimated = Compute.estimateTokens(self.cfg, p.system) + Compute.estimateTokens(self.cfg, p.user) + req.max_output_tokens
  local tid = self.axis:start({
    agentId = req.agent_id, conversation = ("%s-%s-%s"):format(self.cfg.axis.idPrefix, req.agent_id, self.run),
    userId = self.cfg.axis.idPrefix .. ":" .. self.cfg.axis.userName,
    system = p.system, user = p.user, note = p.note, maxTokens = req.max_output_tokens,
  }, now)
  self.active[tid] = req
  self.inFlight += 1
  return req.id
end

local function finishTurn(self, result)
  local req = self.active[result.turn]
  self.active[result.turn] = nil
  self.inFlight -= 1
  local base = { seconds = result.seconds, input_tokens = result.input_tokens, output_tokens = result.output_tokens, raw_text = result.text }
  if not result.ok then
    base.ok, base.kind, base.error = false, "provider_error", result.error
    return respond(self, req, base)
  end
  local ok, call, err = Validator.parse(result.text, req.prompt.tools, self.cfg)
  if ok then base.ok, base.tool_call = true, call
  else base.ok, base.kind, base.error = false, "invalid", err end
  respond(self, req, base)
end

-- Call every frame: advances the Axis turns (each one carries its own deadline).
function Provider:update()
  for _, result in ipairs(self.axis:update(self.now())) do finishTurn(self, result) end
end

-- Hand the responses over (oldest first) and forget them.
function Provider:drain()
  local out = self.out
  self.out = {}
  return out
end

return Provider
