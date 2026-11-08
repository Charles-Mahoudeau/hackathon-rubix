-- AI decision interface. Swapping in RUBIX later = replace ONLY Ai.decide.
-- Contract: decide(sim, agentId, context) -> { name = string, args = table }
-- AI output is always a tool call, never free text; Sim validates everything.
local World = require("@scripts/config/world")
local AiConfig = require("@scripts/config/ai")
local Skills = require("@scripts/sim/skills")
local Refined = require("@scripts/config/branches").refining
local Market = require("@scripts/sim/market")

local Ai = {}
local mode = "stub" -- "stub" (spec §10.5, reads the directive) | "optimal" (always the best call) | "vague" (random bad calls)
local providers = {} -- name -> decide(sim, agentId, ctx); the real provider registers itself here
local provider = "stub"

local logisticianStub, monitorStub

-- The always-best-call stub of the Miner (declared by the mining branch, sim/branches/mining.luau).
function Ai.minerOptimal(sim, agentId, ctx)
  local ship = ctx.ship
  if ship.cargo > 0 then return { name = "sell", args = { ship = ship.id } } end
  -- best known vein on a reachable planet: richness (band midpoint if unscanned) x hardness x depot price, per trip jump
  local mid = { low = 1.0, medium = 1.5, high = 2.0 }
  local best, bv = -1, nil
  for _, p in pairs(ctx.planets) do
    if p.reachable then
      for _, v in ipairs(p.veins) do
        local ore = World.ores[v.ore]
        local depleted = v.reserve ~= nil and v.reserve < 1
        local score = (v.richness or mid[v.band]) * ore.hardness * ore.basePrice * p.depotRate / (v.jumps + 1)
        if not depleted and score > best then best, bv = score, v.id end
      end
    end
  end
  if not bv then return { name = "wait", args = { seconds = sim.b.waitMinSeconds } } end
  return { name = "mine", args = { vein = bv, ship = ship.id } }
end

local function sortedKeys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end

local function firstWord(text, words)
  local best, bestPos
  for _, w in ipairs(words) do
    local pos = text:find("%f[%a]" .. w:lower())
    if pos and (not bestPos or pos < bestPos) then best, bestPos = w, pos end
  end
  return best
end

local function mentions(t, phrase) return t:find("%f[%a]" .. phrase) ~= nil end

-- "never sell below 20", "not under 20", "minimum 20": the number after the first lead that has one (not a percentage).
local MIN_PRICE_LEADS = { "never sell below", "not sell below", "not under", "minimum price", "minimum" }
local function minPriceIn(t)
  for _, lead in ipairs(MIN_PRICE_LEADS) do
    local n, pct = t:match(lead .. "%s+(%d+%.?%d*)(%%?)")
    if n and pct ~= "%" then return tonumber(n) end
  end
end

local BUYER_WORDS = { { "orbis", "orbis" }, { "halcyon", "halcyon" }, { "meridian", "meridian" }, { "hmc", "hmc" },
  { "corporation", "hmc" }, { "depot", "hmc" } }
local function buyerIn(t)
  local best, bestPos
  for _, w in ipairs(BUYER_WORDS) do
    local pos = t:find("%f[%a]" .. w[1])
    if pos and (not bestPos or pos < bestPos) then best, bestPos = w[2], pos end
  end
  return best
end

-- What one unit would fetch at `buyer` for the hold of `ship`, now (nil when it cannot be told).
local function unitPrice(sim, ship, buyer)
  local ore = ship.ore
  if not ore or not World.ores[ore] then return nil end
  if buyer ~= "hmc" then return Market.price(sim.market, buyer, ore) end
  local planet = sim.planets[ship.at]
  return planet and planet.depotRate * World.ores[ore].basePrice or nil
end

