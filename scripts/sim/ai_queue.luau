-- Concurrency cap + hourly token budget for AI requests (spec §10.4). Pure and clock-injected: the caller supplies
-- `now()` in seconds (real time with a real provider), so it runs headless and deterministically.
local AiQueue = {}
AiQueue.__index = AiQueue

function AiQueue.new(cfg, now)
  return setmetatable({ cfg = cfg, now = now, nextId = 0, running = {}, nRunning = 0, waiting = {}, usage = {}, used = 0 }, AiQueue)
end

local function prune(self)
  local cutoff = self.now() - self.cfg.windowSeconds
  local u = self.usage
  while #u > 0 and u[1].t <= cutoff do
    self.used = self.used - u[1].tokens
    table.remove(u, 1)
  end
end

function AiQueue:tokensUsed() prune(self); return self.used end

function AiQueue:budgetReached() return self:tokensUsed() >= self.cfg.tokensPerHour end

-- req = { agentId, monitor = bool }. Returns id, "running" | "queued", or nil, "budget".
function AiQueue:submit(req)
  if self:budgetReached() then return nil, "budget" end
  self.nextId = self.nextId + 1
  local id = self.nextId
  local entry = { id = id, agentId = req.agentId, monitor = req.monitor == true }
  if self.nRunning < self.cfg.maxConcurrent then
    self.running[id], self.nRunning = entry, self.nRunning + 1
    return id, "running"
  end
  self.waiting[#self.waiting + 1] = entry
  return id, "queued"
end

-- Frees the slot, records the tokens, and starts waiting requests. Returns the ids that just started.
function AiQueue:complete(id, tokens)
  if self.running[id] then
    self.running[id], self.nRunning = nil, self.nRunning - 1
    self.usage[#self.usage + 1] = { t = self.now(), tokens = tokens or 0 }
    self.used = self.used + (tokens or 0)
  end
  local started = {}
  while self.nRunning < self.cfg.maxConcurrent and #self.waiting > 0 do
    local pick = 1
    for i, e in ipairs(self.waiting) do
      if e.monitor and not self.waiting[pick].monitor then pick = i; break end
    end
    local e = table.remove(self.waiting, pick)
    self.running[e.id], self.nRunning = e, self.nRunning + 1
    started[#started + 1] = e.id
  end
  return started
end

-- Drops a request that never ran (e.g. agent paused while queued).
function AiQueue:cancel(id)
  for i, e in ipairs(self.waiting) do
    if e.id == id then table.remove(self.waiting, i); return true end
  end
  return false
end

function AiQueue:queued() return #self.waiting end
function AiQueue:inFlight() return self.nRunning end

return AiQueue
