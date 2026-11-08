-- Run from repo root: luau tests/test_client_sim.luau
-- GR5-71: the sim the client builds (client/sim_host) has the stub decider wired, so a precise directive typed in the
-- editor produces a mine -> return -> sell loop and credits rise.
local SimHost = require("@scripts/client/sim_host")
local Editor = require("@scripts/ui/agent_editor")
local Screens = require("@scripts/config/screens")

local Save = require("@scripts/client/save")
local Persistence = require("@scripts/sim/persistence")

-- the client boots through Save.boot (load or new game) and attaches the decider, as client/main does
local save = Save.new(Persistence.memoryStorage())
local sim = SimHost.attach((Save.boot(save, 0, 1000)))
assert(sim.decide, "the booted client sim has a decider")
assert(SimHost.new().decide, "SimHost.new has a decider")

local id = Screens.editor.agent
local draft = Editor.newDraft(sim, id)
draft.directive = "mine titanium at K1, return at 90%"
local ok = Editor.save(sim, id, draft)
assert(ok, "directive saved through the editor path")

local credits0 = sim.resources.credits
sim:run(6000)
assert(sim.resources.credits > credits0, "credits rise: " .. credits0 .. " -> " .. sim.resources.credits)

local mined, sold = false, false
for _, e in ipairs(sim.feed) do
  if e.kind == "call" and e.text:find("^mine%(K1, 90%%%) %-> %+%d+ titanium") then mined = true end
  if e.kind == "info" and e.text:find("sold", 1, true) then sold = true end
end
assert(mined, "feed has a mine(K1, 90%) line (the call covers the return trip)")
assert(sold, "feed lists the sale")

-- without the decider (the old client path) nothing happens
local Sim = require("@scripts/sim/sim")
local bare = Sim.new()
local feed0 = #bare.feed
bare:setDirective(id, "mine titanium at K1, return at 90%")
bare:run(600)
assert(#bare.feed == feed0 and bare.resources.credits == credits0, "a sim with no decider stays idle")
print("test_client_sim ok")
