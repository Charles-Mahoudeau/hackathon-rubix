-- Decision log (spec §12.1): one record per decision, AI or skill step, kept per agent (last `recordsMax`, in memory and
-- in the save). A record opens when a request is sent and is filled as the decision resolves: tokens and Compute on the
-- answer, the call and its validation when the sim applies it, the result when the action ends, revenue when it sells.
-- Pure Luau, headless, no UI calls: the UI reads `sim.records` and listens to `decision_record` events.
local Settings = require("./context_settings")
local Prompt = require("./prompt")

local Log = {}

local function now(sim) return sim.realClock and sim.realClock() or sim.tick * sim.b.tickSeconds end

-- Short hash of directive + equipped tools + context settings (spec §12.3): a new version starts when one of them changes.
function Log.promptVersion(sim, agentId)
  local agent = sim.agents[agentId]
  local keys = {}
  for k in pairs(agent.contextSettings) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = { agent.directive or "", table.concat(sim:equippedTools(agentId), ",") }
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(agent.contextSettings[k]) end
  local h = 2166136261 -- FNV-1a, 32 bit
  for _, byte in ipairs({ string.byte(table.concat(parts, "\n"), 1, -1) }) do
    h = bit32.band(bit32.bxor(h, byte) * 16777619, 0xFFFFFFFF)
  end
  return ("%08x"):format(h):sub(1, 6)
end

function Log.init(sim)
  sim.records, sim.recordSeq, sim.recordRev, sim.earnings = {}, 0, 0, {}
end

local function list(sim, agentId)
  local l = sim.records[agentId]
  if not l then l = {}; sim.records[agentId] = l end
  return l
end

local function emit(sim, rec, update)
  sim.recordRev += 1
  sim:emit("decision_record", { agent = rec.agent_id, id = rec.id, update = update })
end