-- Spec §10.5: a deterministic keyword interpreter. What the order and the directive leave open is picked from the
-- sim's stub stream, so a vague prompt wanders (random ore, random hold %) and a precise one works well.
-- The order is read first, so it wins over the directive. Policy, top to bottom: scan, run a named skill, store or sell a
-- held cargo, mine. A Miner only decides while docked, so "return(to)" rides on the mine call as `to` and the sim issues
-- the return itself when the hold reaches the threshold. Every call carries the `reasoning` that says what was read
-- from the text and what was picked at random.
function Ai.minerDirective(sim, agentId, ctx)
  local agent = sim.agents[agentId]
  local texts = { (agent.order or ""):lower(), (agent.directive or ""):lower() }
  local function first(fn)
    for _, t in ipairs(texts) do
      local v = fn(t)
      if v ~= nil then return v end
    end
  end
  local cfg = AiConfig.stub
  local rand = sim.randStub
  local ship = ctx.ship
  local notes = {}
  local function note(text) notes[#notes + 1] = text end
  local function done(call)
    local text = table.concat(notes, ", ")
    call.reasoning = (text:sub(1, 1):upper() .. text:sub(2)):sub(1, AiConfig.reasoningMaxChars)
    return call
  end
  local function pick(list) return list[1 + math.floor(rand() * #list)] end

  -- 1. scan
  if sim:hasTool(agentId, "scan") and first(function(t) if mentions(t, "scan") then return true end end) then
    for _, pid in ipairs(World.planetOrder) do
      local p = ctx.planets[pid]
      if p and p.reachable then
        for _, v in ipairs(p.veins) do
          if not v.scanned then
            local call = { name = "scan", args = { planet = pid } }
            if sim:validate(agentId, call) then
              note("directive says scan, " .. pid .. " has unscanned veins")
              return done(call)
            end
            break
          end
        end
      end
    end
  end

  local rows = {}
  for _, pid in ipairs(World.planetOrder) do
    local p = ctx.planets[pid]
    if p and p.reachable then
      for _, v in ipairs(p.veins) do
        if not (v.reserve ~= nil and v.reserve < 1) then rows[#rows + 1] = { planet = pid, vein = v } end
      end
    end
  end
  local function rowsWhere(list, fn)
    local out = {}
    for _, r in ipairs(list) do if fn(r) then out[#out + 1] = r end end
    return out
  end
  local function oreFromText()
    local w = first(function(t) return firstWord(t, sortedKeys(World.ores)) end)
    return w
  end
  local pctValue
  local function holdPct()
    if pctValue then return pctValue end
    local v = first(function(t)
      local n = t:match("(%d+)%s*%%")
      if n then return math.max(10, math.min(100, tonumber(n))) end
    end)
    if v then note(("return at %d%%"):format(v))
    else
      v = cfg.holdPct[1] + math.floor(rand() * (cfg.holdPct[2] - cfg.holdPct[1] + 1))
      note(("no threshold given, picked %d%% at random"):format(v))
    end
    pctValue = v
    return v
  end

  -- The vein the text points at, `filter` (a skill parameter's resource / planet) narrowing the choice.
  local function chooseVein(filter)
    filter = filter or {}
    local pool = rowsWhere(rows, function(r)
      return (not filter.resource or r.vein.ore == filter.resource) and (not filter.planet or r.planet == filter.planet)
    end)
    if #pool == 0 then return nil end
    local named = first(function(t)
      for id in t:gmatch("%f[%w](%a%d)%f[%W]") do
        for _, r in ipairs(pool) do if r.vein.id:lower() == id then return r end end
      end
    end)
    if named then note("directive names vein " .. named.vein.id); return named end
    local ore = filter.resource
    if not ore then
      local w = oreFromText()
      if w and #rowsWhere(pool, function(r) return r.vein.ore == w end) > 0 then ore = w; note("directive says " .. w) end
    end
    if not ore and first(function(t) if mentions(t, "most valuable") or mentions(t, "most expensive") then return true end end) then
      local bestScore
      for _, r in ipairs(pool) do
        local score = World.ores[r.vein.ore].basePrice * ctx.planets[r.planet].depotRate
        if not bestScore or score > bestScore then ore, bestScore = r.vein.ore, score end
      end
      note("most valuable resource is " .. ore)
    end
    -- "richest" / "nearest" without a resource or planet ranges over everything reachable; a random pick is only for
    -- what the text leaves open when there is no such rule either. "best price" is about buyers, not about the vein.
    local way = first(function(t)
      t = t:gsub("best price", ""):gsub("highest price", "")
      if mentions(t, "richest") or mentions(t, "best") then return "richest" end
      if mentions(t, "nearest") or mentions(t, "closest") then return "nearest" end
    end)
    if ore then pool = rowsWhere(pool, function(r) return r.vein.ore == ore end) end
    local planet = filter.planet
    if not planet then
      planet = first(function(t)
        for _, r in ipairs(pool) do if mentions(t, r.planet:lower()) then return r.planet end end
      end)
      if planet then note("planet " .. planet) end
    end
    if planet then pool = rowsWhere(pool, function(r) return r.planet == planet end) end
    local mid = { low = 1.0, medium = 1.5, high = 2.0 }
    local choice
    if way == "richest" then
      for _, r in ipairs(pool) do
        local rich = r.vein.richness or mid[r.vein.band]
        if not choice or rich > (choice.vein.richness or mid[choice.vein.band]) then choice = r end
      end
      note("richest vein " .. choice.vein.id)
    elseif way == "nearest" then
      local function travel(r) return World.travel[ship.at][r.planet] + World.jumpSeconds * r.vein.jumps end
      for _, r in ipairs(pool) do if not choice or travel(r) < travel(choice) then choice = r end end
      note("nearest vein " .. choice.vein.id)
    else
      -- one draw over the veins left open, so the odds stay per vein
      choice = #pool == 1 and pool[1] or pick(pool)
      local open = {}
      if not ore then open[#open + 1] = "resource" end
      if not planet then open[#open + 1] = "planet" end
      if #open == 0 then open[1] = "vein" end
      note("no " .. table.concat(open, " or ") .. " given, picked " .. choice.vein.id .. " at random")
    end
    return choice
  end

  -- Where the hold goes: "sell locally" / "local depot" or "home" / "warehouse" / "bring back"; storing or selling to
  -- the Orbis post needs the home dock, so those imply it.
  local intent = first(function(t)
    if mentions(t, "store") then return "store" end
    if mentions(t, "sell") or buyerIn(t) then return "sell" end
    if mentions(t, "warehouse") then return "store" end
  end)
  local namedBuyer = first(buyerIn)
  local function dockChoice()
    local dock = first(function(t)
      if mentions(t, "sell locally") or mentions(t, "local depot") then return "local_depot" end
      if mentions(t, "home") or mentions(t, "warehouse") or mentions(t, "bring back") then return "home" end
    end)
    if dock then note("dock at " .. (dock == "home" and "home" or "the local depot")); return dock end
    if intent == "store" or namedBuyer == "orbis" then
      note("storing or selling at Orbis needs the home dock")
      return "home"
    end
    dock = pick({ "home", "local_depot" })
    note("no dock given, picked " .. dock .. " at random")
    return dock
  end

  -- 2. a named skill
  if sim:hasTool(agentId, "run_skill") then
    local named
    for _, name in ipairs(Skills.names(sim)) do
      local skill = sim.skills[name]
      if skill.agent_type == agent.type then
        local n = name:lower()
        for _, t in ipairs(texts) do
          if (t:find("use skill " .. n, 1, true) or t:find("run " .. n, 1, true)) and (not named or #name > #named) then named = name end
        end
        if named then break end
      end
    end
    if named then
      local params = {}
      local usable = true
      for _, pname in ipairs(sortedKeys(sim.skills[named].params or {})) do
        local decl = sim.skills[named].params[pname]
        if decl.kind == "vein" then
          local r = chooseVein(decl.filter)
          if r then params[pname] = r.vein.id else usable = false end
        elseif decl.kind == "resource" then
          params[pname] = oreFromText()
          usable = usable and params[pname] ~= nil
        elseif decl.kind == "pct" then params[pname] = holdPct()
        elseif decl.kind == "buyer" then params[pname] = namedBuyer or "hmc"
        else usable = false end
      end
      local call = { name = "run_skill", args = { name = named, params = next(params) and params or nil } }
      if usable and sim:validate(agentId, call) then
        table.insert(notes, 1, "directive says run " .. named)
        return done(call)
      end
      notes = {}
    end
  end

  -- 5. docked with cargo: store, sell at the buyer the text names (or the best / a random one) if the price is enough
  if ship.cargo > 0 and ship.ore then
    local ore = ship.ore
    if sim:storingStation(ship.at) and sim:hasTool(agentId, "store") then
      local store = intent == "store"
      if intent == nil then
        store = rand() < cfg.storeChance
        note(store and "no store or sell given, stored at random" or "no store or sell given, sold at random")
      else note(store and "directive says store" or "directive says sell") end
      if store then
        local call = { name = "store", args = { resource = ore, qty = "all" } }
        if sim:validate(agentId, call) then return done(call) end
        note("warehouse full")
      end
    end
    local function sellCall(buyer) return { name = "sell", args = { ship = ship.id, resource = ore, qty = "all", buyer = buyer } } end
    local buyer = namedBuyer
    if buyer then note("buyer " .. buyer)
    else
      local visible = {}
      for _, b in ipairs({ "hmc", "orbis" }) do if sim:validate(agentId, sellCall(b)) then visible[#visible + 1] = b end end
      if #visible == 0 then visible = { "hmc" } end
      local best = first(function(t) if mentions(t, "best price") or mentions(t, "highest price") then return true end end)
      if best then
        local top
        for _, b in ipairs(visible) do
          local price = unitPrice(sim, ship, b) or 0
          if not top or price > top then buyer, top = b, price end
        end
        note("best price is at " .. buyer)
      else
        buyer = pick(visible)
        note("no buyer given, picked " .. buyer .. " at random")
      end
    end
    local minPrice = first(minPriceIn)
    local price = unitPrice(sim, ship, buyer)
    if minPrice and price and price < minPrice then
      note(("price %.1f is below the minimum %g, waiting"):format(price, minPrice))
      return done({ name = "wait", args = { seconds = cfg.heldWaitSeconds } })
    end
    if minPrice then note(("price meets the minimum %g"):format(minPrice)) end
    return done(sellCall(buyer))
  end

  if #rows == 0 then return { name = "wait", args = { seconds = cfg.waitSeconds }, reasoning = "No known vein in range, waiting" } end

  -- 3 / 6. mine, back to the dock when the hold reaches the threshold
  local choice = chooseVein()
  local pct = holdPct()
  return done({ name = "mine", args = { vein = choice.vein.id, stop_at_hold_pct = pct, to = dockChoice() } })
end

-- Logistician stub (spec §10.5). The order, then the directive, may name an ore, a market and "sell" / "ship". Left open,
-- it picks the fullest stock of at least `minStock` and a random market that buys it, so two vague Logisticians on one
-- station pick the same stock and collide (spec §8.6). "best price" ships to the market that pays most for it. A stock
-- below `minStock` or no docked freighter: wait.
logisticianStub = function(sim, agentId, ctx)
  local agent = sim.agents[agentId]
  local texts = { (agent.order or ""):lower(), (agent.directive or ""):lower() }
  local cfg = sim.b.logistics.stub
  local function first(fn)
    for _, t in ipairs(texts) do
      local v = fn(t)
      if v ~= nil then return v end
    end
  end
  local idle = { name = "wait", args = { seconds = cfg.waitSeconds }, reasoning = "Nothing to ship or sell, waiting" }
  local goods = sortedKeys(World.ores)
  for _, g in ipairs(Refined.recipeOrder) do goods[#goods + 1] = g end
  local ore = first(function(t) return firstWord(t, goods) end)
  local market = first(function(t) return firstWord(t, World.marketOrder) end)
  local wantsSell = first(function(t) if t:find("sell", 1, true) then return true end end)
  local wantsShip = first(function(t) if t:find("ship", 1, true) then return true end end)
  local bestPrice = first(function(t) if mentions(t, "best price") or mentions(t, "highest price") then return true end end)
  local resource, have = ore, ore and ctx.stock[ore] or 0
  if not ore then
    -- refined goods first (worth more per unit), once the station holds shipMinStock of one
    for _, g in ipairs(Refined.recipeOrder) do
      local q = ctx.stock[g] or 0
      if q >= Refined.stub.shipMinStock and q > have then resource, have = g, q end
    end
    if not resource then
      for _, o in ipairs(World.oreOrder) do
        local q = ctx.stock[o] or 0
        if q >= cfg.minStock and q > have then resource, have = o, q end
      end
    end
  end
  if not resource or have < 1 then return idle end
  local cargo = sim.b.freighter.cargo
  local refined = Refined.recipes[resource] ~= nil
  if refined and wantsSell and not wantsShip and ctx.station.kind == "main" and Market.has(sim.market, "orbis", resource) then
    return { name = "sell", args = { resource = resource, qty = "all", buyer = "orbis" }, reasoning = "Directive says sell, " .. resource .. " goes to orbis" }
  end
  if wantsSell and not wantsShip and not refined and market ~= "halcyon" and market ~= "meridian" then
    local buyer = (market == "orbis" and ctx.station.kind == "main") and "orbis" or "hmc"
    return { name = "sell", args = { resource = resource, qty = "all", buyer = buyer }, reasoning = "Directive says sell, " .. resource .. " goes to " .. buyer }
  end
  local docked = false
  for _, f in ipairs(ctx.freighters) do if f.state == "docked" then docked = true end end
  if not docked then return idle end
  local dest, why = market, nil
  if dest then why = "directive names " .. dest
  elseif bestPrice then
    local listed = {}
    for _, m in ipairs(ctx.markets) do listed[m] = true end
    local top = Market.best(sim.market, resource, function(m) return listed[m] end)
    if top then dest, why = top, "best price for " .. resource .. " is at " .. top end
  end
  if not dest then
    local pool = {}
    for _, m in ipairs(ctx.markets) do
      if Market.has(sim.market, m, resource) then pool[#pool + 1] = m end
    end
    if #pool == 0 then return idle end
    dest = pool[1 + math.floor(sim.randStub() * #pool)]
    why = "no destination given, picked " .. dest .. " at random"
  end
  local qty = math.min(have, cargo)
  return { name = "ship", args = { resource = resource, qty = qty, destination = dest },
    reasoning = ((ore and "directive says " .. resource or "fullest stock is " .. resource) .. ", " .. why):gsub("^%l", string.upper) }
end

-- Spec §10.5 for the Monitor: a keyword interpreter over its order and directive, acting on the oldest queued alert.
-- What the text leaves open is picked from the stub stream; with no alert it waits.
local function parseParams(text)
  local out = {}
  for k, v in tostring(text or ""):gmatch("([%w_]+)=([^,]+)") do out[k] = tonumber(v) or v end
  return out
end

-- Veins another ship is on or heading to (the target's own ship does not count: it is the one being moved).
local function veinsInUse(sim, target)
  local used = {}
  local own = target.type == "miner" and sim:ownedShip(target.id) or nil
  for _, sid in ipairs(sim.shipOrder) do
    local ship = sim.ships[sid]
    if ship ~= own and ship.vein and (ship.state == "travel_out" or ship.state == "mining") then used[ship.vein.id] = true end
  end
  return used
end

-- Best vein for a `vein` parameter: not excluded, not depleted, not used by another ship, the highest reserve percent
-- (unscanned counts as 50). `ore` (the depleted vein's resource) is preferred; any other fitting vein is the fallback.
local function bestVein(ctx, decl, exclude, reach, used, ore)
  local f, best, bestPct = decl.filter or {}, { nil, nil }, { -1, -1 }
  for _, v in ipairs(ctx.veins) do
    local pct = v.pct or 50
    if v.id ~= exclude and not used[v.id] and pct > 0 and reach(v) and (not f.resource or v.ore == f.resource) and (not f.planet or v.planet == f.planet) then
      local slot = (ore and v.ore == ore) and 1 or 2
      if pct > bestPct[slot] then best[slot], bestPct[slot] = v.id, pct end
    end
  end
  return best[1] or best[2]
end

-- Parameter values for `skill` with every vein parameter on a fresh vein the target can reach; nil when another kind cannot be filled in.
local function rotatedParams(sim, ctx, skill, known, depleted, target)
  local params = {}
  local ship = target.type == "miner" and sim:ownedShip(target.id) or nil
  local function reach(v) return not ship or sim:inRange(ship, v.planet) end
  local used = veinsInUse(sim, target)
  local ore
  for _, v in ipairs(ctx.veins) do if v.id == depleted then ore = v.ore end end
  for name, decl in pairs(skill.params or {}) do
    if decl.kind == "vein" then
      params[name] = bestVein(ctx, decl, depleted, reach, used, ore)
      if not params[name] then return nil end
    elseif known[name] ~= nil then
      params[name] = known[name]
    else
      return nil
    end
  end
  return params
end

local ASSIGN_ALERTS = { skill_aborted = true, no_compute = true, agent_idle = true }

function monitorStub(sim, agentId, ctx)
  local agent = sim.agents[agentId]
  local wait = { name = "wait", args = { seconds = sim.b.monitor.stubWaitSeconds }, reasoning = "No alert, waiting" }
  local alert = ctx.alerts[1]
  if not alert or not alert.agent or not sim.agents[alert.agent] then return wait end
  local target = sim.agents[alert.agent]
  local texts = { (agent.order or ""):lower(), (agent.directive or ""):lower() }
  local function has(...)
    for _, t in ipairs(texts) do
      for _, w in ipairs({ ... }) do if t:find(w, 1, true) then return true end end
    end
    return false
  end
  local known = parseParams(alert.params)
  local depleted = known.vein
  local function with(call, why)
    call.reasoning = why
    return call
  end

  if has("resume", "restart", "unstick") and alert.type == "agent_paused" then
    return with({ name = "resume_agent", args = { agent = target.id } }, "Directive says resume, " .. target.id .. " is paused")
  end
  local rotate = has("next vein", "another vein", "rotate")
  if (rotate or has("skill", "switch", "reassign")) and ASSIGN_ALERTS[alert.type] then
    if rotate and alert.skill and sim.skills[alert.skill] then
      local params = rotatedParams(sim, ctx, sim.skills[alert.skill], known, depleted, target)
      if params then
        return with({ name = "assign_skill", args = { agent = target.id, skill = alert.skill, params = params } },
          "Directive says rotate, " .. alert.skill .. " moves to a free vein")
      end
    end
    local names = {}
    for _, name in ipairs(Skills.names(sim)) do
      if name ~= alert.skill then names[#names + 1] = name end
    end
    if alert.skill and sim.skills[alert.skill] then names[#names + 1] = alert.skill end -- the aborted one, last
    for _, name in ipairs(names) do
      local skill = sim.skills[name]
      if skill.agent_type == target.type then
        local params = rotatedParams(sim, ctx, skill, known, depleted, target)
        if params then
          return with({ name = "assign_skill", args = { agent = target.id, skill = name, params = params } },
            "Directive says reassign, " .. alert.type .. " on " .. target.id .. " gets " .. name)
        end
      end
    end
  end
  if has("order", "tell") then
    return with({ name = "set_order", args = { agent = target.id, text = sim.b.monitor.stubOrder:format(alert.reason) } },
      "Directive says order, " .. target.id .. " is told to choose another option")
  end
  if has("pause") and has("losing") and alert.type == "losing_money" then
    return with({ name = "pause_agent", args = { agent = target.id } }, "Directive says pause, " .. target.id .. " is losing money")
  end
  local options = {
    { name = "set_order", args = { agent = target.id, text = sim.b.monitor.stubOrder:format(alert.reason) } },
    { name = "resume_agent", args = { agent = target.id } },
    { name = "pause_agent", args = { agent = target.id } },
    wait,
  }
  local valid = {}
  for _, call in ipairs(options) do if sim:validate(agentId, call) then valid[#valid + 1] = call end end
  local call = valid[1 + math.floor(sim.randStub() * #valid)]
  return with({ name = call.name, args = call.args }, "Directive covers nothing for " .. alert.type .. ", picked " .. call.name .. " at random")
end

-- Shared agent types have their stub here; a branch's agent type brings its own (registry.agentTypes[type].stub).
local function dispatch(sim, agentId, ctx, which)
  local kind = sim.agents[agentId].type
  if kind == "logistician" then return logisticianStub(sim, agentId, ctx) end
  if kind == "monitor" then return monitorStub(sim, agentId, ctx) end
  local t = sim.registry.agentTypes[kind]
  local hook = t and t.stub and t.stub[which]
  if hook then return hook(sim, agentId, ctx) end
  return { name = "report", args = { message = "idle" } }
end

local function optimal(sim, agentId, ctx) return dispatch(sim, agentId, ctx, "optimal") end
local function directiveStub(sim, agentId, ctx) return dispatch(sim, agentId, ctx, "directive") end

-- Deliberately vague: sometimes emits invalid calls, to exercise validation.
local function vague(sim, agentId, ctx)
  if sim.rand() < sim.b.ai.vagueErrorRate then
    local bad = { { name = "dig", args = {} }, { name = "mine", args = { vein = "K99" } }, { name = "scan", args = { planet = "kessa" } },
      { name = "mine", args = { vein = "A1" } } }
    return bad[1 + math.floor(sim.rand() * #bad)]
  end
  return optimal(sim, agentId, ctx)
end

-- The returned module table is read-only, so the mode lives in a local behind a setter.
function Ai.setMode(m)
  assert(m == "stub" or m == "optimal" or m == "vague", "Ai.setMode: unknown mode " .. tostring(m))
  mode = m
end

function Ai.register(name, decide)
  assert(name ~= "stub" and type(decide) == "function", "Ai.register: needs a name other than 'stub' and a function")
  providers[name] = decide
end

-- Debug panel / config switch (spec §10.1). Returns ok, err; an unregistered provider leaves the current one in place.
function Ai.use(name)
  if name ~= "stub" and not providers[name] then return false, "provider_unavailable: " .. tostring(name) end
  provider = name
  return true
end

function Ai.provider() return provider end

function Ai.decide(sim, agentId, ctx)
  if provider ~= "stub" then return providers[provider](sim, agentId, ctx) end
  if mode == "vague" then return vague(sim, agentId, ctx) end
  if mode == "stub" then return directiveStub(sim, agentId, ctx) end
  return optimal(sim, agentId, ctx)
end

return Ai
