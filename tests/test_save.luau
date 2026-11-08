-- GR5-77 gate: the client save controller (client/save.luau) wired to Persistence: load on boot, offline catch-up,
-- autosave every 30 s of real time, save on quit, and an unreadable save that is never touched. Headless, memory storage.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Clock = require("@scripts/sim/clock")
local Json = require("./support/engine_json")
local Persistence = require("@scripts/sim/persistence")
local Save = require("@scripts/client/save")
local Cfg = require("@scripts/config/save")
local SaveView = require("@scripts/ui/save_view")
local OfflineView = require("@scripts/ui/offline_view")
local Shell = require("@scripts/ui/shell")
local Fit = require("@scripts/ui/fit")
local Theme = require("@scripts/config/theme")

assert(Cfg.autosaveSeconds == 30 and Cfg.file:match("^[%w_%-%.]+$") and #Cfg.file <= 64 and Cfg.file:sub(1, 1) ~= ".", "valid engine save name")

local storage = Persistence.memoryStorage()
local T0 = 1700000000

-- first launch: no file => new game, written at once
local save = Save.new(storage)
local sim, report = Save.boot(save, 0, T0)
assert(sim.tick == 0 and report == nil and not save.blocked and not save.error)
assert(storage.files[Cfg.file] ~= nil, "a new game is saved at boot")

-- play ~2 minutes of real time at x1 (plus a skill-mode agent so skills and agents have something to restore)
sim:setDecider(Ai.decide)
sim:setDirective("miner", "Mine cobalt on K3 until the hold is 100%, then sell at HMC.")
local now, utc, autosaves = 0, T0, 0
for _ = 1, 1200 do
  Clock.advance(sim, 0.1)
  now += 0.1; utc += 0.1 -- real seconds
  if Save.tick(save, sim, now, math.floor(utc)) then autosaves += 1 end
end
assert(autosaves == 3, "autosave every 30 s of real time over 120 s: " .. autosaves) -- at 30, 60, 90 (float drift keeps 120 just out)
assert(sim.tick > 0)
local atAutosave = Persistence.load(storage, Cfg.file)
assert(atAutosave.tick <= sim.tick and atAutosave.tick >= sim.tick - 310, "autosave is recent, not stale")

-- quit saves the exact state
local quitUtc = math.floor(utc)
assert(Save.quit(save, sim, quitUtc))
local credits, tick, agents = sim.resources.credits, sim.tick, 0
for _ in pairs(sim.agents) do agents += 1 end
local skills = 0
for _ in pairs(sim.skills) do skills += 1 end

-- relaunch 20 s later (below the offline threshold): everything restored, no summary
local back = Save.new(storage)
local sim2, report2 = Save.boot(back, 0, quitUtc + 20)
assert(report2 == nil and not back.showOffline and sim2.lastOfflineReport == nil)
assert(sim2.tick == tick and sim2.resources.credits == credits, "game time and credits restored")
local agents2, skills2 = 0, 0
for _ in pairs(sim2.agents) do agents2 += 1 end
for _ in pairs(sim2.skills) do skills2 += 1 end
assert(agents2 == agents and skills2 == skills, "agents and skills restored")
assert(sim2.agents.miner.directive == sim.agents.miner.directive, "the directive survives")

-- relaunch an hour after the previous launch (it saved at quitUtc + 20): the offline summary is built, shown as a modal, and dismissable
local away = Save.new(storage)
local sim3, report3 = Save.boot(away, 0, quitUtc + 20 + 3600)
assert(report3 and report3.simulated_seconds == 3600 and sim3.lastOfflineReport == report3 and away.showOffline)
assert(sim3.tick > tick, "game time advanced by the catch-up")
local modal = SaveView.model(away, sim3)
assert(modal and modal.kind == "offline" and modal.buttons[1].action == "offline.dismiss" and #modal.lines >= 2)
assert(Persistence.load(storage, Cfg.file).tick == sim3.tick, "the catch-up is saved at boot so a crash does not replay it")
assert(OfflineView.act(sim3, "offline.dismiss") and SaveView.model(away, sim3) == nil)

-- an unknown schema_version: error screen, file untouched through tick / quit, play without saving
local future = '{"schema_version":999,"keep":"me"}'
local s2 = Persistence.memoryStorage()
s2.files[Cfg.file] = future
local bad = Save.new(s2)
local placeholder = Save.boot(bad, 0, T0)
assert(bad.blocked and bad.error.code == "unknown_schema" and bad.error.found == 999 and placeholder.paused)
local em = SaveView.model(bad, placeholder)
assert(em.kind == "error" and #em.buttons == 2 and em.lines[1]:find("999", 1, true))
assert(Save.tick(bad, placeholder, 1000, T0 + 1000) == false)
assert(select(1, Save.quit(bad, placeholder, T0 + 1000)) == false)
assert(s2.files[Cfg.file] == future, "unreadable save untouched by autosave and quit")
assert(Save.act(bad, placeholder, "save.play_unsaved", 5, T0))
assert(not bad.error and not placeholder.paused and bad.blocked and SaveView.model(bad, placeholder) == nil)
assert(Save.quit(bad, placeholder, T0 + 2000) == false and s2.files[Cfg.file] == future, "still not saving after Play without saving")

-- erasing needs two clicks and replaces the file with a fresh game
local s3 = Persistence.memoryStorage()
s3.files[Cfg.file] = future
local e = Save.new(s3)
local ph = Save.boot(e, 0, T0)
assert(Save.act(e, ph, "save.erase", 1, T0) and s3.files[Cfg.file] == future and e.confirmErase, "first click only asks")
assert(SaveView.model(e, ph).buttons[2].label:find("again", 1, true))
local handled, fresh = Save.act(e, ph, "save.erase", 2, T0)
assert(handled and fresh and fresh.tick == 0 and not e.blocked and not e.error)
assert(Persistence.load(s3, Cfg.file).tick == 0 and Save.write(e, fresh, T0 + 1), "erased: fresh game saved, saving is back")

-- a save the engine reports as damaged (read error) is an error, not a new game, and is not overwritten
local damaged = { files = { [Cfg.file] = "x" }, writes = 0 }
function damaged.read(path) return nil, "corrupt" end
function damaged.write(path, text) damaged.writes += 1; return true end
local d = Save.new(damaged)
Save.boot(d, 0, T0)
assert(d.blocked and d.error.code == "corrupt" and damaged.writes == 0)
assert(select(2, Persistence.save(Sim.new(), damaged, Cfg.file, T0)).code == "corrupt" and damaged.writes == 0, "save refuses an unreadable file")

-- a failing write never throws and is reported
local failing = { read = function() return nil end, write = function() return false, "io: disk full" end }
local f = Save.new(failing)
local fs = Save.boot(f, 0, T0)
assert(f.lastError and f.lastError.code == "write_failed" and fs.tick == 0)
assert(Save.tick(f, fs, 30, T0 + 30) and f.lastError.code == "write_failed")
local throwing = { read = function() return nil end, write = function() error("boom") end }
local t = Save.new(throwing)
Save.boot(t, 0, T0)
assert(t.lastError and t.lastError.code == "write_failed")

-- debug "Reset save" unblocks and reschedules
local r = Save.new(Persistence.memoryStorage())
Save.boot(r, 0, T0)
r.blocked, r.error = true, { code = "corrupt" }
Save.reset(r, 100)
assert(not r.blocked and not r.error and r.nextAt == 100 + Cfg.autosaveSeconds)

-- the modals fit the 1280x720 view
local again = Save.new(s2)
local againSim = Save.boot(again, 0, T0)
local confirming = Save.new(s2)
local confirmSim = Save.boot(confirming, 0, T0)
Save.act(confirming, confirmSim, "save.erase", 1, T0)
for _, case in ipairs({ { again, againSim, "error" }, { confirming, confirmSim, "confirm" }, { away, nil, "offline" } }) do
  local s, sm = case[1], case[2]
  if case[3] == "offline" then
    s.showOffline = true
    sm = Sim.new()
    sm.lastOfflineReport = report3
    -- long skill / abort lines must wrap, not overflow
    sm.lastOfflineReport = Json.decode(Json.encode(report3))
    sm.lastOfflineReport.aborted = { { agent = "miner", skill = "a-skill-with-a-very-long-name", reason = string.rep("the vein ran dry and nothing else was reachable ", 3) } }
  end
  assert(SaveView.model(s, sm), case[3])
  local spec = Shell.spec(sm, "map", { save = s })
  local problems = Fit.check(spec, Theme.layout.view)
  assert(#problems == 0, case[3] .. ": " .. table.concat(problems, "\n"))
end

print("save OK")
