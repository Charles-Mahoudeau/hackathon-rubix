-- Skills (spec §13, D11): saved tool sequences that run with no AI and no Compute. A skill is data (`sim.skills[name]`),
-- the Archive is shared by the whole company, and the runner (Skills.step) is called once per tick for every agent in
-- skill mode. Pure sim logic: it talks to the UI only through sim events.
local World = require("@scripts/config/world")
local Feed = require("./feed")
local Words = require("@scripts/config/copy")
local Market = require("./market")
local Alerts = require("./alerts")

local Skills = {}

-- Which arg is turned into which parameter ("make this a parameter"), and which parameter kinds exist (spec §13.2b).
local PARAM_OF_ARG = { vein = "vein", resource = "resource", destination = "destination", buyer = "buyer", stop_at_hold_pct = "pct",
  route = "route", convoy = "convoy_filter", recipe = "recipe", site = "site" }
local PARAM_NAMES = { vein = "vein", resource = "resource", destination = "destination", buyer = "buyer", pct = "pct", station = "station",
  route = "route", convoy_filter = "convoy_filter", recipe = "recipe", site = "site" }

local function isParam(v) return type(v) == "string" and v:sub(1, 1) == "$" end

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

local function sortedKeys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end

-- The parameter an arg can become ("make this a parameter"), or nil when it cannot (spec §13.2b).
function Skills.paramOfArg(arg) return PARAM_OF_ARG[arg] end

function Skills.count(sim)
  local n = 0
  for _ in pairs(sim.skills) do n += 1 end
  return n
end

-- Skill names in alphabetical order.
function Skills.names(sim) return sortedKeys(sim.skills) end

-- Check parameter values against the skill's declarations (spec §13.2b). -> ok | false, "bad_params", detail
function Skills.checkParams(sim, skill, values)
  values = values or {}
  if type(values) ~= "table" then return false, "bad_params", "params must be an object" end
  for name in pairs(values) do
    if not (skill.params and skill.params[name]) then return false, "bad_params", "unknown parameter " .. tostring(name) end
  end
  for name, decl in pairs(skill.params or {}) do
    local v = values[name]
    if v == nil then return false, "bad_params", "missing parameter " .. name end
    local kind = decl.kind
    local err
    if kind == "destination" then
      if not World.markets[v] then err = name .. ": unknown market" end
    elseif kind == "buyer" then
      if v ~= "hmc" and not World.markets[v] then err = name .. ": unknown buyer" end
    elseif kind == "station" then
      if not sim.planets[v] then err = name .. ": unknown station" end
    else
      local k = sim.registry.paramKinds[kind]
      err = k and k.check and k.check(sim, name, v, decl) -- the kinds of a branch (vein, resource, pct: mining)
    end
    if err then return false, "bad_params", err end
  end
  return true
end

