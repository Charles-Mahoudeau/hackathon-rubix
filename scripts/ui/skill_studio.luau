-- Skill studio view-model (GR5-26, spec §13.2b/§13.3): the three ways the player works with skills on the Archive screen.
--   Record: pick a range of an agent's successful feed calls and save it ("Save as skill").
--   New skill: the manual form (steps from the agent's tools, args from dropdown-like cycles, guards, loop, "make this a parameter").
--   Assign: start a skill on an agent and give a value to each of its parameters.
-- Pure reads of the sim plus a small state table; clicks arrive as "studio.*" action strings, so every path runs headless.
-- The shell only lays out `model.rows` (cells of text and buttons).
local Skills = require("@scripts/sim/skills")
local Feed = require("@scripts/sim/feed")
local DecisionLog = require("@scripts/sim/decision_log")
local World = require("@scripts/config/world")
local Screens = require("@scripts/config/screens")
local Theme = require("@scripts/config/theme")

local Studio = {}

local WARN = Theme.semantic.warning

-- Args the form shows per tool, in order. `report` (free text) and `run_skill` have no place in a skill.
local FORM_ARGS = {
  mine = { "vein", "stop_at_hold_pct" }, ["return"] = { "to" }, sell = { "buyer", "resource", "qty" },
  store = { "resource", "qty" }, ship = { "resource", "qty", "destination" }, scan = { "planet" }, wait = { "seconds" },
}
local FORM_TOOLS = { "mine", "return", "sell", "store", "ship", "scan", "wait" }

local ERRORS = {
  bad_name = "The name must be 1 to 24 characters.",
  name_taken = "A skill with that name already exists.",
  archive_full = "The Archive is full: buy an Archive slot in the Shop (or build the warehouse).",
  bad_steps = "A skill needs 1 to 12 steps.",
  bad_range = "Pick calls of one agent from the list.",
  bad_length = "Pick 2 to 8 calls.",
  not_successful = "Only successful calls can be recorded.",
  bad_params = "Give every parameter a value.",
  wrong_agent_type = "That skill is for another type of agent.",
  unknown_skill = "That skill no longer exists.",
}

function Studio.new()
  return { mode = "list", agent = nil, first = nil, last = nil, draft = nil, message = nil, suggestion = nil, assign = nil }
end

local function say(st, text, bad) st.message = { text = text, bad = bad or false } end
local function errText(err, detail) return ERRORS[err] or (tostring(err) .. (detail and (": " .. tostring(detail)) or "")) end

local function sortedKeys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

local function isParam(v) return type(v) == "string" and v:sub(1, 1) == "$" end

-- Agents that can run skills, in team order.
local function agentIds(sim)
  local out = {}
  for _, id in ipairs(sim.agentOrder) do out[#out + 1] = id end
  return out
end

local function knownVeins(sim, filter)
  local out = {}
  for _, def in ipairs(World.veins) do
    local id = def.id
    local v = sim.veins[id]
    if v and (not v.hidden or v.scanned) and (not filter or ((not filter.resource or v.ore == filter.resource) and (not filter.planet or v.planet == filter.planet))) then
      out[#out + 1] = id
    end
  end
  return out
end

-- The values an arg (form) or a parameter (assign) cycles through.
local function argOptions(sim, arg)
  local f = sim.b.skills.form
  if arg == "vein" then return knownVeins(sim)
  elseif arg == "stop_at_hold_pct" or arg == "pct" then return f.pctOptions
  elseif arg == "to" then return { "home", "local_depot" }
  elseif arg == "buyer" then
    local out = { "hmc" }
    for _, m in ipairs(World.marketOrder) do out[#out + 1] = m end
    return out
  elseif arg == "resource" then return World.oreOrder
  elseif arg == "qty" then return f.qtyOptions
  elseif arg == "destination" then return World.marketOrder
  elseif arg == "planet" or arg == "station" then return World.planetOrder
  elseif arg == "seconds" then return f.waitOptions end
  return {}
end

local function paramOptions(sim, decl)
  if decl.kind == "vein" then return knownVeins(sim, decl.filter) end
  return argOptions(sim, decl.kind)
end

local function nextOf(list, current)
  if #list == 0 then return current end
  for i, v in ipairs(list) do
    if tostring(v) == tostring(current) then return list[i % #list + 1] end
  end
  return list[1]
end

local function argsText(args)
  local parts = {}
  for _, k in ipairs(sortedKeys(args or {})) do parts[#parts + 1] = ("%s=%s"):format(k, tostring(args[k])) end
  return table.concat(parts, " ")
end

local function titleCase(s) return s:sub(1, 1):upper() .. s:sub(2) end

-- A readable unique name for a skill with no typed name: "Mine K1", "Mine $vein" -> "Mine any vein", then " 2", " 3".
function Studio.autoName(sim, skill)
  local cfg = sim.b.skills
  local first = skill.steps[1]
  local base = first and titleCase(first.tool) or titleCase(Screens.studio.autoNameFallback)
  local args = first and first.args or {}
  local arg = args.vein
  if arg == nil then arg = select(2, next(args)) end
  if arg ~= nil then
    arg = tostring(arg)
    base ..= isParam(arg) and (" any " .. arg:sub(2)) or (" " .. arg)
  end
  base = base:sub(1, cfg.nameMax)
  local name, n = base, 1
  while sim.skills[name] do
    n += 1
    local suffix = " " .. n
    name = base:sub(1, cfg.nameMax - #suffix) .. suffix
  end
  return name
end

local function reset(st)
  st.first, st.last, st.draft, st.suggestion = nil, nil, nil, nil
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Record

-- Successful calls of the picked agent, oldest first (the feed keeps the latest ones).
local function recordable(sim, agentId)
  local out = {}
  for _, e in ipairs(sim.feed) do
    if e.kind == "call" and e.agent == agentId and e.status == "ok" then out[#out + 1] = e end
  end
  return out
end

local function pickedAgent(sim, st)
  if st.agent and sim.agents[st.agent] then return st.agent end
  return sim.agentOrder[1]
end

-- The picked calls: every recordable call between the two ends (either order).
local function selection(sim, st, agentId)
  if not st.first then return {} end
  local lo, hi = math.min(st.first, st.last or st.first), math.max(st.first, st.last or st.first)
  local out = {}
  for _, e in ipairs(recordable(sim, agentId)) do
    if e.id >= lo and e.id <= hi then out[#out + 1] = e end
  end
  return out
end

local function saveSkill(sim, st, skill, opts)
  local ok, name, sug = Skills.save(sim, skill, opts)
  if ok then
    say(st, ("Saved '%s' (Archive %d/%d)."):format(name, Skills.count(sim), sim:archiveCapacity()))
    reset(st)
    st.mode = "list"
  elseif name == "similar_skill" then
    st.suggestion = { sug = sug, skill = skill }
    st.message = nil
  else
    say(st, errText(name), true)
  end
  return ok
end

local function recordSave(sim, st)
  local agentId = pickedAgent(sim, st)
  local picked = selection(sim, st, agentId)
  if #picked == 0 then return say(st, "Pick the first and the last call of the routine.", true) end
  local skill, err = Skills.record(sim, agentId, picked[1].id, picked[#picked].id, "tmp")
  if not skill then return say(st, errText(err), true) end
  skill.name = Studio.autoName(sim, skill)
  saveSkill(sim, st, skill)
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Form

local function newDraft(agentType)
  return { agent_type = agentType, params = {}, steps = {}, loop = true, created_from = "manual" }
end

local function defaultArgs(sim, agentType, tool)
  local ore = World.oreOrder[1]
  if tool == "mine" then return { vein = knownVeins(sim)[1], stop_at_hold_pct = 90 }
  elseif tool == "return" then return { to = "home" }
  elseif tool == "sell" then
    if agentType == "logistician" then return { buyer = "hmc", resource = ore, qty = "all" } end
    return { buyer = "hmc" }
  elseif tool == "store" then return { resource = ore, qty = "all" }
  elseif tool == "ship" then return { resource = ore, qty = "all", destination = World.marketOrder[1] }
  elseif tool == "scan" then return { planet = World.homePlanet }
  elseif tool == "wait" then return { seconds = sim.b.skills.form.waitOptions[2] } end
  return {}
end

-- Tools the form offers for a type: the ones some agent of that type has equipped (spec §13.2).
local function formTools(sim, agentType)
  local out = {}
  for _, tool in ipairs(FORM_TOOLS) do
    for _, id in ipairs(sim.agentOrder) do
      if sim.agents[id].type == agentType and sim:hasTool(id, tool) then out[#out + 1] = tool; break end
    end
  end
  return out
end

local function agentTypes(sim)
  local out, seen = {}, {}
  for _, id in ipairs(sim.agentOrder) do
    local t = sim.agents[id].type
    if not seen[t] then seen[t] = true; out[#out + 1] = t end
  end
  return out
end

local function dropUnusedParams(draft)
  local used = {}
  for _, step in ipairs(draft.steps) do
    for _, v in pairs(step.args or {}) do if isParam(v) then used[v:sub(2)] = true end end
  end
  for name in pairs(draft.params) do if not used[name] then draft.params[name] = nil end end
end

local function formAct(sim, st, action)
  local d = st.draft or newDraft(agentTypes(sim)[1] or "miner")
  st.draft = d
  local kind, a, b = action:match("^studio%.form%.(%a+)%.?([^.]*)%.?(.*)$")
  local i = tonumber(a)
  if kind == "type" then
    if d.agent_type ~= a then st.draft = newDraft(a) end
  elseif kind == "add" then
    if #d.steps >= sim.b.skills.stepsMax then return say(st, errText("bad_steps"), true) end
    d.steps[#d.steps + 1] = { tool = a, args = defaultArgs(sim, d.agent_type, a) }
  elseif kind == "up" and i and d.steps[i] and i > 1 then
    d.steps[i - 1], d.steps[i] = d.steps[i], d.steps[i - 1]
  elseif kind == "down" and i and d.steps[i] and i < #d.steps then
    d.steps[i + 1], d.steps[i] = d.steps[i], d.steps[i + 1]
  elseif kind == "del" and i and d.steps[i] then
    table.remove(d.steps, i)
    dropUnusedParams(d)
  elseif kind == "arg" and i and d.steps[i] and d.steps[i].args[b] ~= nil and not isParam(d.steps[i].args[b]) then
    d.steps[i].args[b] = nextOf(argOptions(sim, b), d.steps[i].args[b])
  elseif kind == "param" and i and d.steps[i] and d.steps[i].args[b] ~= nil then
    local converted, err = Skills.makeParam(d, b, nil, d.steps[i].args[b])
    if converted then
      -- the clicked value becomes the parameter, in every step that holds the same value
      st.draft = converted
    else
      say(st, errText(err), true)
    end
  elseif kind == "unparam" and i and d.steps[i] and isParam(d.steps[i].args[b]) then
    local token = d.steps[i].args[b]
    local first = argOptions(sim, b)[1]
    for _, step in ipairs(d.steps) do
      for k, v in pairs(step.args) do if v == token then step.args[k] = first end end
    end
    dropUnusedParams(d)
  elseif kind == "guard" and i and d.steps[i] and d.steps[i].tool == "sell" then
    local step = d.steps[i]
    local prices = sim.b.skills.form.guardPrices
    if not step.guard then step.guard = { min_unit_price = prices[1] }
    else
      local nxt
      for j, p in ipairs(prices) do if p == step.guard.min_unit_price then nxt = prices[j + 1] end end
      step.guard = nxt and { min_unit_price = nxt } or nil
    end
  elseif kind == "loop" then
    d.loop = not d.loop
  elseif kind == "save" then
    if #d.steps == 0 then return say(st, errText("bad_steps"), true) end
    local skill = copy(d)
    skill.name = Studio.autoName(sim, skill)
    saveSkill(sim, st, skill)
  else
    return false
  end
  return true
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Assign

local function startAssign(sim, st, skillName, agentId)
  local skill = sim.skills[skillName]
  if not skill then return say(st, errText("unknown_skill"), true) end
  local params = {}
  for _, name in ipairs(sortedKeys(skill.params or {})) do
    local current = sim.agents[agentId] and sim.agents[agentId].activeSkill == skillName and sim.agents[agentId].skillParams
    params[name] = (current and current[name]) or paramOptions(sim, skill.params[name])[1]
  end
  if next(params) == nil then
    local ok, err, detail = Skills.assign(sim, agentId, skillName, {})
    if ok then say(st, ("%s now runs '%s'."):format(agentId, skillName)) else say(st, errText(err, detail), true) end
    return
  end
  st.assign = { skill = skillName, agent = agentId, params = params }
  st.message = nil
end

local function assignAct(sim, st, action)
  local asg = st.assign
  if action == "studio.assign.cancel" then st.assign = nil; return true end
  if asg then
    local pname = action:match("^studio%.assign%.cycle%.(.+)$")
    if pname then
      local skill = sim.skills[asg.skill]
      local decl = skill and skill.params and skill.params[pname]
      if not decl then return false end
      asg.params[pname] = nextOf(paramOptions(sim, decl), asg.params[pname])
      return true
    end
    if action == "studio.assign.start" then
      local ok, err, detail = Skills.assign(sim, asg.agent, asg.skill, asg.params)
      if ok then
        say(st, ("%s now runs '%s' (%s)."):format(asg.agent, asg.skill, argsText(asg.params)))
        st.assign = nil
      else
        say(st, errText(err, detail), true)
      end
      return true
    end
  end
  local skillName, agentId = action:match("^studio%.assign%.(.+)%.([^.]+)$")
  if skillName then
    startAssign(sim, st, skillName, agentId)
    return true
  end
  return false
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Clicks

-- "studio.*" action. -> handled, goto (a screen id to open, or nil)
function Studio.act(sim, st, action)
  if type(action) ~= "string" or action:sub(1, 7) ~= "studio." then return false end
  local mode = action:match("^studio%.mode%.(%a+)$")
  if mode then
    if mode ~= "list" and mode ~= "record" and mode ~= "form" then return false end
    st.mode, st.assign, st.message, st.suggestion = mode, nil, nil, nil
    return true
  end
  if action:sub(1, 12) == "studio.form." then
    st.mode, st.message = "form", nil
    return formAct(sim, st, action) ~= false, nil
  end
  local agent = action:match("^studio%.rec%.agent%.(.+)$")
  if agent then
    if not sim.agents[agent] then return false end
    st.agent, st.first, st.last, st.message = agent, nil, nil, nil
    return true
  end
  local pick = action:match("^studio%.rec%.pick%.(%d+)$")
  if pick then
    local id = tonumber(pick)
    if st.first and not st.last then st.last = id else st.first, st.last = id, nil end
    st.message = nil
    return true
  end
  local from = action:match("^studio%.rec%.from%.(%d+)$")
  if from then
    local rec = DecisionLog.find(sim, tonumber(from))
    local feedId = rec and Skills.feedIdForRecord(sim, rec.id)
    if not feedId then return false end
    st.mode, st.agent, st.first, st.last, st.message, st.assign, st.suggestion = "record", rec.agent_id, feedId, nil, nil, nil, nil
    return true, "archive"
  end
  if action == "studio.rec.save" then
    recordSave(sim, st)
    return true
  end
  if action == "studio.sug.accept" and st.suggestion then
    local ok, err = Skills.acceptSuggestion(sim, st.suggestion.sug)
    if ok then
      say(st, ("'%s' now has a $%s parameter; give it a value when you run it."):format(st.suggestion.sug.skill, st.suggestion.sug.param))
      reset(st)
      st.mode = "list"
    else
      say(st, errText(err), true)
    end
    return true
  end
  if action == "studio.sug.force" and st.suggestion then
    saveSkill(sim, st, st.suggestion.skill, { force = true })
    return true
  end
  if action == "studio.sug.cancel" then
    st.suggestion = nil
    return true
  end
  local stopAgent = action:match("^studio%.stop%.(.+)$")
  if stopAgent then
    local ok, err = Skills.stop(sim, stopAgent)
    if ok then say(st, ("%s is back in AI mode."):format(stopAgent)) else say(st, errText(err), true) end
    return true
  end
  if action:sub(1, 14) == "studio.assign." then return assignAct(sim, st, action) end
  return false
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Model

local function txt(text, color, w) return { text = text, color = color or "text", w = w } end
local function btn(label, action, color, w) return { label = label, action = action, color = color or "dim", w = w } end

local function suggestionRows(st)
  local rows = {}
  if st.suggestion then
    rows[#rows + 1] = { txt(st.suggestion.sug.text, WARN) }
    rows[#rows + 1] = { btn("Make it a parameter", "studio.sug.accept", "cyan", 200), btn("Save as a separate skill", "studio.sug.force", "dim", 220),
      btn("Cancel", "studio.sug.cancel", "dim", 90) }
  end
  return rows
end

local function recordRows(sim, st)
  local c = Screens.studio
  local rows = { { txt("Pick the first and the last call of a routine you liked (2 to 8 successful calls), then save it. It then runs with zero Compute.", "dim") } }
  local agentId = pickedAgent(sim, st)
  local agents = {}
  for _, id in ipairs(agentIds(sim)) do agents[#agents + 1] = btn(id, "studio.rec.agent." .. id, id == agentId and "cyan" or "dim", 130) end
  rows[#rows + 1] = agents
  local picked, inRange = selection(sim, st, agentId), {}
  for _, e in ipairs(picked) do inRange[e.id] = true end
  local list = recordable(sim, agentId)
  if #list == 0 then rows[#rows + 1] = { txt(("No successful calls from %s yet."):format(agentId), "dim") } end
  for i = math.max(1, #list - c.calls + 1), #list do
    local e = list[i]
    rows[#rows + 1] = { btn(("#%d  %s"):format(e.id, Feed.formatCall(e.tool, e.args)), "studio.rec.pick." .. e.id, inRange[e.id] and "cyan" or "dim", c.callWidth) }
  end
  local cfg = sim.b.skills
  local can = #picked >= cfg.recordMin and #picked <= cfg.recordMax
  rows[#rows + 1] = { txt(("Selected: %d call%s"):format(#picked, #picked == 1 and "" or "s"), can and "green" or "dim", 160),
    btn("Save as skill", "studio.rec.save", can and "cyan" or "dim", c.bigButtonWidth) }
  for _, r in ipairs(suggestionRows(st)) do rows[#rows + 1] = r end
  return rows
end

local function stepRow(sim, d, i, step)
  local c = Screens.studio
  local row = { txt(("%d. %s"):format(i, step.tool), "text", c.toolWidth) }
  for _, arg in ipairs(FORM_ARGS[step.tool] or {}) do
    local v = step.args[arg]
    if v ~= nil then
      if isParam(v) then
        row[#row + 1] = btn(("%s=%s"):format(arg, v), ("studio.form.unparam.%d.%s"):format(i, arg), "green", c.argWidth)
      else
        row[#row + 1] = btn(("%s=%s"):format(arg, tostring(v)), ("studio.form.arg.%d.%s"):format(i, arg), "dim", c.argWidth)
        if Skills.paramOfArg(arg) then row[#row + 1] = btn("$", ("studio.form.param.%d.%s"):format(i, arg), "cyan", c.smallWidth) end
      end
    end
  end
  if step.tool == "sell" then
    row[#row + 1] = btn(step.guard and (">= %g cr"):format(step.guard.min_unit_price) or "no price guard", "studio.form.guard." .. i, step.guard and "cyan" or "dim", 130)
  end
  row[#row + 1] = btn("^", "studio.form.up." .. i, "dim", c.smallWidth)
  row[#row + 1] = btn("v", "studio.form.down." .. i, "dim", c.smallWidth)
  row[#row + 1] = btn("x", "studio.form.del." .. i, "dim", c.smallWidth)
  return row
end

local function formRows(sim, st)
  local c = Screens.studio
  local d = st.draft or newDraft(agentTypes(sim)[1] or "miner")
  local rows = { { txt("Build a skill step by step. Click a value to change it; click $ to make that value a parameter you choose when you run the skill.", "dim") } }
  local types = {}
  for _, t in ipairs(agentTypes(sim)) do types[#types + 1] = btn(titleCase(t) .. " skill", "studio.form.type." .. t, t == d.agent_type and "cyan" or "dim", 140) end
  rows[#rows + 1] = types
  local tools = {}
  for _, tool in ipairs(formTools(sim, d.agent_type)) do tools[#tools + 1] = btn("+ " .. tool, "studio.form.add." .. tool, "dim", 96) end
  rows[#rows + 1] = tools
  for i, step in ipairs(d.steps) do rows[#rows + 1] = stepRow(sim, d, i, step) end
  if #d.steps == 0 then rows[#rows + 1] = { txt("No steps yet: add a tool above.", "dim") } end
  local params = {}
  for _, p in ipairs(sortedKeys(d.params)) do params[#params + 1] = "$" .. p end
  local ready = #d.steps > 0
  local preview = ready and Studio.autoName(sim, d) or "-"
  rows[#rows + 1] = { btn(d.loop and "Loops: yes" or "Loops: no", "studio.form.loop", "dim", 130),
    txt(("Name: %s%s"):format(preview, #params > 0 and ("   parameters: " .. table.concat(params, " ")) or ""), "text", 460),
    btn("Save skill", "studio.form.save", ready and "cyan" or "dim", c.bigButtonWidth) }
  for _, r in ipairs(suggestionRows(st)) do rows[#rows + 1] = r end
  return rows
end

local function assignRows(sim, st)
  local asg = st.assign
  local skill = sim.skills[asg.skill]
  local rows = { { txt(("Run '%s' on %s: choose a value for each parameter."):format(asg.skill, asg.agent), "dim") } }
  for _, name in ipairs(sortedKeys(skill and skill.params or {})) do
    rows[#rows + 1] = { txt("$" .. name, "text", 120), btn(tostring(asg.params[name]), "studio.assign.cycle." .. name, "cyan", 180) }
  end
  rows[#rows + 1] = { btn("Start", "studio.assign.start", "green", 120), btn("Cancel", "studio.assign.cancel", "dim", 100) }
  return rows
end

function Studio.model(sim, st)
  local tabs = {}
  for _, t in ipairs({ { "list", "Skills" }, { "record", "Record" }, { "form", "New skill" } }) do
    tabs[#tabs + 1] = { label = t[2], action = "studio.mode." .. t[1], active = st.mode == t[1] and not st.assign }
  end
  local rows
  if st.assign then rows = assignRows(sim, st)
  elseif st.mode == "record" then rows = recordRows(sim, st)
  elseif st.mode == "form" then rows = formRows(sim, st) end
  if st.mode == "list" and not st.assign then rows = suggestionRows(st); if #rows == 0 then rows = nil end end
  return { mode = st.mode, tabs = tabs, rows = rows, assign = st.assign, message = st.message, hasSuggestion = st.suggestion ~= nil }
end

-- One string that changes when what the studio shows changes.
function Studio.signature(sim, st)
  local parts = { st.mode, tostring(st.agent), tostring(st.first), tostring(st.last), tostring(#sim.feed), tostring(sim.feedSeq),
    st.message and st.message.text or "", tostring(st.suggestion ~= nil) }
  if st.draft then
    for _, step in ipairs(st.draft.steps) do parts[#parts + 1] = step.tool .. argsText(step.args) .. tostring(step.guard and step.guard.min_unit_price) end
    parts[#parts + 1] = st.draft.agent_type .. tostring(st.draft.loop)
  end
  if st.assign then parts[#parts + 1] = st.assign.skill .. st.assign.agent .. argsText(st.assign.params) end
  return table.concat(parts, "|")
end

return Studio
