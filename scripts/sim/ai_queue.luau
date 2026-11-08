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

local function reservedTotal(self)
  local sum = 0
  for _, e in pairs(self.running) do sum = sum + e.reserved end
  return sum
end

-- A request fits when the window is not spent and, if others are in flight, used + reserved + its own reservation stays
-- under the cap. The first request is never held back by its own estimate, so an oversize one cannot starve forever.
local function fits(self, reserve)
  if self:budgetReached() then return false end
  if self.nRunning == 0 then return true end
  return self.used + reservedTotal(self) + reserve <= self.cfg.tokensPerHour
end

-- req = { agentId, monitor = bool, estimate = tokens? }. Returns id, "running" | "queued", or nil, "budget".
function AiQueue:submit(req)
  local reserve = req.estimate or 0
  if self:budgetReached() then return nil, "budget" end
  self.nextId = self.nextId + 1
  local id = self.nextId
  local entry = { id = id, agentId = req.agentId, monitor = req.monitor == true, reserved = reserve }
  if self.nRunning < self.cfg.maxConcurrent and fits(self, reserve) then
    self.running[id], self.nRunning = entry, self.nRunning + 1
    return id, "running"
  end
  self.waiting[#self.waiting + 1] = entry
  return id, "queued"
end

-- Replaces a running request's reservation with the estimate of the prompt actually assembled. Returns false when the
-- others in flight leave no room for it (the caller must not send).
function AiQueue:reserve(id, tokens)
  local e = self.running[id]
  if not e then return false end
  local others = reservedTotal(self) - e.reserved
  if self.nRunning > 1 and self.used + others + tokens > self.cfg.tokensPerHour then return false end
  e.reserved = tokens
  return true
end

-- Frees the slot, records the tokens, and starts waiting requests whose budget still fits. Returns the ids that just
-- started, and the ids refused because the hourly window is spent (they leave the queue; the caller handles them).
-- A request that merely does not fit next to the ones in flight stays queued: their completion calls this again.
function AiQueue:complete(id, tokens)
  if self.running[id] then
    self.running[id], self.nRunning = nil, self.nRunning - 1
    self.usage[#self.usage + 1] = { t = self.now(), tokens = tokens or 0 }
    self.used = self.used + (tokens or 0)
  end
  local started, refused = {}, {}
  if self:budgetReached() then
    for _, e in ipairs(self.waiting) do refused[#refused + 1] = e.id end
    self.waiting = {}
    return started, refused
  end
  while self.nRunning < self.cfg.maxConcurrent and #self.waiting > 0 do
    local pick = 1
    for i, e in ipairs(self.waiting) do
      if e.monitor and not self.waiting[pick].monitor then pick = i; break end
    end
    if not fits(self, self.waiting[pick].reserved) then break end
    local e = table.remove(self.waiting, pick)
    self.running[e.id], self.nRunning = e, self.nRunning + 1
    started[#started + 1] = e.id
  end
  return started, refused
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
