-- Agent feed (spec §12): one line per tool call and its result, e.g. `mine(K3, 100%) -> +100 cobalt (80 s)`.
-- Sim-side data plus events only; the UI reads `sim.feed` and listens to `feed_event`.
local Ai = require("@scripts/config/ai")
local DecisionLog = require("@scripts/sim/decision_log")
local Copy = require("@scripts/sim/copy")

local Feed = {}

local function fmtArgs(tool, a)
  if tool == "mine" then return ("%s, %d%%"):format(tostring(a.vein), a.stop_at_hold_pct or 100) end
  if tool == "return" then return a.to or "home" end
  if tool == "sell" then
    local where = a.buyer and a.buyer ~= "hmc" and (" @" .. a.buyer) or ""
    return (a.resource and ("%s, %s"):format(a.resource, tostring(a.qty or "all")) or (a.planet or "")) .. where
  end
  if tool == "store" then return ("%s, %s"):format(tostring(a.resource), tostring(a.qty or "all")) end
  if tool == "ship" then return ("%s, %s -> %s"):format(tostring(a.resource), tostring(a.qty or "all"), tostring(a.destination)) end
  if tool == "run_skill" then return tostring(a.name) end
  if tool == "wait" then return tostring(a.seconds) end
  if tool == "report" then return a.to or "player" end
  if tool == "scan" then return tostring(a.planet) end
  if tool == "refine" then return ("%s x%s"):format(tostring(a.recipe), tostring(a.qty)) end
  if tool == "survey" then return tostring(a.site) end
  if tool == "salvage" then return ("%s, layer %s"):format(tostring(a.site), tostring(a.layer)) end
  if tool == "scan_route" then return tostring(a.route) end
  if tool == "intercept" then
    if type(a.convoy) == "table" then return ("max_escort=%s"):format(tostring(a.convoy.max_escort or "any")) end
    return tostring(a.convoy)
  end
  if tool == "set_order" then return ("%s, %q"):format(tostring(a.agent), tostring(a.text)) end
  if tool == "assign_skill" then return ("%s, %s"):format(tostring(a.agent), tostring(a.skill)) end
  if tool == "pause_agent" or tool == "resume_agent" then return tostring(a.agent) end
  return ""
end

function Feed.formatCall(tool, args) return ("%s(%s)"):format(tool, fmtArgs(tool, args or {})) end

-- A feed line as the UI font can draw it: the UI font is ASCII (+ Latin-1) only, and saves written before the feed switched to
-- "->" still hold the arrow glyph (U+2192), which would draw as "?". Every screen that shows feed text goes through this.
function Feed.display(text: string): string
  return (text:gsub("\226\134\146", "->"))
end

function Feed.init(sim) sim.feed, sim.feedSeq = {}, 0 end

local function push(sim, entry)
  sim.feedSeq += 1
  entry.id, entry.tick = sim.feedSeq, sim.tick
  local list = sim.feed
  list[#list + 1] = entry
  if #list > Ai.feedMax then table.remove(list, 1) end
  sim:emit("feed_event", { entry = entry, update = false })
  return entry
end

-- A call accepted by the sim. It stays "running" until `Feed.finish` gives it a result.
function Feed.begin(sim, agentId, call, reasoning, recordId)
  -- the history row Sim:apply just wrote for this call receives the result when the line finishes
  local agent = sim.agents[agentId]
  local h = agent and agent.history
  local last = h and h[#h]
  local histId
  if last and last.tool == call.name and last.ok and not last.linked then last.linked, histId = true, last.id end
  return push(sim, { agent = agentId, kind = "call", status = "running", tool = call.name, args = call.args or {},
    reasoning = reasoning, recordId = recordId, histId = histId, text = Feed.formatCall(call.name, call.args) })
end

-- `result` is the §11 result table of the call (history, `recent` context rows, decision log); without one the text
-- stands in, so a branch tool never reads blank.
function Feed.finish(sim, entry, resultText, ok, result)
  if not entry or entry.status ~= "running" then return end
  entry.status = ok == false and "failed" or "ok"
  entry.text = entry.text .. " -> " .. resultText
  if entry.histId then
    sim:setResult(entry.agent, entry.histId, result or (ok == false and { error = resultText }) or { result = resultText }, ok)
  end
  if entry.recordId then DecisionLog.finished(sim, entry.recordId, resultText, ok, result) end
  sim:emit("feed_event", { entry = entry, update = true })
end

-- A call refused by the sim or by validation: listed with its error.
function Feed.refused(sim, agentId, call, err)
  local name = type(call) == "table" and call.name or "?"
  return push(sim, { agent = agentId, kind = "error", status = "failed", tool = name,
    text = Feed.formatCall(name, type(call) == "table" and call.args or {}) .. (" -> ERROR %s (%s)"):format(Copy.error(err), tostring(err)) })
end

function Feed.info(sim, agentId, text, source) return push(sim, { agent = agentId, kind = "info", text = text, source = source }) end
function Feed.error(sim, agentId, text) return push(sim, { agent = agentId, kind = "error", text = text }) end

return Feed