local function add(sim, rec)
  sim.recordSeq += 1
  rec.id = sim.recordSeq
  local l = list(sim, rec.agent_id)
  l[#l + 1] = rec
  if #l > sim.aiConfig.recordsMax then table.remove(l, 1) end
  emit(sim, rec, false)
  return rec
end

-- The record with this id, or nil (already trimmed away). Newest records are the ones asked for, so scan from the end.
function Log.find(sim, id)
  if not id then return nil end
  for _, l in pairs(sim.records) do
    for i = #l, 1, -1 do
      if l[i].id == id then return l[i] end
      if l[i].id < id then break end
    end
  end
  return nil
end

local function zeroTokens() return { rules = 0, directive = 0, order = 0, context = 0, tools = 0, output = 0, total = 0 } end

-- Context weight in tokens for every format (spec §9.2.5: both sizes are recorded per decision). `prompt` is the one
-- being sent, so its own format is not built again.
local function contextSizes(sim, agentId, prompt)
  local sizes = { [prompt.format] = prompt.sections.context }
  local settings = sim.agents[agentId].contextSettings
  for _, f in ipairs(Settings.options.format) do
    if sizes[f] == nil then
      sizes[f] = Prompt.build(sim, agentId, { settings = assert(Settings.with(settings, "format", f)) }).sections.context
    end
  end
  return sizes
end

-- An AI decision goes out: `prompt` is the Prompt.build result billed, `cost` the Compute charged on the estimate.
function Log.open(sim, agentId, prompt, cost)
  local t = zeroTokens()
  for k, v in pairs(prompt.sections) do t[k] = v end
  t.total = prompt.input
  return add(sim, { agent_id = agentId, prompt_version = Log.promptVersion(sim, agentId), t_game = sim.tick * sim.b.tickSeconds,
    t_real_sent = now(sim), tokens = t, compute_spent = cost, validation = "pending", source = "ai", credits_delta = 0,
    context_sizes = contextSizes(sim, agentId, prompt) })
end

-- A skill step (spec §13): it costs no Compute and carries no tokens.
function Log.skillStep(sim, agentId, skillName)
  local t = now(sim)
  return add(sim, { agent_id = agentId, prompt_version = Log.promptVersion(sim, agentId), t_game = sim.tick * sim.b.tickSeconds,
    t_real_sent = t, t_real_received = t, tokens = zeroTokens(), compute_spent = 0, validation = "pending",
    source = "skill:" .. skillName, credits_delta = 0 })
end

-- The answer arrived: real (or estimated) output tokens, the final Compute bill and the model's reasoning.
-- `total` is the real token count when the provider reported one.
function Log.answered(sim, rec, info)
  if not rec then return end
  rec.t_real_received = now(sim)
  rec.tokens.output = info.output or rec.tokens.output
  rec.tokens.total = info.total or (rec.tokens.total + rec.tokens.output)
  if info.cost then rec.compute_spent = info.cost end
  if info.reasoning and info.reasoning ~= "" then rec.reasoning = info.reasoning end
  if info.realTokens then rec.real_tokens = true end
  emit(sim, rec, true)
end

-- The decision ended without an action (provider failure, stale, dropped): `why` is the reason shown in amber.
function Log.failed(sim, rec, why, call)
  if not rec then return end
  if rec.validation == "pending" then rec.validation = why end
  if call ~= nil and rec.tool_call == nil then rec.tool_call = { tool = call.name, args = call.args or {} } end
  rec.t_real_received = rec.t_real_received or now(sim)
  emit(sim, rec, true)
end

-- The sim accepted the call (apply). A fallback keeps the provider's failure as its validation.
function Log.accepted(sim, rec, call, fallback)
  if not rec then return end
  rec.tool_call = { tool = call.name, args = call.args or {} }
  if rec.validation == "pending" then rec.validation = "ok" end
  if fallback then rec.fallback = true end
  rec.t_real_received = rec.t_real_received or now(sim)
  emit(sim, rec, true)
end

-- The action ended (a feed line got its result).
function Log.finished(sim, recordId, text, ok)
  local rec = Log.find(sim, recordId)
  if not rec or rec.result then return end
  rec.result = { ok = ok ~= false, result = text, error = ok == false and text or nil }
  emit(sim, rec, true)
end

-- Revenue directly produced by an action (sales). Also feeds the credits/h readout at the time it was earned.
function Log.earned(sim, agentId, recordId, amount)
  if amount == 0 then return end
  local rec = Log.find(sim, recordId)
  if rec then
    rec.credits_delta += amount
    emit(sim, rec, true)
  end
  local e = sim.earnings[agentId]
  if not e then e = {}; sim.earnings[agentId] = e end
  e[#e + 1] = { t = sim.tick * sim.b.tickSeconds, amount = amount }
  local cutoff = sim.tick * sim.b.tickSeconds - sim.aiConfig.compute.rateWindowSeconds
  while #e > 0 and e[1].t < cutoff do table.remove(e, 1) end
end

-- A record is an error when the call was refused, the turn failed, or the action it started failed.
function Log.isError(rec)
  if rec.validation ~= "ok" and rec.validation ~= "pending" then return true end
  return rec.result ~= nil and rec.result.ok == false
end

-- The reason to show with an error record.
function Log.errorReason(rec)
  if rec.validation ~= "ok" and rec.validation ~= "pending" then return rec.validation end
  if rec.result and rec.result.ok == false then return rec.result.error or rec.result.result end
  return nil
end

-- Per agent over the last rateWindowSeconds (10 game minutes), the same span as the Compute/h readout:
-- credits/h, Compute/h and net credits/h = credits - Compute x price.
function Log.stats(sim, agentId)
  local cfg = sim.aiConfig
  local span = sim.compute:span()
  local tNow = sim.tick * sim.b.tickSeconds
  local credits = 0
  for _, e in ipairs(sim.earnings[agentId] or {}) do
    if e.t >= tNow - span then credits += e.amount end
  end
  local creditsPerHour = credits / span * 3600
  local computePerHour = sim.compute:agentRatePerHour(agentId)
  return { credits_per_hour = creditsPerHour, compute_per_hour = computePerHour,
    net_per_hour = creditsPerHour - computePerHour * cfg.compute.priceCredits }
end

return Log
