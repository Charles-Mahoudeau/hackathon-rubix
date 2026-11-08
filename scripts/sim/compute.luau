-- Compute ledger (spec §6.4, §10.4): token estimate, decision cost, charge-on-send / settle-on-response,
-- buying packs and per-agent Compute/h. The hourly AI token budget is owned by the AiQueue (sim/ai_queue.luau); this ledger
-- only asks it. Pure Luau, headless, no UI calls.
-- `resources` is the sim's own table, so the ledger and the sim never disagree on the balance.
local Compute = {}
Compute.__index = Compute

local function stepsPerUnit(cfg) return math.floor(1 / cfg.compute.roundTo + 0.5) end

-- Round a Compute amount to the billing step so balances never drift (10 - 1.1 - 0.7 ...).
local function snap(cfg, x)
  local k = stepsPerUnit(cfg)
  return math.floor(x * k + 0.5) / k
end

function Compute.estimateTokens(cfg, text)
  if text == nil or text == "" then return 0 end
  local n = utf8.len(text) or #text
  return math.ceil(n / cfg.charsPerToken)
end

-- Compute billed for `tokens`: tokens / 1000, rounded UP to the billing step.
function Compute.cost(cfg, tokens)
  local k = stepsPerUnit(cfg)
  local steps = tokens / cfg.compute.tokensPerCompute * k
  return math.ceil(steps - 1e-9) / k
end

function Compute.creditsFor(cfg, compute) return compute * cfg.compute.priceCredits end

function Compute.packPrice(cfg, packs) return packs * cfg.compute.packSize * cfg.compute.priceCredits end

-- `clock` = game seconds (rates); `budget` = the AiQueue that owns the hourly token budget.
function Compute.new(resources, cfg, clock, budget)
  local self = setmetatable({
    resources = resources, cfg = cfg, clock = clock, budget = budget,
    started = clock(), nextId = 1,
    charges = {}, -- id -> { agent, t, tokens, cost }
    spend = {}, -- list of { t, agent, cost, id } (Compute spend, for the per-agent rate)
    lifetime = {}, -- agent -> total Compute spent
    lifetimeTotal = 0,
  }, Compute)
  return self
end

local function prune(list, cutoff)
  while #list > 0 and list[1].t < cutoff do table.remove(list, 1) end
end

function Compute:_prune() prune(self.spend, self.clock() - self.cfg.compute.rateWindowSeconds) end

-- Can a decision of `inputTokens` (plus the assumed output) be sent now? -> ok, reason ("budget" | "no_compute"), cost
function Compute:canSend(inputTokens)
  local cost = Compute.cost(self.cfg, inputTokens + self.cfg.estimatedOutputTokens)
  if self.budget:budgetReached() then return false, "budget", cost end
  if self.resources.compute + 1e-9 < cost then return false, "no_compute", cost end
  return true, nil, cost
end

local function bump(list, e) list[#list + 1] = e end

-- Bill a request on send, using the estimate. Returns chargeId, cost. The caller must have checked canSend.
function Compute:charge(agentId, inputTokens, outputTokens)
  local tokens = inputTokens + (outputTokens or self.cfg.estimatedOutputTokens)
  local cost = Compute.cost(self.cfg, tokens)
  local id, now = self.nextId, self.clock()
  self.nextId = id + 1
  self.resources.compute = math.max(0, snap(self.cfg, self.resources.compute - cost))
  self.charges[id] = { agent = agentId, t = now, tokens = tokens, cost = cost }
  bump(self.spend, { t = now, agent = agentId, cost = cost, id = id })
  self.lifetime[agentId] = (self.lifetime[agentId] or 0) + cost
  self.lifetimeTotal = self.lifetimeTotal + cost
  return id, cost
end

-- Correct a charge to the real token counts. A failed or invalid response is settled with output 0 but still billed.
-- Returns the final cost, or nil if the charge is unknown (already settled).
function Compute:settle(chargeId, inputTokens, outputTokens)
  local c = self.charges[chargeId]
  if not c then return nil end
  self.charges[chargeId] = nil
  local tokens = inputTokens + outputTokens
  local cost = Compute.cost(self.cfg, tokens)
  local diff = cost - c.cost
  self.resources.compute = math.max(0, snap(self.cfg, self.resources.compute - diff))
  for _, e in ipairs(self.spend) do
    if e.id == chargeId then e.cost = cost; break end
  end
  self.lifetime[c.agent] = self.lifetime[c.agent] + diff
  self.lifetimeTotal = self.lifetimeTotal + diff
  return cost
end

-- Buy `packs` packs of Compute with credits. No cap on the Compute balance. -> ok, err
function Compute:buy(packs)
  if type(packs) ~= "number" or packs < 1 or packs ~= math.floor(packs) then return false, "bad_packs" end
  local price = Compute.packPrice(self.cfg, packs)
  if self.resources.credits < price then return false, "not_enough_credits" end
  self.resources.credits = self.resources.credits - price
  self.resources.compute = snap(self.cfg, self.resources.compute + packs * self.cfg.compute.packSize)
  return true
end

-- Free Compute from outside the shop (anti-softlock bailout, debug boost). Not counted as spend.
function Compute:grant(amount) self.resources.compute = snap(self.cfg, self.resources.compute + amount) end

-- Compute per hour spent by one agent, averaged over the last rateWindowSeconds of game time.
function Compute:span()
  local c = self.cfg.compute
  return math.min(c.rateWindowSeconds, math.max(c.rateMinElapsedSeconds, self.clock() - self.started))
end

function Compute:agentRatePerHour(agentId)
  self:_prune()
  local now, span = self.clock(), self:span()
  local total = 0
  for _, e in ipairs(self.spend) do
    if e.t >= now - span and (agentId == nil or e.agent == agentId) then total = total + e.cost end
  end
  return total / span * 3600
end

function Compute:teamRatePerHour() return self:agentRatePerHour(nil) end

return Compute
