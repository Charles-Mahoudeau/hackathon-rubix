-- Save controller for the game client (spec §3, §14, §16.3): load on boot, offline catch-up, autosave every
-- `autosaveSeconds` of real time, save on quit. Pure given a storage and the clocks the host passes in (`now` = real seconds
-- since launch, `utc` = wall-clock seconds), so the whole path runs headless against Persistence.memoryStorage().
-- A save that cannot be read (corrupt, unknown schema_version) is never touched: the controller is `blocked` (no autosave,
-- no save on quit) until the player picks "Play without saving" (stays blocked) or "Erase save and start new" (unblocks).
local Persistence = require("@scripts/sim/persistence")
local Sim = require("@scripts/sim/sim")
local Config = require("@scripts/config/save")

local Save = {}

function Save.new(storage, cfg)
  return { storage = storage, cfg = cfg or Config, blocked = false, error = nil, nextAt = nil, lastError = nil,
    lastSavedAt = nil, confirmErase = false, showOffline = false, saves = 0 }
end

-- Writes the sim now. -> ok, err. Never throws (a failed save must not take the game down).
function Save.write(self, sim, utc)
  if self.blocked then return false, { code = "blocked", message = "saving is off for this session" } end
  local call = function() return Persistence.save(sim, self.storage, self.cfg.file, utc) end
  local called, ok, e = pcall(call)
  if not called then ok, e = false, { code = "write_failed", message = tostring(ok) } end
  if not ok then
    self.lastError = e
    return false, e
  end
  self.lastError, self.lastSavedAt, self.saves = nil, utc, self.saves + 1
  return true
end

-- Boot: loads the save (or starts a new game when there is none), simulates the time away and saves at once so a crash
-- does not replay it. -> sim, report. When the save cannot be read the sim is a paused placeholder and `self.error` is set.
function Save.boot(self, now, utc)
  local sim, e = Persistence.loadOrNew(self.storage, self.cfg.file)
  if not sim then
    self.error, self.blocked = e, true
    local placeholder = Sim.new()
    placeholder.paused = true
    return placeholder, nil
  end
  local report = Persistence.catchUp(sim, utc)
  self.showOffline = report ~= nil
  self.nextAt = now + self.cfg.autosaveSeconds
  Save.write(self, sim, utc)
  return sim, report
end

-- Called every frame. -> true when an autosave was attempted.
function Save.tick(self, sim, now, utc)
  if self.blocked or not self.nextAt or now < self.nextAt then return false end
  self.nextAt = now + self.cfg.autosaveSeconds
  Save.write(self, sim, utc)
  return true
end

-- The window is closing.
function Save.quit(self, sim, utc)
  return Save.write(self, sim, utc)
end

-- A debug "Reset save" replaced the sim with a fresh one that is already on disk.
function Save.reset(self, now)
  self.error, self.blocked, self.confirmErase, self.showOffline = nil, false, false, false
  self.nextAt = now + self.cfg.autosaveSeconds
end

-- "save.play_unsaved" | "save.erase" (two clicks). -> handled, freshSim (only when the save was erased).
function Save.act(self, sim, action, now, utc)
  if action == "save.play_unsaved" then
    if not self.error then return false end
    self.error, self.confirmErase = nil, false
    sim.paused = false
    return true
  elseif action == "save.erase" then
    if not self.error then return false end
    if not self.confirmErase then
      self.confirmErase = true
      return true
    end
    local fresh, e = Persistence.reset(self.storage, self.cfg.file, utc)
    if not fresh then
      self.error, self.confirmErase = e, false
      return true
    end
    Save.reset(self, now)
    return true, fresh
  end
  return false
end

function Save.signature(self)
  return table.concat({ self.error and self.error.code or "", tostring(self.confirmErase), tostring(self.showOffline),
    tostring(self.blocked), self.lastError and self.lastError.code or "" }, "|")
end

return Save
