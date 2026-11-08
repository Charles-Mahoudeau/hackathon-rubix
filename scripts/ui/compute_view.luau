-- Compute view-models: plain tables the top bar, Agents list and Context panel draw (spec §6.4, §9.3, §9.4, §10.4).
-- Pure reads of the sim, no engine calls, so the numbers are testable headless and the screens only lay them out.
-- Every cost is shown in Compute with its credit equivalent (x priceCredits).
local Compute = require("@scripts/sim/compute")
local Prompt = require("@scripts/sim/prompt")
local Settings = require("@scripts/sim/context_settings")
local Screens = require("@scripts/config/screens")

local View = {}

local function round1(x) return math.floor(x * 10 + 0.5) / 10 end

-- "1.2 Compute (48 cr)"
function View.costText(sim, compute)
  return ("%.1f Compute (%d cr)"):format(compute, math.floor(Compute.creditsFor(sim.compute.cfg, compute) + 0.5))
end

-- Compute is "low" when it cannot pay for a few more decisions of the typical size, "empty" when it cannot pay for one.
function View.topBar(sim)
  local c = sim.compute
  local Ai = c.cfg
  local used, cap = sim.aiQueue:tokensUsed(), Ai.tokensPerHour
  local reached = sim.aiQueue:budgetReached()
  local amount = sim.resources.compute
  local level, need = "ok", 0
  for id in pairs(sim.agents) do
    need = math.max(need, Compute.cost(Ai, Prompt.build(sim, id).input + Ai.estimatedOutputTokens))
  end
  if amount + 1e-9 < need then level = "empty" elseif amount < need * 3 then level = "low" end
  return {
    compute = round1(amount),
    computeCredits = Compute.creditsFor(Ai, amount),
    level = level,
    teamPerHour = round1(c:teamRatePerHour()),
    budget = { used = used, cap = cap, left = math.max(0, cap - used), fraction = math.min(1, used / cap),
      reached = reached, message = reached and Ai.budgetMessage or nil },
  }
end

-- One row per agent, busiest thinker first: "who thinks too much".
function View.agentRows(sim)
  local Ai = sim.compute.cfg
  local rows, total = {}, sim.compute:teamRatePerHour()
  for id, agent in pairs(sim.agents) do
    local rate = sim.compute:agentRatePerHour(id)
    rows[#rows + 1] = { id = id, state = agent.state, blockReason = agent.blockReason,
      computePerHour = round1(rate), creditsPerHour = round1(Compute.creditsFor(Ai, rate)),
      share = total > 0 and rate / total or 0, spent = round1(sim.compute.lifetime[id] or 0) }
  end
  table.sort(rows, function(a, b)
    if a.computePerHour ~= b.computePerHour then return a.computePerHour > b.computePerHour end
    return a.id < b.id
  end)
  if rows[1] and rows[1].computePerHour > 0 then rows[1].thinksMost = true end
  return rows
end

-- Buy buttons: packs of 5 (200 cr). Always offered; `affordable` greys the button, it never hides it.
function View.buyOptions(sim, maxPacks)
  local Ai = sim.compute.cfg
  local out = {}
  for packs = 1, maxPacks or 3 do
    local price = Compute.packPrice(Ai, packs)
    out[#out + 1] = { packs = packs, compute = packs * Ai.compute.packSize, price = price,
      affordable = sim.resources.credits >= price, action = "compute.buy." .. packs,
      text = ("Buy %d Compute (%d cr)"):format(packs * Ai.compute.packSize, price) }
  end
  return out
end

-- The Context panel (§9.3/§9.4) for one agent. `weight` of an option = tokens it adds to the context section
-- compared with the cheapest option of that setting, measured by building the real prompt with that option.
function View.contextPanel(sim, agentId)
  local Ai = sim.compute.cfg
  local agent = sim.agents[agentId]
  local current = Prompt.build(sim, agentId)
  local rows = {}
  for _, key in ipairs(Settings.orderFor(agent.type)) do
    local available, unlockTier = Settings.available(sim, key)
    local base = Prompt.build(sim, agentId, { settings = assert(Settings.with(agent.contextSettings, key, Settings.minimal[key])) })
    local options = {}
    for _, value in ipairs(Settings.options[key]) do
      local p = Prompt.build(sim, agentId, { settings = assert(Settings.with(agent.contextSettings, key, value)) })
      options[#options + 1] = { value = value, weight = p.sections.context - base.sections.context, total = p.input }
    end
    local weight = current.sections.context - base.sections.context
    local row = { key = key, label = Screens.context.labels[key], value = agent.contextSettings[key], weight = weight,
      options = options, available = available, unlockTier = unlockTier,
      kind = key == "recent_results" and "stepper" or "choice" }
    if row.kind == "stepper" then
      row.stepActions = { down = ("context.%s.step.-1"):format(key), up = ("context.%s.step.1"):format(key) }
    end
    for i, o in ipairs(options) do
      o.text = Screens.context.values[tostring(o.value)] or tostring(o.value)
      o.action = ("context.%s.%d"):format(key, i)
      o.selected = o.value == row.value
    end
    rows[#rows + 1] = row
  end
  local formats, formatList = {}, {}
  for _, f in ipairs(Settings.options.format) do
    local p = Prompt.build(sim, agentId, { settings = assert(Settings.with(agent.contextSettings, "format", f)) })
    formats[f] = { context = p.sections.context, total = p.input }
    formatList[#formatList + 1] = { format = f, context = p.sections.context, total = p.input, active = f == current.format }
  end
  local estimateTokens = current.input + Ai.estimatedOutputTokens
  local compute = Compute.cost(Ai, estimateTokens)
  return {
    agentId = agentId,
    rows = rows,
    formats = formats,
    formatList = formatList,
    sections = current.sections,
    contextText = current.contextText,
    format = current.format,
    inputTokens = current.input,
    outputTokens = Ai.estimatedOutputTokens,
    totalTokens = estimateTokens,
    cost = { compute = compute, credits = Compute.creditsFor(Ai, compute), text = View.costText(sim, compute) },
    budget = View.topBar(sim).budget,
  }
end

-- A click from the Compute / Context UI -> handled, ok, err. Pure sim calls, so the whole path is testable headless.
--   "compute.buy.<packs>"        buy packs of Compute
--   "context.<key>.<option #>"   pick that option of a setting
--   "context.<key>.step.<+-n>"   move a number setting (recent results) by n
function View.act(sim, agentId, action)
  if type(action) ~= "string" then return false end
  local packs = action:match("^compute%.buy%.(%d+)$")
  if packs then return true, sim:buyCompute(tonumber(packs)) end
  local key, step = action:match("^context%.([%w_]+)%.step%.(%-?%d+)$")
  if key then
    local agent = sim.agents[agentId]
    local opts = Settings.options[key]
    if not agent or not opts or type(agent.contextSettings[key]) ~= "number" then return true, false, "bad_setting" end
    local value = math.max(opts[1], math.min(opts[#opts], agent.contextSettings[key] + tonumber(step)))
    return true, sim:setContextSetting(agentId, key, value)
  end
  local index
  key, index = action:match("^context%.([%w_]+)%.(%d+)$")
  if key then
    local opts = Settings.options[key]
    if not opts or opts[tonumber(index)] == nil then return true, false, "bad_setting" end
    if not Settings.available(sim, key) then return true, false, "locked" end
    return true, sim:setContextSetting(agentId, key, opts[tonumber(index)])
  end
  return false
end

return View
