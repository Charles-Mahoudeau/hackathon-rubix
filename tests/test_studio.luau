-- Run from repo root: luau tests/test_studio.luau
-- GR5-26: the skill studio (record from the feed or the Logs, manual form, "make this a parameter", the near-duplicate
-- suggestion, assigning with parameter values) driven only by click strings, then M7b: one parameterized skill on 3 Miners.
local Sim = require("@scripts/sim/sim")
local Skills = require("@scripts/sim/skills")
local Market = require("@scripts/sim/market")
local Ai = require("@scripts/sim/ai")
local Studio = require("@scripts/ui/skill_studio")
local ArchiveView = require("@scripts/ui/archive_view")
local LogsView = require("@scripts/ui/logs_view")
local Shell = require("@scripts/ui/shell")
local Screens = require("@scripts/config/screens")

local function rich()
  local s = Sim.new()
  s.resources.credits = 100000
  Market.quiet(s.market)
  return s
end
local function click(sim, st, action)
  local handled, to = Studio.act(sim, st, action)
  assert(handled, "unhandled: " .. action)
  return to
end
local function rows(sim, st)
  local out = {}
  for _, row in ipairs(Studio.model(sim, st).rows or {}) do
    for _, cell in ipairs(row) do out[#out + 1] = cell end
  end
  return out
end
local function has(sim, st, label)
  for _, c in ipairs(rows(sim, st)) do if c.label == label or c.text == label then return c end end
  return nil
end
local function mineTwice(s, vein)
  for _ = 1, 2 do
    assert(s:apply("miner", { name = "mine", args = { vein = vein, stop_at_hold_pct = 90 } }))
    repeat s:step() until s.ships.s1.state == "idle"
  end
end

-- unknown actions are not ours
do
  local s, st = rich(), Studio.new()
  assert(not Studio.act(s, st, "logs.agent.all") and not Studio.act(s, st, 5))
end

-- 1. record from the feed with clicks: pick two ends, save, auto-named, runs with zero Compute
do
  local s, st = rich(), Studio.new()
  mineTwice(s, "K1")
  click(s, st, "studio.mode.record")
  local pick = {}
  for _, c in ipairs(rows(s, st)) do if c.action and c.action:match("^studio%.rec%.pick%.") then pick[#pick + 1] = c.action end end
  assert(#pick == 2, "two successful calls listed")
  assert(has(s, st, "Selected: 0 calls") and has(s, st, "Save as skill").color == "dim", "cannot save with nothing picked")
  click(s, st, "studio.rec.save")
  assert(st.message.bad, "nothing picked")
  click(s, st, pick[1])
  click(s, st, "studio.rec.save")
  assert(st.message.bad and st.message.text:find("2 to 8"), "one call is too few")
  click(s, st, pick[2])
  assert(has(s, st, "Selected: 2 calls").color == "green" and has(s, st, "Save as skill").color == "cyan")
  click(s, st, "studio.rec.save")
  assert(not st.message.bad and st.mode == "list", st.message.text)
  assert(s.skills["Mine K1"] and s.skills["Mine K1"].created_from == "recording" and #s.skills["Mine K1"].steps == 2)
  assert(Studio.model(s, st).message.text:find("Saved 'Mine K1'"))
end

-- 1b. more successful calls than one page: Older / Newer turn the pages and a range can span them
do
  local s, st = rich(), Studio.new()
  local per = Screens.studio.calls
  for i = 1, per * 2 + 3 do
    s.feedSeq = (s.feedSeq or 0) + 1
    s.feed[#s.feed + 1] = { id = 9000 + i, kind = "call", agent = "miner", status = "ok", tool = "mine", args = { vein = "K1", stop_at_hold_pct = 90 }, text = "x" }
  end
  click(s, st, "studio.mode.record")
  local function picks()
    local out = {}
    for _, c in ipairs(rows(s, st)) do if c.action and c.action:match("^studio%.rec%.pick%.") then out[#out + 1] = tonumber(c.action:match("(%d+)$")) end end
    return out
  end
  assert(#picks() == per and picks()[per] == 9000 + per * 2 + 3 and has(s, st, "Page 3 / 3"), "newest page first")
  assert(has(s, st, "Newer").color == "dim" and has(s, st, "Older").color == "cyan")
  click(s, st, "studio.rec.page.older")
  assert(picks()[per] == 9000 + per * 2 + 3 - per and has(s, st, "Page 2 / 3"), "older page")
  click(s, st, "studio.rec.page.older")
  click(s, st, "studio.rec.page.older")
  assert(has(s, st, "Page 1 / 3") and #picks() == 3 and has(s, st, "Older").color == "dim", "oldest page, clamped")
  click(s, st, "studio.rec.pick." .. picks()[3])
  click(s, st, "studio.rec.page.newer")
  click(s, st, "studio.rec.pick." .. picks()[1])
  assert(has(s, st, "Selected: 2 calls"), "a range spans two pages")
  click(s, st, "studio.rec.agent.miner")
  assert(has(s, st, "Page 3 / 3"), "switching agent goes back to the newest page")
end

-- 2. the same routine for another vein: the suggestion offers a parameter; accepting converts the first skill
do
  local s, st = rich(), Studio.new()
  s.upgrades.archive = 3
  mineTwice(s, "K1")
  local calls = {}
  for _, e in ipairs(s.feed) do if e.kind == "call" and e.status == "ok" then calls[#calls + 1] = e.id end end
  assert(#calls == 2)
  click(s, st, "studio.mode.record")
  click(s, st, "studio.rec.pick." .. calls[1])
  click(s, st, "studio.rec.pick." .. calls[2])
  click(s, st, "studio.rec.save")
  assert(s.skills["Mine K1"])
  mineTwice(s, "K2")
  click(s, st, "studio.mode.record")
  local ids = {}
  for _, c in ipairs(rows(s, st)) do local id = c.action and c.action:match("^studio%.rec%.pick%.(%d+)$"); if id then ids[#ids + 1] = tonumber(id) end end
  click(s, st, "studio.rec.pick." .. ids[#ids - 1])
  click(s, st, "studio.rec.pick." .. ids[#ids])
  click(s, st, "studio.rec.save")
  assert(st.suggestion and not s.skills["Mine K2"], "the near-duplicate is held back")
  assert(has(s, st, st.suggestion.sug.text) and has(s, st, "Make it a parameter") and has(s, st, "Save as a separate skill"))
  click(s, st, "studio.sug.cancel")
  assert(not st.suggestion and Skills.count(s) == 1)
  click(s, st, "studio.rec.save")
  assert(st.suggestion)
  click(s, st, "studio.sug.accept")
  assert(Skills.count(s) == 1 and s.skills["Mine K1"].params.vein and s.skills["Mine K1"].steps[1].args.vein == "$vein")
  assert(st.mode == "list" and st.message.text:find("parameter"))
  -- ... or save it anyway
  click(s, st, "studio.mode.record")
  click(s, st, "studio.rec.pick." .. ids[#ids - 1])
  click(s, st, "studio.rec.pick." .. ids[#ids])
  click(s, st, "studio.rec.save")
  assert(not st.suggestion and Skills.count(s) == 2, "the converted skill no longer matches")
end

-- 3. the manual form: steps from the agent's tools, args cycle, make-a-parameter, guard, reorder, loop, save
do
  local s, st = rich(), Studio.new()
  s.upgrades.archive = 3
  click(s, st, "studio.mode.form")
  assert(has(s, st, "+ mine") and has(s, st, "+ sell") and not has(s, st, "+ scan"), "scan is offered once it is equipped")
  click(s, st, "studio.form.add.mine")
  click(s, st, "studio.form.add.return")
  click(s, st, "studio.form.add.sell")
  local d = st.draft
  assert(#d.steps == 3 and d.steps[1].args.vein == "K1" and d.steps[1].args.stop_at_hold_pct == 90)
  click(s, st, "studio.form.arg.1.vein")
  assert(d.steps[1].args.vein == "K2", "a click moves to the next vein")
  click(s, st, "studio.form.arg.1.stop_at_hold_pct")
  assert(d.steps[1].args.stop_at_hold_pct == 100)
  click(s, st, "studio.form.guard.3")
  assert(d.steps[3].guard.min_unit_price == 8)
  assert(not Studio.act(s, st, "studio.form.guard.2") and d.steps[2].guard == nil, "only sell has a guard")
  click(s, st, "studio.form.up.3")
  assert(d.steps[2].tool == "sell" and d.steps[3].tool == "return")
  click(s, st, "studio.form.down.2")
  assert(d.steps[2].tool == "return")
  click(s, st, "studio.form.param.1.vein")
  d = st.draft
  assert(d.params.vein and d.steps[1].args.vein == "$vein" and has(s, st, "vein=$vein"))
  assert(d.steps[1].args.stop_at_hold_pct == 100, "other args stay")
  assert(not Studio.act(s, st, "studio.form.arg.1.vein") and d.steps[1].args.vein == "$vein", "a parameter does not cycle")
  click(s, st, "studio.form.unparam.1.vein")
  assert(next(st.draft.params) == nil and st.draft.steps[1].args.vein == "K1", "back to a plain value")
  click(s, st, "studio.form.param.1.vein")
  click(s, st, "studio.form.loop")
  assert(st.draft.loop == false)
  click(s, st, "studio.form.loop")
  click(s, st, "studio.form.save")
  assert(not st.message.bad, st.message.text)
  local skill = s.skills["Mine any vein"]
  assert(skill and skill.params.vein and skill.loop and skill.created_from == "manual" and skill.steps[3].guard.min_unit_price == 8)
  -- an empty form and a full Archive say why
  click(s, st, "studio.mode.form")
  click(s, st, "studio.form.save")
  assert(st.message.bad)
  s.upgrades.archive = 0
  click(s, st, "studio.form.add.mine")
  click(s, st, "studio.form.save")
  assert(st.message.bad and st.message.text:find("Archive is full") == 1 or st.message.text:find("Archive is full"), st.message.text)
  -- the form picks the agent type
  click(s, st, "studio.form.type.logistician")
  assert(#st.draft.steps == 0)
end

-- 4. assign with parameter values from the Archive
do
  local s, st = rich(), Studio.new()
  s.upgrades.archive = 3
  assert(Skills.save(s, { name = "ore-run", agent_type = "miner", loop = true, params = { vein = { kind = "vein", filter = { resource = "titanium" } } },
    steps = { { tool = "mine", args = { vein = "$vein" } }, { tool = "return" }, { tool = "sell" } } }))
  local m = ArchiveView.model(s)
  assert(#m.skills[1].assigns == 1 and m.skills[1].assigns[1].action == "studio.assign.ore-run.miner")
  click(s, st, "studio.assign.ore-run.miner")
  assert(st.assign and st.assign.params.vein == "K1")
  click(s, st, "studio.assign.cycle.vein")
  assert(st.assign.params.vein == "K2")
  click(s, st, "studio.assign.cycle.vein")
  assert(st.assign.params.vein == "A3", "the filter keeps only titanium veins")
  click(s, st, "studio.assign.cycle.vein")
  assert(st.assign.params.vein == "K1", "and wraps around; hidden veins are not offered")
  click(s, st, "studio.assign.cancel")
  assert(not st.assign and s.agents.miner.mode == "ai")
  click(s, st, "studio.assign.ore-run.miner")
  click(s, st, "studio.assign.cycle.vein")
  click(s, st, "studio.assign.start")
  assert(s.agents.miner.mode == "skill" and s.agents.miner.skillParams.vein == "K2" and not st.assign)
  m = ArchiveView.model(s)
  assert(m.skills[1].runners[1].params == "vein=K2" and m.skills[1].runners[1].stop == "studio.stop.miner")
  assert(ArchiveView.signature(s) ~= nil)
  click(s, st, "studio.stop.miner")
  assert(s.agents.miner.mode == "ai")
  -- a skill with no parameter starts at once; a wrong type is refused
  assert(Skills.save(s, { name = "plain", agent_type = "miner", loop = true, params = {}, steps = { { tool = "mine", args = { vein = "K1" } }, { tool = "return" } } }, { force = true }))
  click(s, st, "studio.assign.plain.miner")
  assert(s.agents.miner.mode == "skill" and not st.assign)
  click(s, st, "studio.assign.plain.nobody")
  assert(st.message.bad)
end

-- 5. Logs: a successful AI decision offers "Save as skill from here", which opens the recorder on that call
do
  local s, st = rich(), Studio.new()
  s:setDecider(Ai.decide)
  s:setDirective("miner", "Mine titanium on K1 until the hold is 100%, then sell at HMC.")
  s:run(3000)
  local view = LogsView.new()
  local rec
  for _, r in ipairs(s.records.miner) do if r.source == "ai" and Skills.feedIdForRecord(s, r.id) and r.tool_call and r.validation == "ok" then rec = r; break end end
  assert(rec, "an AI decision with a feed call")
  assert(LogsView.act(view, "logs.select." .. rec.id))
  local d = LogsView.model(s, view).detail
  assert(d.record and d.record.action == "studio.rec.from." .. rec.id)
  local to = click(s, st, d.record.action)
  assert(to == "archive" and st.mode == "record" and st.agent == "miner" and st.first == Skills.feedIdForRecord(s, rec.id))
  assert(not Studio.act(s, st, "studio.rec.from.99999"))
end

-- 6. every mode builds in the shell, with and without skills
do
  local s, st = rich(), Studio.new()
  mineTwice(s, "K1")
  for _, mode in ipairs({ "list", "record", "form" }) do
    click(s, st, "studio.mode." .. mode)
    assert(Shell.spec(s, "archive", { studio = st }))
  end
  click(s, st, "studio.form.add.mine")
  click(s, st, "studio.form.param.1.vein")
  assert(Shell.spec(s, "archive", { studio = st }))
  assert(Studio.signature(s, st) ~= nil)
  s.upgrades.archive = 3
  assert(Skills.save(s, { name = "ore-run", agent_type = "miner", loop = true, params = { vein = { kind = "vein" } }, steps = { { tool = "mine", args = { vein = "$vein" } }, { tool = "return" } } }))
  click(s, st, "studio.assign.ore-run.miner")
  assert(Shell.spec(s, "archive", { studio = st }) and Studio.model(s, st).assign)
  assert(Shell.spec(Sim.new(), "archive", {}), "the Archive screen shows with no skill")
end

-- 7. M7b: one parameterized skill runs on 3 Miners, each on its own vein, from clicks only
do
  local s, st = rich(), Studio.new()
  s.tier = 2
  for _, a in pairs(s.agents) do a.tier = 2 end
  s.upgrades.archive = 3
  for _, id in ipairs({ "miner_b", "miner_c" }) do
    s:addAgent(id, "miner")
    s:addShip("s_" .. id, id)
  end
  click(s, st, "studio.mode.form")
  click(s, st, "studio.form.add.mine")
  click(s, st, "studio.form.add.return")
  click(s, st, "studio.form.add.sell")
  click(s, st, "studio.form.param.1.vein")
  click(s, st, "studio.form.save")
  local name = "Mine any vein"
  assert(s.skills[name], tostring(st.message and st.message.text))
  local veins = { miner = "K1", miner_b = "K2", miner_c = "K3" }
  for _, id in ipairs({ "miner", "miner_b", "miner_c" }) do
    click(s, st, ("studio.assign.%s.%s"):format(name, id))
    while st.assign.params.vein ~= veins[id] do click(s, st, "studio.assign.cycle.vein") end
    click(s, st, "studio.assign.start")
  end
  local compute = s.resources.compute
  local seen = {}
  local ships = { miner = "s1", miner_b = "s_miner_b", miner_c = "s_miner_c" }
  for _ = 1, s:ticks(600) do
    s:step()
    for agent, ship in pairs(ships) do
      local v = s.ships[ship].vein
      if v then seen[agent] = seen[agent] or {}; seen[agent][v.id] = true end
    end
  end
  for agent, vein in pairs(veins) do
    assert(seen[agent] and seen[agent][vein], agent .. " mined its own vein")
    local n = 0
    for _ in pairs(seen[agent]) do n += 1 end
    assert(n == 1, agent .. " stayed on " .. vein)
  end
  assert(s.resources.compute == compute, "skills cost no Compute")
  local usage = Skills.usage(s)[name]
  assert(#usage == 3 and usage[1].params.vein == "K1" and usage[2].params.vein == "K2" and usage[3].params.vein == "K3")
  assert(#ArchiveView.model(s).skills[1].runners == 3)
end

print("studio OK")
