-- Logs screen view-model (GR5-8, spec §12.2): per-agent header stats, the filtered record list (newest first) and the
-- detail of the clicked record. Pure reads of the sim plus a small view state, no engine calls, so the numbers and the
-- filters are testable headless and the drawing code only lays them out.
local Screens = require("@scripts/config/screens")
local DecisionLog = require("@scripts/sim/decision_log")
local Feed = require("@scripts/sim/feed")

local View = {}

local function round(x) return math.floor(x + 0.5) end

-- Filter state of the screen. agent: "all" | an agent id; source: "all" | "ai" | "skill".
function View.new() return { agent = "all", source = "all", errorsOnly = false, selected = nil, page = 0 } end

local function clock(t)
  local s = math.floor(t)
  if s >= 3600 then return ("%d:%02d:%02d"):format(s // 3600, (s // 60) % 60, s % 60) end
  return ("%02d:%02d"):format(s // 60, s % 60)
end

local function agentIds(sim)
  local ids = {}
  for _, id in ipairs(sim.agentOrder) do ids[#ids + 1] = id end
  return ids
end

local function matches(view, rec)
  if view.agent ~= "all" and rec.agent_id ~= view.agent then return false end
  if view.source == "ai" and rec.source ~= "ai" then return false end
  if view.source == "skill" and rec.source:sub(1, 6) ~= "skill:" then return false end
  if view.errorsOnly and not DecisionLog.isError(rec) then return false end
  return true
end

-- Every record kept, whatever the filter.
function View.total(sim)
  local n = 0
  for _, l in pairs(sim.records) do n += #l end
  return n
end

local function callText(rec)
  local c = rec.tool_call
  if not c then return "(no call)" end
  return Feed.formatCall(c.tool, c.args)
end

local function rowText(rec, maxChars)
  local text = ("#%d %s %s %s %s"):format(rec.id, clock(rec.t_game), rec.agent_id, rec.source == "ai" and "ai" or rec.source, callText(rec))
  local reason = DecisionLog.errorReason(rec)
  if reason then text = text .. "  ! " .. reason
  elseif rec.validation == "pending" then text = text .. "  ..."
  elseif rec.credits_delta ~= 0 then text = text .. ("  +%d cr"):format(rec.credits_delta) end
  if #text > maxChars then text = text:sub(1, maxChars - 3) .. "..." end
  return text
end

local function detail(rec)
  local reason = DecisionLog.errorReason(rec)
  local t = rec.tokens
  local tokens = {}
  for _, k in ipairs({ "rules", "directive", "order", "context", "tools", "output", "total" }) do
    tokens[#tokens + 1] = { name = k, tokens = t[k] }
  end
  local sizes = {}
  for _, f in ipairs({ "compact", "json" }) do
    if rec.context_sizes and rec.context_sizes[f] then sizes[#sizes + 1] = { format = f, tokens = rec.context_sizes[f] } end
  end
  local latency = rec.t_real_received and rec.t_real_sent and (rec.t_real_received - rec.t_real_sent) or nil
  return {
    id = rec.id, agent = rec.agent_id, source = rec.source, promptVersion = rec.prompt_version,
    title = ("#%d  %s  %s"):format(rec.id, rec.agent_id, rec.source),
    time = ("game %s"):format(clock(rec.t_game)),
    latency = latency and ("%.1f s"):format(latency) or "-",
    tokens = tokens, realTokens = rec.real_tokens == true, contextSizes = sizes,
    computeText = ("%.1f Compute"):format(rec.compute_spent),
    reasoning = rec.reasoning or "(none)",
    call = callText(rec),
    validation = rec.validation, isError = reason ~= nil, reason = reason,
    fallback = rec.fallback == true,
    result = rec.result and (rec.result.result or rec.result.error) or (rec.validation == "pending" and "waiting for the answer" or "-"),
    credits = rec.credits_delta,
  }
end

-- The whole screen. `view` is the filter state of View.new().
function View.model(sim, view)
  local cfg = Screens.logs
  local header = {}
  for _, id in ipairs(agentIds(sim)) do
    local s = DecisionLog.stats(sim, id)
    header[#header + 1] = { id = id, creditsPerHour = round(s.credits_per_hour), computePerHour = round(s.compute_per_hour * 10) / 10,
      netPerHour = round(s.net_per_hour), raw = s }
  end
  local agents = { { id = "all", label = "All agents", active = view.agent == "all", action = "logs.agent.all" } }
  for _, id in ipairs(agentIds(sim)) do
    agents[#agents + 1] = { id = id, label = id, active = view.agent == id, action = "logs.agent." .. id }
  end
  local sources = {}
  for _, s in ipairs(cfg.sources) do
    sources[#sources + 1] = { id = s.id, label = s.label, active = view.source == s.id, action = "logs.source." .. s.id }
  end

  local list = {}
  for _, l in pairs(sim.records) do
    for _, rec in ipairs(l) do if matches(view, rec) then list[#list + 1] = rec end end
  end
  table.sort(list, function(a, b) return a.id > b.id end)
  local pages = math.max(1, math.ceil(#list / cfg.rows))
  local page = math.max(0, math.min(view.page, pages - 1))
  local rows = {}
  for i = page * cfg.rows + 1, math.min(#list, (page + 1) * cfg.rows) do
    local rec = list[i]
    rows[#rows + 1] = { id = rec.id, text = rowText(rec, cfg.rowChars), isError = DecisionLog.isError(rec),
      pending = rec.validation == "pending", selected = rec.id == view.selected, action = "logs.select." .. rec.id }
  end
  local selected = DecisionLog.find(sim, view.selected)
  return {
    header = header, agents = agents, sources = sources, errorsOnly = view.errorsOnly,
    rows = rows, shown = #list, total = View.total(sim), page = page, pages = pages,
    detail = selected and detail(selected) or nil, hint = cfg.hint,
  }
end

-- Click handling. Returns true when the view state changed.
function View.act(view, action)
  if type(action) ~= "string" or action:sub(1, 5) ~= "logs." then return false end
  local kind, arg = action:match("^logs%.(%a+)%.?(.*)$")
  if kind == "agent" then view.agent, view.page = arg, 0
  elseif kind == "source" then view.source, view.page = arg, 0
  elseif kind == "errors" then view.errorsOnly, view.page = not view.errorsOnly, 0
  elseif kind == "select" then
    local id = tonumber(arg)
    view.selected = view.selected ~= id and id or nil
  elseif kind == "page" then view.page = math.max(0, view.page + (tonumber(arg) or 0))
  else return false end
  return true
end

-- Changes whenever something the screen shows changes (a record opens or is filled, a filter moves, the header ticks).
function View.signature(sim, view)
  local parts = { sim.recordSeq, sim.recordRev, view.agent, view.source, tostring(view.errorsOnly), tostring(view.selected), view.page }
  for _, id in ipairs(agentIds(sim)) do
    local s = DecisionLog.stats(sim, id)
    parts[#parts + 1] = ("%d/%.1f"):format(round(s.credits_per_hour), s.compute_per_hour)
  end
  return table.concat(parts, "|")
end

return View