-- Structure check of a skill table. `agentId` (optional) also requires every tool to be equipped by that agent
-- (spec §13.2). -> ok | false, error
function Skills.validate(sim, skill, agentId)
  local cfg = sim.b.skills
  if type(skill) ~= "table" then return false, "bad_skill" end
  local len = type(skill.name) == "string" and (utf8.len(skill.name) or #skill.name) or 0
  if len < 1 or len > cfg.nameMax then return false, "bad_name" end
  local def = sim.registry.agentTypes[skill.agent_type]
  if not def then return false, "bad_agent_type" end
  if type(skill.steps) ~= "table" or #skill.steps < 1 or #skill.steps > cfg.stepsMax then return false, "bad_steps" end
  for name, decl in pairs(skill.params or {}) do
    if not sim.registry.paramKinds[type(decl) == "table" and decl.kind or ""] or sim.registry.paramKinds[decl.kind].reserved then return false, "bad_param_kind: " .. tostring(name) end
  end
  local allowed = {}
  for _, t in ipairs(def.tools) do allowed[t] = true end
  for i, step in ipairs(skill.steps) do
    if type(step) ~= "table" or not sim.registry.schemas[step.tool] or step.tool == "run_skill" then return false, ("step %d: bad tool"):format(i) end
    if not allowed[step.tool] or (agentId and not sim:hasTool(agentId, step.tool)) then
      return false, ("step %d: tool not equipped: %s"):format(i, step.tool)
    end
    for arg, v in pairs(step.args or {}) do
      if isParam(v) and not (skill.params and skill.params[v:sub(2)]) then return false, ("step %d: undeclared parameter %s"):format(i, v) end
      if type(arg) ~= "string" then return false, ("step %d: bad args"):format(i) end
    end
    if step.guard ~= nil then
      local g = step.guard
      if step.tool ~= "sell" or type(g) ~= "table" or type(g.min_unit_price) ~= "number" or g.min_unit_price <= 0 then
        return false, ("step %d: bad guard"):format(i)
      end
    end
  end
  return true
end

-- Two skills that differ only by arg values: { skill, step, arg, param, from, to } for the first arg that can become a parameter.
local function similarity(a, b)
  if a.agent_type ~= b.agent_type or #a.steps ~= #b.steps or (a.loop ~= false) ~= (b.loop ~= false) then return nil end
  local found
  for i, sa in ipairs(a.steps) do
    local sb = b.steps[i]
    if sa.tool ~= sb.tool then return nil end
    local aa, ba = sa.args or {}, sb.args or {}
    for k in pairs(aa) do if ba[k] == nil then return nil end end
    for k in pairs(ba) do if aa[k] == nil then return nil end end
    for _, k in ipairs(sortedKeys(aa)) do
      if aa[k] ~= ba[k] and not found and PARAM_OF_ARG[k] and not isParam(aa[k]) and not isParam(ba[k]) then
        found = { step = i, arg = k, param = PARAM_OF_ARG[k], from = ba[k], to = aa[k] }
      end
    end
  end
  return found
end

-- The first saved skill that `skill` is a near-duplicate of, with the suggestion text (spec §13.2b).
function Skills.suggestParam(sim, skill)
  for _, name in ipairs(Skills.names(sim)) do
    local other = sim.skills[name]
    local s = similarity(skill, other)
    if s then
      s.skill = name
      s.text = ("This looks like '%s' with another %s. Make the %s a parameter instead?"):format(name, s.param, s.param)
      return s
    end
  end
  return nil
end

-- A copy of `skill` where `arg` (same value in every step that has it) becomes a parameter. `only` picks which value
-- (default: the first found); a parameter of that name must not exist yet.
function Skills.makeParam(skill, arg, filter, only)
  local pname = PARAM_OF_ARG[arg]
  if not pname then return nil, "not_parametrizable" end
  if skill.params and skill.params[pname] then return nil, "already_parameter" end
  local out, value = copy(skill), only
  for _, step in ipairs(out.steps) do
    local v = step.args and step.args[arg]
    if v ~= nil and not isParam(v) and (value == nil or v == value) then value = v; step.args[arg] = "$" .. pname end
  end
  if value == nil then return nil, "no_such_arg" end
  out.params = out.params or {}
  out.params[pname] = { kind = PARAM_NAMES[pname], filter = filter }
  out.created_from = out.created_from or "manual"
  return out, value
end

-- Saves a skill into the company Archive. opts.agent: also require the tools to be equipped by that agent;
-- opts.force: save even when it looks like an existing skill with another arg value.
-- -> ok, name | false, error, suggestion
function Skills.save(sim, skill, opts)
  opts = opts or {}
  local ok, err = Skills.validate(sim, skill, opts.agent)
  if not ok then return false, err end
  if sim.skills[skill.name] then return false, "name_taken" end
  if Skills.count(sim) >= sim:archiveCapacity() then return false, "archive_full" end
  if not opts.force then
    local sug = Skills.suggestParam(sim, skill)
    if sug then return false, "similar_skill", sug end
  end
  local saved = copy(skill)
  saved.loop = saved.loop ~= false
  saved.params = saved.params or {}
  saved.created_from = saved.created_from or "manual"
  sim.skills[saved.name] = saved
  sim:log("INFO", ("skill saved: %s (%d steps)"):format(saved.name, #saved.steps))
  sim:emit("skill_saved", { name = saved.name })
  return true, saved.name
end

-- Accepts a suggestion: the existing skill becomes parameterized and the new one is not saved. Agents running it keep
-- the value they had. -> ok | false, error
function Skills.acceptSuggestion(sim, sug)
  local existing = sim.skills[sug.skill]
  if not existing then return false, "unknown_skill" end
  local converted, value = Skills.makeParam(existing, sug.arg)
  if not converted then return false, value end
  sim.skills[sug.skill] = converted
  for _, id in ipairs(sim.agentOrder) do
    local a = sim.agents[id]
    if a.activeSkill == sug.skill then
      a.skillParams = a.skillParams or {}
      a.skillParams[sug.param] = value
    end
  end
  return true
end

-- The feed entry a decision-log record produced (the Logs screen selects records, the recorder works on feed entries).
function Skills.feedIdForRecord(sim, recordId)
  for _, e in ipairs(sim.feed) do if e.recordId == recordId and e.kind == "call" then return e.id end end
  return nil
end

-- Recording (spec §13.3): the agent's feed calls from entry `firstId` to `lastId`, 2 to 8 contiguous successful calls.
-- Args are copied as they were. -> skill table (not saved yet) | nil, error
function Skills.record(sim, agentId, firstId, lastId, name)
  local cfg = sim.b.skills
  local agent = sim.agents[agentId]
  if not agent then return nil, "unknown agent" end
  local calls = {}
  for _, e in ipairs(sim.feed) do
    if e.agent == agentId and e.id >= firstId and e.id <= lastId then
      if e.kind == "call" then
        if e.status ~= "ok" then return nil, "not_successful" end
        calls[#calls + 1] = e
      elseif e.kind == "error" and e.tool then
        return nil, "not_successful"
      end
    end
  end
  if #calls == 0 or calls[1].id ~= firstId or calls[#calls].id ~= lastId then return nil, "bad_range" end
  if #calls < cfg.recordMin or #calls > cfg.recordMax then return nil, "bad_length" end
  local steps = {}
  for i, e in ipairs(calls) do
    local args = copy(e.args or {})
    args.ship = nil
    steps[i] = { tool = e.tool, args = args }
  end
  return { name = name, agent_type = agent.type, params = {}, steps = steps, loop = true, created_from = "recording" }
end

function Skills.delete(sim, name)
  if not sim.skills[name] then return false, "unknown_skill" end
  sim.skills[name] = nil
  sim:log("INFO", "skill deleted: " .. name)
  return true
end

-- Who runs what: name -> { { agent, params }, ... } in agent order.
function Skills.usage(sim)
  local out = {}
  for _, id in ipairs(sim.agentOrder) do
    local a = sim.agents[id]
    if a.mode == "skill" and a.activeSkill then
      local list = out[a.activeSkill]
      if not list then list = {}; out[a.activeSkill] = list end
      list[#list + 1] = { agent = id, params = a.skillParams or {}, aborted = a.skillRun and a.skillRun.aborted or nil }
    end
  end
  return out
end

-- Can `agent` start skill `name` with `params`? Shared by the AI tool, the player and the Monitor. -> skill | false, error, detail
function Skills.canStart(sim, agentId, name, params)
  local agent = sim.agents[agentId]
  local skill = sim.skills[name or ""]
  if not skill or not agent or skill.agent_type ~= agent.type then return false, "unknown_skill" end
  local ok, err, detail = Skills.checkParams(sim, skill, params)
  if not ok then return false, err, detail end
  return skill
end

-- Starts `name` on the agent (AI call, player or Monitor). name nil / "none": back to AI mode. -> ok | false, error
function Skills.assign(sim, agentId, name, params)
  local agent = sim.agents[agentId]
  if not agent then return false, "unknown agent" end
  if name == nil or name == "none" then return Skills.stop(sim, agentId) end
  local skill, err, detail = Skills.canStart(sim, agentId, name, params)
  if not skill then
    if err == "unknown_skill" and sim.skills[name] then err = "wrong_agent_type" end
    return false, err, detail
  end
  Skills.closeRun(sim, agentId, "replaced")
  agent.mode, agent.activeSkill, agent.skillParams = "skill", name, copy(params or {})
  agent.skillRun = { i = 1, loops = 0, loopStart = sim.tick }
  agent.blockReason = nil
  if agent.state ~= "paused_error" then agent.state = "idle" end
  sim:log("INFO", ("%s: running skill %s"):format(agentId, name))
  sim:emit("skill_assigned", { agent = agentId, skill = name })
  return true
end

-- The run_skill call that started the current skill gets its result: why the skill ended (spec §11).
function Skills.closeRun(sim, agentId, because)
  local agent = sim.agents[agentId]
  if not agent or not agent.skillHistId then return end
  sim:setResult(agentId, agent.skillHistId, { skill_ended_because = because })
  agent.skillHistId = nil
end

function Skills.stop(sim, agentId)
  local agent = sim.agents[agentId]
  if not agent then return false, "unknown agent" end
  Skills.closeRun(sim, agentId, "stopped")
  agent.mode, agent.activeSkill, agent.skillParams, agent.skillRun = "ai", nil, nil, nil
  if agent.state == "acting" then agent.state = "idle" end
  return true
end

-- Restart an aborted skill with the same parameters (the player is back).
function Skills.restart(sim, agentId)
  local agent = sim.agents[agentId]
  if not agent or agent.mode ~= "skill" or not agent.activeSkill then return false, "no_skill" end
  return Skills.assign(sim, agentId, agent.activeSkill, agent.skillParams)
end

-- A skill stops: `aborted` is a failed step, `completed` the end of a non-looping skill. With wake_ai_on_skill_abort, a
-- directive and Compute the agent goes back to AI mode with the reason in its inbox; otherwise (and always offline) it idles.
local function stop(sim, agentId, agent, reason, completed)
  local name = agent.activeSkill
  Skills.closeRun(sim, agentId, completed and "completed" or reason)
  local text = completed and ("skill '%s' completed"):format(name) or ("skill '%s' aborted: %s"):format(name, reason)
  sim:log(completed and "INFO" or "WARN", agentId .. ": " .. text)
  Feed.error(sim, agentId, completed and text or ("%s %s: %s"):format(Words.skill.aborted, name, reason))
  local inbox = agent.inbox
  inbox[#inbox + 1] = text
  while #inbox > sim.b.inboxKeep do table.remove(inbox, 1) end
  sim:emit("skill_aborted", { agent = agentId, skill = name, reason = reason, completed = completed or false })
  if not completed and not sim.offline then Alerts.raise(sim, "skill_aborted", agentId, reason, { skill = name, params = agent.skillParams }) end
  if sim.tally then
    local t = sim.tally.aborted
    t[#t + 1] = { agent = agentId, skill = name, reason = reason, completed = completed or false,
      at = (sim.tick - sim.tally.startTick) * sim.b.tickSeconds }
  end
  local hasText = (agent.directive or "") ~= "" or (agent.order or "") ~= ""
  if not sim.offline and agent.wakeAiOnSkillAbort and hasText and sim.resources.compute >= sim.b.skills.wakeMinCompute then
    agent.mode, agent.activeSkill, agent.skillParams, agent.skillRun = "ai", nil, nil, nil
    if agent.state == "acting" then agent.state = "idle" end
  else
    agent.skillRun = { aborted = reason, completed = completed or false, i = 1 }
    if agent.state ~= "paused_error" then agent.state = "idle" end
  end
end

function Skills.abort(sim, agentId, reason) stop(sim, agentId, sim.agents[agentId], reason, false) end

-- The call a step makes with the agent's parameter values filled in.
local function resolve(skill, step, params)
  local args = {}
  for k, v in pairs(step.args or {}) do
    if isParam(v) then v = params and params[v:sub(2)] end
    args[k] = v
  end
  return { name = step.tool, args = args }
end

-- Price per unit the sell call would get now, for the guard (nil when it cannot be told).
local function unitPrice(sim, agent, ship, call)
  local args = call.args
  local buyer = args.buyer or "hmc"
  local ore = ship and ship.ore or args.resource
  if args.resource then ore = args.resource end
  if not ore or not World.ores[ore] then return nil end
  if buyer == "orbis" then return Market.price(sim.market, "orbis", ore) end
  local planet = ship and (args.planet or ship.at) or agent.station
  return sim.planets[planet].depotRate * World.ores[ore].basePrice
end

local function advance(sim, agent, run, skill)
  run.i += 1
  if run.i > #skill.steps then
    if skill.loop == false then return true end
    run.i, run.loops = 1, run.loops + 1
    local resume = run.loopStart + sim:ticks(sim.b.skills.minLoopSeconds)
    if sim.tick < resume then run.holdUntil = resume end
    run.loopStart = math.max(sim.tick, resume)
  end
  return false
end

-- One tick of the runner for an agent in skill mode: when the agent is free (its ship docked, no wait running) the next
-- step runs exactly like an AI call, with no Compute (spec §13.2). The first failing step aborts the skill.
function Skills.step(sim, agentId, agent)
  local run = agent.skillRun
  if not run or run.aborted then
    if agent.state ~= "paused_error" and agent.state ~= "idle" then agent.state = "idle" end
    return
  end
  if agent.state == "paused_error" then return end
  local skill = sim.skills[agent.activeSkill or ""]
  if not skill then return stop(sim, agentId, agent, "skill_deleted", false) end
  local ship = agent.type == "miner" and sim:ownedShip(agentId) or nil
  local def = sim.registry.agentTypes[agent.type]
  local branchBusy = def.busy ~= nil and def.busy(sim, agent)
  if (ship and ship.state ~= "idle") or branchBusy or (run.waitUntil and sim.tick < run.waitUntil) or (run.holdUntil and sim.tick < run.holdUntil) then
    agent.state = "acting"
    return
  end
  run.waitUntil, run.holdUntil = nil, nil
  agent.state = "acting"
  local step = skill.steps[run.i]
  local call = resolve(skill, step, agent.skillParams)
  local skip
  local branchSkip = def.skip and def.skip(sim, agent, call)
  if branchSkip then
    skip = branchSkip
  elseif ship and call.name == "return" and ship.state == "idle" then
    skip = "already docked" -- the ship came home on its own once the hold was full
  elseif ship and call.name == "sell" and (call.args.buyer or "hmc") == "hmc" and ship.cargo <= 0 and not sim:hasWarehouse() then
    skip = "hold already sold at the depot"
  elseif step.guard and step.guard.min_unit_price then
    local price = unitPrice(sim, agent, ship, call)
    if price and price < step.guard.min_unit_price then
      skip = ("price %.1f below %g"):format(price, step.guard.min_unit_price)
      Feed.info(sim, agentId, ("skip sell: %s"):format(skip))
    end
  end
  if skip == nil then
    local ok, err = sim:apply(agentId, call, { skill = skill.name })
    if not ok then return stop(sim, agentId, agent, err, false) end
    if call.name == "wait" and not ship then run.waitUntil = sim.tick + sim:ticks(call.args.seconds) end
  end
  if advance(sim, agent, run, skill) then stop(sim, agentId, agent, "completed", true) end
end

return Skills
