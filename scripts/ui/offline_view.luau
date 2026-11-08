-- "While you were away" view-model (GR5-10, spec §14): the report of the last offline simulation as text lines, and the
-- dismiss action. Pure reads, so the whole path is testable headless; the shell only lays it out.
local Offline = require("@scripts/sim/offline")

local View = {}

function View.model(sim)
  local r = sim.lastOfflineReport
  if not r then return nil end
  return { title = "While you were away", lines = Offline.lines(r), report = r, dismiss = "offline.dismiss" }
end

function View.signature(sim)
  local r = sim.lastOfflineReport
  return r and ("%d:%d:%d"):format(r.simulated_seconds, r.credits, #r.aborted) or ""
end

-- "offline.dismiss" -> handled.
function View.act(sim, action)
  if action ~= "offline.dismiss" then return false end
  sim.lastOfflineReport = nil
  return true
end

return View
