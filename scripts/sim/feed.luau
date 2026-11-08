-- Agent feed (spec §12): one line per tool call and its result, e.g. `mine(K3, 100%) → +100 cobalt (80 s)`.
-- Sim-side data plus events only; the UI reads `sim.feed` and listens to `feed_event`.
local Ai = require("@scripts/config/ai")
local DecisionLog = require("@scripts/sim/decision_log")

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
  return ""
end

function Feed.formatCall(tool, args) return ("%s(%s)"):format(tool, fmtArgs(tool, args or {})) end

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
  return push(sim, { agent = agentId, kind = "call", status = "running", tool = call.name, args = call.args or {},
    reasoning = reasoning, recordId = recordId, text = Feed.formatCall(call.name, call.args) })
end

function Feed.finish(sim, entry, resultText, ok)
  if not entry or entry.status ~= "running" then return end
  entry.status = ok == false and "failed" or "ok"
  entry.text = entry.text .. " → " .. resultText
  if entry.recordId then DecisionLog.finished(sim, entry.recordId, resultText, ok) end
  sim:emit("feed_event", { entry = entry, update = true })
end

-- A call refused by the sim or by validation: listed with its error.
function Feed.refused(sim, agentId, call, err)
  local name = type(call) == "table" and call.name or "?"
  return push(sim, { agent = agentId, kind = "error", status = "failed", tool = name,
    text = Feed.formatCall(name, type(call) == "table" and call.args or {}) .. " → ERROR " .. tostring(err) })
end

function Feed.info(sim, agentId, text) return push(sim, { agent = agentId, kind = "info", text = text }) end
function Feed.error(sim, agentId, text) return push(sim, { agent = agentId, kind = "error", text = text }) end

return Feed
