-- Save modal view-model (spec §14, §16.3): the unreadable-save error screen (boot) and the "While you were away" summary
-- shown over whatever screen is open at launch. Pure reads; the shell lays it out. Actions: save.play_unsaved, save.erase,
-- offline.dismiss (handled by OfflineView).
local Persistence = require("@scripts/sim/persistence")
local OfflineView = require("@scripts/ui/offline_view")

local View = {}

local function errorLines(e)
  if e.code == "unknown_schema" then
    return { ("This save was written by another version of the game (schema %s, this build reads %s)."):format(tostring(e.found), tostring(Persistence.SCHEMA_VERSION)),
      "The file was not changed and will not be overwritten while you play without saving." }
  end
  return { e.message or "The save file is damaged.", "The file was not changed. You can play without saving, or erase it and start a new game." }
end

-- save = the client/save.luau controller. -> nil | { kind, title, lines, buttons = { { label, action, color } } }
function View.model(save, sim)
  if save.error then
    local lines = errorLines(save.error)
    return { kind = "error", title = "Save cannot be loaded", lines = lines, buttons = {
      { label = "Play without saving", action = "save.play_unsaved", color = "cyan" },
      { label = save.confirmErase and "Click again to erase" or "Erase save, start new", action = "save.erase", color = save.confirmErase and "amber" or "dim" },
    } }
  end
  local away = save.showOffline and OfflineView.model(sim) or nil
  if away then
    return { kind = "offline", title = away.title, lines = away.lines, buttons = { { label = "Dismiss", action = away.dismiss, color = "cyan" } } }
  end
  return nil
end

function View.signature(save, sim)
  local r = sim.lastOfflineReport
  return (save.showOffline and r) and ("away:%d:%d"):format(r.simulated_seconds, r.credits) or ""
end

return View
