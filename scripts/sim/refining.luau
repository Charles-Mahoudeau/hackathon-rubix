-- Refining (spec §15b.2, B-b): refineries on stations, one job at a time from the station stock, the Refiner agent's tools, the
-- margins table, mission V1 and the stub Refiner. Pure sim logic, headless: no UI calls; the UI reads `sim.refining` and events.
-- Numbers: config/branches.luau `refining`. No randomness of its own (the stub draws from the sim's stub stream).
-- State: sim.refining = { refineries = { [station] = { station, mk2, owner, job, feedEntry, recordId } }, order = { station, ... },
--   mission = { status, units } }. job = { recipe, qty, left, total, pending, blocked }.
local World = require("@scripts/config/world")
local Cfg = require("@scripts/config/branches").refining
local SalvageCfg = require("@scripts/config/branches").salvage
local Feed = require("./feed")
local Market = require("./market")
local Logistics = require("./logistics")

local Refining = {}

Refining.goods = Cfg.recipeOrder

function Refining.isGood(resource) return Cfg.recipes[resource or ""] ~= nil end

function Refining.init(sim)
  sim.refining = { refineries = {}, order = {}, mission = { status = "locked", units = 0 } }
end

local function open(sim) return sim.branchesOpen.refining == true end
function Refining.isOpen(sim) return open(sim) end

-- Seconds one output unit takes at this refinery (Mk2 is faster).
-- Salvage blueprints each add a speed bonus (read straight from sim.salvage: this module must not require sim/salvage).
local function unitSeconds(sim, ref, recipe)
  local bp = sim.salvage and sim.salvage.bonuses.refinerySpeed or 0
  return Cfg.recipes[recipe].time / ((ref.mk2 and Cfg.mk2.speed or 1) * (1 + bp * SalvageCfg.blueprint.refinerySpeed))
end

-- Base value of the inputs of one output unit.
function Refining.inputValue(recipe)
  local v = 0
  for ore, n in pairs(Cfg.recipes[recipe].inputs) do v += n * World.ores[ore].basePrice end
  return v
end

-- Refineries ---------------------------------------------------------------------------------------------------------

function Refining.refineryAt(sim, stationId) return sim.refining.refineries[stationId or ""] end

function Refining.refineryFor(sim, agentId)
  for _, sid in ipairs(sim.refining.order) do
    local ref = sim.refining.refineries[sid]
    if ref.owner == agentId then return ref end
  end
  return nil
end

function Refining.refineries(sim)
  local out = {}
  for _, sid in ipairs(sim.refining.order) do out[#out + 1] = sim.refining.refineries[sid] end
  return out
end

function Refining.addRefinery(sim, stationId, owner)
  local ref = { station = stationId, mk2 = false, owner = owner, job = nil, feedEntry = nil }
  sim.refining.refineries[stationId] = ref
  sim.refining.order[#sim.refining.order + 1] = stationId
  return ref
end

-- Every station lists the refined goods in its stock (0 each), so the Logistician tools find the keys.
function Refining.ensureStock(sim)
  for _, sid in ipairs(sim.stationOrder) do
    local stock = sim.stations[sid].stock
    for _, good in ipairs(Cfg.recipeOrder) do
      if stock[good] == nil then stock[good] = 0 end
    end
  end
end

local function nextAgentId(sim)
  local n, id = 1, "refiner"
  while sim.agents[id] do n += 1; id = "refiner_" .. n end
  return id
end

-- A Refiner for a refinery nobody runs, once the command capacity has room (spec §5.3).
function Refining.claim(sim)
  for _, sid in ipairs(sim.refining.order) do
    local ref = sim.refining.refineries[sid]
    if not ref.owner and #sim.agentOrder < sim:commandCapacity() then
      local id = nextAgentId(sim)
      sim:addAgent(id, "refiner", { tier = sim.tier, station = sid })
      ref.owner = id
      sim:log("INFO", ("%s: new Refiner agent for the refinery at %s (empty directive)"):format(id, sid))
      sim:emit("agent_added", { agent = id, station = sid })
    end
  end
end

-- Shop: refineries on further stations and Mk2 upgrades, listed once the branch is open ----------------------------------

-- "refinery:<station>" | "refinery_mk2:<station>" -> { kind, station } | nil
function Refining.shopItem(id)
  local kind, station = tostring(id):match("^(refinery[_%w]*):(%w+)$")
  if kind == "refinery" or kind == "refinery_mk2" then return { kind = kind, station = station } end
  return nil
end

function Refining.shopBlocker(sim, id)
  local it = Refining.shopItem(id)
  if not it or not open(sim) then return "unknown_item" end
  if not sim.stations[it.station] then return "unknown_station" end
  local ref = Refining.refineryAt(sim, it.station)
  if it.kind == "refinery" then
    if ref then return "already_owned" end
    if sim.resources.credits < Cfg.extraCost then return "not_enough_credits" end
  else
    if not ref then return "needs_refinery" end
    if ref.mk2 then return "already_owned" end
    if sim.resources.credits < Cfg.mk2.cost then return "not_enough_credits" end
  end
  return nil
end

function Refining.shopRows(sim)
  local rows = {}
  if not open(sim) then return rows end
  for _, sid in ipairs(sim.stationOrder) do
    local ref = Refining.refineryAt(sim, sid)
    local label = Logistics.label(sim.stations[sid])
    local function add(id, name, desc, cost)
      local why = Refining.shopBlocker(sim, id)
      local state = "available"
      if why == "already_owned" then state = "owned"
      elseif why == "not_enough_credits" then state = "unaffordable"
      elseif why then state = "locked" end
      rows[#rows + 1] = { id = id, name = name, desc = desc, cost = cost, state = state, blocker = why, tier = sim.tier }
    end
    if not ref then
      add("refinery:" .. sid, "Refinery " .. label, "A refinery here and an empty Refiner agent", Cfg.extraCost)
    else
      add("refinery_mk2:" .. sid, "Refinery Mk2 " .. label, ("x%d refining speed"):format(Cfg.mk2.speed), Cfg.mk2.cost)
    end
  end
  return rows
end

function Refining.shopBuy(sim, id)
  local why = Refining.shopBlocker(sim, id)
  if why then
    sim:log("ERROR", ("shop: cannot buy %s (%s)"):format(tostring(id), why))
    return false, why
  end
  local it = Refining.shopItem(id)
  if it.kind == "refinery" then
    sim.resources.credits -= Cfg.extraCost
    Refining.addRefinery(sim, it.station, nil)
    Refining.claim(sim)
    sim:log("INFO", ("shop: bought a refinery at %s for %d cr"):format(it.station, Cfg.extraCost))
  else
    sim.resources.credits -= Cfg.mk2.cost
    Refining.refineryAt(sim, it.station).mk2 = true
    sim:log("INFO", ("shop: refinery at %s upgraded to Mk2 for %d cr"):format(it.station, Cfg.mk2.cost))
  end
  sim:emit("upgrade_bought", { id = id })
  return true
end

-- Branch opening: the first refinery stands on the main station (spec §15b.2).
function Refining.onOpen(sim)
  Market.addRefined(sim.market)
  Refining.addRefinery(sim, sim.home, nil)
  Refining.ensureStock(sim)
  local id = nextAgentId(sim)
  sim:addAgent(id, "refiner", { tier = sim.tier, station = sim.home })
  Refining.refineryAt(sim, sim.home).owner = id
  sim.refining.mission.status = "active"
end

-- Mission V1 ---------------------------------------------------------------------------------------------------------

-- -> { id, name, goal, hint, reward, status = locked|active|complete|claimed, units, target }
function Refining.mission(sim)
  local e, d = sim.refining.mission, Cfg.mission
  return { id = d.id, name = d.name, goal = d.goal, hint = d.hint, reward = d.reward, status = e.status, units = e.units, target = d.units }
end

-- A refined good was sold at `unit` credits each: it counts when that is at least margin x the base value of its inputs.
function Refining.onSale(sim, resource, qty, unit)
  local e = sim.refining and sim.refining.mission
  if not e or e.status ~= "active" or not Refining.isGood(resource) then return end
  if unit >= Cfg.mission.margin * Refining.inputValue(resource) then
    e.units += qty
    if e.units >= Cfg.mission.units then
      e.status = "complete"
      sim:log("INFO", ("mission %s complete"):format(Cfg.mission.id))
      sim:emit("mission_complete", { id = Cfg.mission.id })
    end
  end
end

function Refining.claimMission(sim)
  local e = sim.refining and sim.refining.mission
  if not e or e.status == "claimed" then return false, "already_claimed" end
  if e.status ~= "complete" then return false, "not_complete" end
  sim.resources.credits += Cfg.mission.reward
  e.status = "claimed"
  sim:log("INFO", ("mission %s claimed: +%d cr"):format(Cfg.mission.id, Cfg.mission.reward))
  sim:emit("mission_claimed", { id = Cfg.mission.id, reward = { credits = Cfg.mission.reward } })
  return true, { credits = Cfg.mission.reward }
end

-- Margins and prices -------------------------------------------------------------------------------------------------

-- What one unit of `ore` is worth sold raw: the HMC depot at the station's planet or the best market price, whichever is more.
local function rawValue(sim, ore, planet)
  local best = sim.planets[planet].depotRate * World.ores[ore].basePrice
  for _, mid in ipairs(World.marketOrder) do
    if sim:marketUnlocked(mid) then
      local p = Market.price(sim.market, mid, ore)
      if p and p > best then best = p end
    end
  end
  return best
end

-- Best unlocked market for a refined good: market id, price.
local function bestMarket(sim, good)
  local bid, best = nil, -1
  for _, mid in ipairs(World.marketOrder) do
    if sim:marketUnlocked(mid) then
      local p = Market.price(sim.market, mid, good)
      if p and p > best then bid, best = mid, p end
    end
  end
  return bid, best
end

-- Per recipe: the best market that buys it and what one unit earns over the inputs sold raw instead. Recipes no unlocked market buys are left out.
-- -> { { recipe, best_market, margin_per_unit }, ... } in recipe order
function Refining.margins(sim, stationId)
  local planet = (sim.stations[stationId or sim.home] or sim.stations[sim.home]).planet
  local out = {}
  for _, good in ipairs(Cfg.recipeOrder) do
    local mid, price = bestMarket(sim, good)
    if mid then
      local cost = 0
      for ore, n in pairs(Cfg.recipes[good].inputs) do cost += n * rawValue(sim, ore, planet) end
      out[#out + 1] = { recipe = good, best_market = mid, margin_per_unit = Market.round1(price - cost) }
    end
  end
  return out
end

-- Current prices of raw and refined goods on the unlocked markets: market -> good -> price.
function Refining.prices(sim)
  local out = {}
  for _, mid in ipairs(World.marketOrder) do
    if sim:marketUnlocked(mid) then
      local p = {}
      for _, good in ipairs(World.oreOrder) do
        local v = Market.price(sim.market, mid, good)
        if v then p[good] = Market.round1(v) end
      end
      for _, good in ipairs(Cfg.recipeOrder) do
        local v = Market.price(sim.market, mid, good)
        if v then p[good] = Market.round1(v) end
      end
      out[mid] = p
    end
  end
  return out
end

-- Tools ----------------------------------------------------------------------------------------------------------------

-- Units of `recipe` the station stock can make now.
local function makeable(st, recipe)
  local n = math.huge
  for ore, per in pairs(Cfg.recipes[recipe].inputs) do n = math.min(n, math.floor((st.stock[ore] or 0) / per)) end
  return n == math.huge and 0 or n
end

function Refining.validate(sim, agent, n, args)
  local ref = Refining.refineryFor(sim, agent.id)
  if not ref then return false, "no_refinery" end
  if n == "report" then
    if args.to ~= nil and args.to ~= "player" then
      if args.to == agent.id or type(args.to) ~= "string" or not sim.agents[args.to] then return false, "unknown_recipient" end
    end
    return true
  elseif n == "wait" then
    local s = args.seconds
    if type(s) ~= "number" or s < sim.b.waitMinSeconds or s > sim.b.waitMaxSeconds then return false, "bad seconds" end
    return true
  elseif n == "refine" then
    if not Cfg.recipes[args.recipe or ""] then return false, "bad recipe" end
    local q = args.qty
    if type(q) ~= "number" or q ~= math.floor(q) or q < Cfg.qtyMin or q > Cfg.qtyMax then return false, "bad qty" end
    if ref.job then return false, ref.job.blocked and "station_full" or "refinery_busy" end
    if makeable(sim.stations[ref.station], args.recipe) < q then return false, "not_enough_input" end
  end
  return true
end

local function finishEntry(sim, ref, text, ok)
  local e = ref.feedEntry
  if e and e.status == "running" then Feed.finish(sim, e, text, ok) end
  ref.feedEntry = nil
end

-- opts.record: the decision-log record id; opts.auto: no feed line.
function Refining.apply(sim, agentId, call, opts)
  local ref = Refining.refineryFor(sim, agentId)
  local n, args = call.name, call.args or {}
  local rid = opts and opts.record
  if n == "wait" then
    sim.agents[agentId].waitUntil = sim.tick + sim:ticks(args.seconds)
    Feed.finish(sim, Feed.begin(sim, agentId, call, sim:takeReasoning(), rid), "waiting")
    return true
  elseif n == "report" then
    local entry = Feed.begin(sim, agentId, call, sim:takeReasoning(), rid)
    sim:log("INFO", agentId .. " report: " .. tostring(args.message))
    Feed.finish(sim, entry, "sent")
    if args.to ~= nil and args.to ~= "player" then sim:deliver(args.to, ("from %s: %s"):format(agentId, tostring(args.message)))
    else Feed.info(sim, agentId, tostring(args.message)) end
    return true
  end
  -- refine: the inputs leave the stock now, the output arrives when the job ends
  local st = sim.stations[ref.station]
  local used = {}
  for ore, per in pairs(Cfg.recipes[args.recipe].inputs) do
    used[ore] = per * args.qty
    st.stock[ore] -= used[ore]
  end
  local total = math.max(1, sim:ticks(args.qty * unitSeconds(sim, ref, args.recipe)))
  ref.job = { recipe = args.recipe, qty = args.qty, left = total, total = total, inputs = used }
  ref.feedEntry, ref.recordId = Feed.begin(sim, agentId, call, sim:takeReasoning(), rid), rid
  sim:log("INFO", ("%s refines %d %s at %s"):format(agentId, args.qty, args.recipe, ref.station))
  return true, { inputs_used = used }
end

-- Per tick ---------------------------------------------------------------------------------------------------------

local function deposit(sim, ref)
  local job = ref.job
  local st = sim.stations[ref.station]
  local amt = math.min(job.pending, math.max(0, Logistics.room(sim, st)))
  st.stock[job.recipe] += amt
  job.pending -= amt
  if job.pending > 0 then
    job.blocked = true
    return
  end
  local text = ("+%d %s"):format(job.qty, job.recipe)
  sim:log("INFO", ("refinery %s: %d %s done"):format(ref.station, job.qty, job.recipe))
  sim:emit("refined", { station = ref.station, recipe = job.recipe, qty = job.qty })
  ref.job = nil
  finishEntry(sim, ref, text)
end

function Refining.step(sim)
  if not open(sim) then return end
  for _, sid in ipairs(sim.refining.order) do
    local ref = sim.refining.refineries[sid]
    local job = ref.job
    if job then
      if job.pending then
        deposit(sim, ref)
      else
        job.left -= 1
        if job.left <= 0 then
          job.pending = job.qty
          deposit(sim, ref)
        end
      end
    end
  end
  Refining.claim(sim)
end

-- Agent hooks (skill runner, decisions) ----------------------------------------------------------------------------

function Refining.busy(sim, agent)
  local ref = Refining.refineryFor(sim, agent.id)
  return ref ~= nil and ref.job ~= nil
end

-- A skill step with nothing to do is skipped instead of aborting the skill. -> reason | nil
function Refining.skip(sim, agent, call)
  local ref = Refining.refineryFor(sim, agent.id)
  if not ref or call.name ~= "refine" then return nil end
  local recipe, q = call.args.recipe, call.args.qty
  if Cfg.recipes[recipe or ""] and type(q) == "number" and not ref.job and makeable(sim.stations[ref.station], recipe) < q then
    return "not enough input"
  end
  return nil
end

function Refining.needsDecision(sim, agent)
  local ref = Refining.refineryFor(sim, agent.id)
  if not ref then return false end
  return ref.job == nil and sim.tick >= (agent.waitUntil or 0)
end

-- Detached snapshot for the decider and the context builder.
function Refining.context(sim, agent)
  local ref = Refining.refineryFor(sim, agent.id)
  local st = sim.stations[ref.station]
  local stock = {}
  for k, v in pairs(st.stock) do stock[k] = v end
  local recipes = {}
  for _, good in ipairs(Cfg.recipeOrder) do
    local r = Cfg.recipes[good]
    local inputs = {}
    for ore, per in pairs(r.inputs) do inputs[ore] = per end
    recipes[#recipes + 1] = { name = good, inputs = inputs, output = good, time_s = unitSeconds(sim, ref, good), can_make = makeable(st, good) }
  end
  local job
  if ref.job then
    job = { recipe = ref.job.recipe, qty = ref.job.qty, left_s = math.ceil(ref.job.left * sim.b.tickSeconds), blocked = ref.job.blocked == true }
  end
  return {
    tick = sim.tick,
    resources = { credits = sim.resources.credits, compute = sim.resources.compute },
    home = sim.home,
    station = { id = ref.station, label = Logistics.label(st), cap = Logistics.storageCap(sim, st), used = Logistics.used(st) },
    refinery = { station = ref.station, mk2 = ref.mk2, state = job and (job.blocked and "blocked" or "refining") or "idle", job = job },
    stock = stock,
    recipes = recipes,
    prices = Refining.prices(sim),
    margins = Refining.margins(sim, ref.station),
  }
end

-- Stub Refiner (spec §15b.6) -----------------------------------------------------------------------------------------

local function firstNumber(texts)
  for _, t in ipairs(texts) do
    local v = t:match("(%d+)")
    if v then return tonumber(v) end
  end
  return nil
end

local BEST_WORDS = { "best margin", "most profitable", "highest margin", "best price", "most profit" }

-- What the order and the directive say: a recipe, "best margin" wording, a quantity (nil = not said).
local function policyOf(agent)
  local texts = { (agent.order or ""):lower(), (agent.directive or ""):lower() }
  local p = {}
  for _, t in ipairs(texts) do
    for _, good in ipairs(Cfg.recipeOrder) do
      if not p.recipe and t:find("%f[%a]" .. good) then p.recipe = good end
    end
    for _, w in ipairs(BEST_WORDS) do
      if t:find(w, 1, true) then p.best = true end
    end
  end
  p.qty = firstNumber(texts)
  return p
end

local function clampQty(q) return math.max(Cfg.qtyMin, math.min(Cfg.qtyMax, q)) end

-- The settings that put margins or prices in the agent's context (the stub reads them as the AI would).
local function seesPrices(agent)
  local s = agent.contextSettings or {}
  return s.margins == true or s.prices_orbis == true or s.prices_halcyon == true or s.prices_meridian == true
end

local function decide(sim, agent, ctx, p)
  local c = Cfg.stub
  local function wait() return { name = "wait", args = { seconds = math.max(sim.b.waitMinSeconds, math.min(sim.b.waitMaxSeconds, c.waitSeconds)) } } end
  local can = {}
  for _, r in ipairs(ctx.recipes) do can[r.name] = r.can_make end
  local function refine(recipe, want)
    local q = clampQty(math.min(want or Cfg.stub.randQtyMax, can[recipe]))
    if can[recipe] < 1 then return nil end
    return { name = "refine", args = { recipe = recipe, qty = math.min(q, can[recipe]) } }
  end
  local function quantity()
    if p.qty then return p.qty end
    return c.randQtyMin + math.floor(sim.randStub() * (c.randQtyMax - c.randQtyMin + 1))
  end
  if ctx.refinery.state ~= "idle" then return wait() end
  if p.recipe then return refine(p.recipe, quantity()) or wait() end
  if p.best and (p.optimal or seesPrices(agent)) then
    local best
    for _, m in ipairs(ctx.margins) do
      if can[m.recipe] >= 1 and (not best or m.margin_per_unit > best.margin_per_unit) then best = m end
    end
    if best and best.margin_per_unit > 0 then return refine(best.recipe, p.optimal and Cfg.qtyMax or quantity()) or wait() end
    return wait()
  end
  local options = {}
  for _, good in ipairs(Cfg.recipeOrder) do if can[good] >= 1 then options[#options + 1] = good end end
  if #options == 0 then return wait() end
  local pick = options[1 + math.floor(sim.randStub() * #options)]
  return refine(pick, quantity()) or wait()
end

function Refining.stubDirective(sim, agentId, ctx)
  local agent = sim.agents[agentId]
  return decide(sim, agent, ctx, policyOf(agent))
end

function Refining.stubOptimal(sim, agentId, ctx)
  return decide(sim, sim.agents[agentId], ctx, { best = true, optimal = true })
end

return Refining
