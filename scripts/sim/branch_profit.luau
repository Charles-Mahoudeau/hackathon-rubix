-- Branch profitability harness (GR5-64): Salvage, Refining and Raiding measured against a mining-only control on the same seed,
-- tier, assets and game time. Pure sim, headless, deterministic per seed; tools/branch_report.luau turns it into the report.
-- An arm = the pacing player replayed to the fork, a credit grant, the branch (or its control setup), a frozen shop, a window.
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Clock = require("@scripts/sim/clock")
local Pacing = require("@scripts/sim/pacing")
local Market = require("@scripts/sim/market")
local Refining = require("@scripts/sim/refining")
local Skills = require("@scripts/sim/skills")
local Compute = require("@scripts/sim/compute")
local World = require("@scripts/config/world")
local Branches = require("@scripts/config/branches")
local Cfg = require("@scripts/config/branch_profit")

local Profit = {}

local BRANCH_AGENT = { salvage = "scavenger", refining = "refiner", raiding = "privateer" }
local MISSION = { salvage = "V2", refining = "V1", raiding = "V3" }

local function missionStatus(sim, branch)
  if branch == "salvage" then return sim.salvage.mission.status end
  if branch == "refining" then return sim.refining.mission.status end
  if branch == "raiding" then return sim.raid.mission.status end
  return nil
end

-- What the company holds is worth if sold now (Compute at its pack price): ore at the HMC rate of the home planet, refined goods at the best unlocked market price
-- (depth ignored). Ship holds and freighter loads count, so cargo in transit at the window's end is not lost.
local function worth(sim, good, qty)
  if qty <= 0 then return 0 end
  local ore = World.ores[good]
  if ore then return qty * ore.basePrice * sim.planets[sim.home].depotRate end
  if Refining.isGood(good) then
    local mid, price = Market.best(sim.market, good, function(id) return sim:marketUnlocked(id) end)
    return mid and qty * price or 0
  end
  return 0
end

local function stockValue(sim)
  local total = sim.resources.compute * sim.compute.cfg.compute.priceCredits
  for _, sid in ipairs(sim.stationOrder) do
    for good, qty in pairs(sim.stations[sid].stock) do total += worth(sim, good, qty) end
  end
  for _, f in ipairs(sim.freighters) do
    if f.load then total += worth(sim, f.load.resource, f.load.qty) end
  end
  for _, id in ipairs(sim.shipOrder) do
    local ship = sim.ships[id]
    if ship.ore and ship.cargo > 0 then total += worth(sim, ship.ore, ship.cargo) end
  end
  return total
end

local function costOf(branch)
  return Branches[branch].unlock.cost
end

-- The saved skill that mines a vein and stores the ore, once per run.
local function ensureStoreSkill(sim)
  if sim.skills[Cfg.storeSkill] then return end
  local ok, err = Skills.save(sim, { name = Cfg.storeSkill, agent_type = "miner", loop = true,
    params = { vein = { kind = "vein" }, res = { kind = "resource" } },
    steps = { { tool = "mine", args = { vein = "$vein" } }, { tool = "return" }, { tool = "store", args = { resource = "$res" } } } }, { force = true })
  assert(ok, "store skill: " .. tostring(err))
end

-- Once per game second: every Miner runs the store skill on the best free vein of its supply ore (the control's `supply` list, one ore
-- per Miner in turn; none listed = the best vein overall), re-aimed only while docked and empty.
local function directStore(sim, supply)
  local taken, n = {}, 0
  for _, id in ipairs(sim.agentOrder) do
    local a = sim.agents[id]
    if a.type == "miner" then
      n += 1
      local ship = sim:ownedShip(id)
      local want = supply and supply[(n - 1) % #supply + 1]
      local skip = table.clone(taken)
      if want then
        for vid, v in pairs(sim.veins) do if v.ore ~= want then skip[vid] = true end end
      end
      local vein = Pacing.bestVein(sim, ship, skip)
      if vein then
        taken[vein] = true
        local idle = ship.state == "idle" and ship.at == sim.home and ship.cargo <= 0
        if a.activeSkill ~= Cfg.storeSkill or (a.skillParams.vein ~= vein and idle) then
          Skills.assign(sim, id, Cfg.storeSkill, { vein = vein, res = sim.veins[vein].ore })
        end
      end
    end
  end
end

-- One arm. spec = { seed, fork (game seconds), window (game seconds), branch (nil for a control), directive, context, control = control name }.
-- Returns the measurements of the window (see the fields at the end).
function Profit.runArm(spec)
  local sim = Sim.new({ seed = spec.seed })
  sim:setDecider(Ai.decide)
  assert(Clock.setSpeed(sim, 1))
  local tick = sim.b.tickSeconds
  local perSecond = math.floor(1 / tick + 0.5)
  local forkTicks, windowTicks = math.floor(spec.fork / tick + 0.5), math.floor(spec.window / tick + 0.5)

  local bought = {}
  for i = 1, forkTicks do
    sim:step()
    if i % perSecond == 0 then Pacing.play(sim, bought) end
  end

  local control = Cfg.controls[spec.control or "hmc"]
  local branch = spec.branch
  local unlock = branch and costOf(branch) or 0
  -- Both arms of a pair get the same grant: the largest unlock among the branches compared with the control, the working capital,
  -- and the freighters the control's logistics chain needs.
  local grant = (spec.grantFor or 0) + Cfg.workingCapital + (control.freighters or 0) * sim.b.logistics.freighterCost
  sim.resources.credits += grant

  local out = { seed = spec.seed, id = spec.id, branch = branch, grant = grant, unlock = unlock, forkTier = sim.tier, openError = nil }
  local logisticianId
  local storing = control.logistician ~= nil
  if storing then
    ensureStoreSkill(sim)
    local ok, id = sim:hireLogistician(sim.home)
    if ok then logisticianId = id; sim:setDirective(id, control.logistician) else out.openError = "hire: " .. tostring(id) end
    for _ = 1, control.freighters or 0 do
      local fok, fwhy = sim:buyFreighter(sim.home)
      if not fok then out.openError = "freighter: " .. tostring(fwhy) end
    end
  end
  if branch then
    local ok, why = sim:openBranch(branch)
    if not ok then
      out.openError = "open: " .. tostring(why)
      return out
    end
    local agent = BRANCH_AGENT[branch]
    sim:setDirective(agent, spec.directive)
    for key, value in pairs(spec.context or {}) do assert(sim:setContextSetting(agent, key, value)) end
  end

  -- Tallies ------------------------------------------------------------------------------------------------------------
  local gross, byType, counts = 0, {}, {}
  local branchAgent = branch and BRANCH_AGENT[branch]
  local origCredit = sim.credit
  sim.credit = function(self, agentId, recordId, amount)
    local a = agentId and self.agents[agentId]
    local kind = a and a.type or "freighter"
    byType[kind] = (byType[kind] or 0) + amount
    return origCredit(self, agentId, recordId, amount)
  end
  local computePacks = 0
  local origBuy = sim.compute.buy
  sim.compute.buy = function(self, packs)
    local ok, err = origBuy(self, packs)
    if ok then computePacks += Compute.packPrice(self.cfg, packs) end
    return ok, err
  end
  local won, lost, loot, damageTaken, inputs, refinedUnits, retaliationLost = 0, 0, 0, 0, 0, 0, 0
  local missionAt
  local origEmit = sim.emit
  sim.emit = function(self, name, data)
    counts[name] = (counts[name] or 0) + 1
    if name == "raid_result" then
      if data.won then won += 1 else lost += 1 end
      damageTaken += data.damage or 0
    elseif name == "refined" then
      inputs += data.qty * Refining.inputValue(data.recipe)
      refinedUnits += data.qty
    elseif name == "retaliation" then
      retaliationLost += data.lost or 0
    elseif name == "mission_complete" and branch and data.id == MISSION[branch] and not missionAt then
      missionAt = (self.tick - forkTicks) * tick
    end
    return origEmit(self, name, data)
  end
  local refinedRevenue, refinedSold, refinedGoodSold = 0, 0, 0
  local origOnSale = Refining.onSale
  Refining.onSale = function(s2, resource, qty, unit)
    refinedRevenue += qty * unit
    refinedSold += qty
    if unit >= Branches.refining.mission.margin * Refining.inputValue(resource) then refinedGoodSold += qty end
    return origOnSale(s2, resource, qty, unit)
  end
  local decisions = {}
  local origDecide = sim.decide
  sim.decide = function(self, agentId, ctx)
    local a = self.agents[agentId]
    local kind = a and a.type or "?"
    decisions[kind] = (decisions[kind] or 0) + 1
    return origDecide(self, agentId, ctx)
  end

  local start = { credits = sim.resources.credits, nw = sim.resources.credits + stockValue(sim), revenue = sim.lifetimeRevenue,
    compute = sim.compute.lifetimeTotal, computeBy = table.clone(sim.compute.lifetime) }
  local timeline = { { t = 0, nw = start.nw } }
  local disabledEvents, pausedEvents = 0, 0
  local wasDisabled, wasPaused = {}, {}

  local function disabledNow()
    local list = {}
    for _, id in ipairs(sim.salvageOrder or {}) do list[#list + 1] = { key = "w" .. id, off = sim.salvageShips[id].state == "disabled" } end
    for _, id in ipairs(sim.interceptorOrder or {}) do list[#list + 1] = { key = "i" .. id, off = sim.interceptors[id].state == "disabled" } end
    return list
  end

  for i = 1, windowTicks do
    sim:step()
    if i % perSecond == 0 then
      Pacing.play(sim, bought, { shop = false, miners = not storing })
      if storing then directStore(sim, control.supply) end
      for _, d in ipairs(disabledNow()) do
        if d.off and not wasDisabled[d.key] then disabledEvents += 1 end
        wasDisabled[d.key] = d.off
      end
      if branchAgent then
        for _, id in ipairs(sim.agentOrder) do
          if sim.agents[id].type == branchAgent then
            local paused = sim.agents[id].state == "paused_error"
            if paused and not wasPaused[id] then pausedEvents += 1 end
            wasPaused[id] = paused
          end
        end
      end
      if (i / perSecond) % 60 == 0 then
        timeline[#timeline + 1] = { t = i * tick, nw = sim.resources.credits + stockValue(sim) }
      end
    end
  end

  local minutes = spec.window / 60
  local spent = {}
  for k, v in pairs(sim.compute.lifetime) do spent[k] = v - (start.computeBy[k] or 0) end
  local branchGross = branchAgent and (byType[branchAgent] or 0) or 0
  local endNw = sim.resources.credits + stockValue(sim)
  local revenue = sim.lifetimeRevenue - start.revenue
  -- credits spent on something other than Compute packs: with the shop frozen this is repairs (branch assets are the only thing that repairs) and mission claims
  local otherSpend = start.credits + revenue - computePacks - sim.resources.credits

  out.minutes = minutes
  out.totalRevenue = revenue
  out.byType = byType
  out.branchGross = branchGross
  out.netWorthDelta = endNw - start.nw
  out.creditsDelta = sim.resources.credits - start.credits
  out.stockEnd = endNw - sim.resources.credits
  out.computeCredits = computePacks
  out.computeUsed = sim.compute.lifetimeTotal - start.compute
  out.computeBranch = branchAgent and (spent[branchAgent] or 0) or 0
  out.repairs = otherSpend
  out.decisions = decisions
  out.timeline = timeline
  out.disabled = disabledEvents
  out.paused = pausedEvents
  out.wins, out.losses, out.damageTaken = won, lost, damageTaken
  out.retaliationLost = retaliationLost
  Refining.onSale = origOnSale
  out.refinedUnits, out.refinedInputs = refinedUnits, inputs
  out.refinedRevenue, out.refinedSold, out.refinedGoodSold = refinedRevenue, refinedSold, refinedGoodSold
  out.counts = counts
  out.mission = branch and { id = MISSION[branch], status = missionStatus(sim, branch), at = missionAt } or nil
  out.logistician = logisticianId
  if spec.keepSim then out.sim = sim end
  if branch == "raiding" then out.notoriety = sim.raid.notoriety end
  if branch == "salvage" then
    local unsold = {}
    for _, id in ipairs(sim.salvageOrder) do
      for good, q in pairs(sim.salvageShips[id].hold) do unsold[good] = (unsold[good] or 0) + q end
    end
    out.unsoldHold = unsold
  end
  return out
end

local function mean(list)
  local s = 0
  for _, v in ipairs(list) do s += v end
  return #list > 0 and s / #list or 0
end

Profit.mean = mean

-- The control arm of one (seed, fork, control) with the grant of the largest unlock among `branches`.
function Profit.grantFor(branches)
  local grant = 0
  for _, b in ipairs(branches) do grant = math.max(grant, costOf(b)) end
  return grant
end

function Profit.runControl(seed, forkName, controlName, branches, windowMinutes)
  return Profit.runArm({ seed = seed, fork = Cfg.forks[forkName], window = (windowMinutes or Cfg.windowMinutes) * 60, control = controlName, grantFor = Profit.grantFor(branches),
    id = "control_" .. controlName })
end

-- Every scenario on every seed, each against its control. Returns { controls = { [key] = { [seed] = arm } }, runs = { { scenario, seed, arm, control, marginal... } } }.
-- A control is granted the largest unlock of the scenarios that share it, so both arms start with the same credits after the unlock.
function Profit.run(opts)
  opts = opts or {}
  local seeds = opts.seeds or Cfg.seeds
  local scenarios = opts.scenarios or Cfg.scenarios
  local groups, order = {}, {}
  for _, sc in ipairs(scenarios) do
    local key = sc.fork .. ":" .. sc.control
    if not groups[key] then groups[key] = { fork = sc.fork, control = sc.control, branches = {}, seen = {} }; order[#order + 1] = key end
    local g = groups[key]
    if not g.seen[sc.branch] then g.seen[sc.branch] = true; g.branches[#g.branches + 1] = sc.branch end
  end
  local controls = {}
  for _, key in ipairs(order) do
    local g = groups[key]
    controls[key] = {}
    for _, seed in ipairs(seeds) do controls[key][seed] = Profit.runControl(seed, g.fork, g.control, g.branches, opts.windowMinutes) end
  end
  local runs = {}
  for _, sc in ipairs(scenarios) do
    local key = sc.fork .. ":" .. sc.control
    for _, seed in ipairs(seeds) do
      -- the branch arm gets the same grant as its control so that both hold the same credits right after the unlock
      local g = groups[key]
      local ctrl = controls[key][seed]
      local arm = Profit.runArm({ seed = seed, fork = Cfg.forks[sc.fork], window = (opts.windowMinutes or Cfg.windowMinutes) * 60, branch = sc.branch, directive = sc.directive,
        context = sc.context, control = sc.control, id = sc.id, grantFor = Profit.grantFor(g.branches) })
      runs[#runs + 1] = { scenario = sc, seed = seed, arm = arm, control = ctrl, key = key, group = g }
    end
  end
  return { controls = controls, runs = runs }
end

-- Marginal figures of one run against its control. net = (net worth change of the branch arm) - (net worth change of the control);
-- the unlock cost is paid before the window starts, so it is not in `net`. Payback: first minute from which the marginal net worth
-- stays at or above the unlock cost, else unlock / marginal rate when the rate is positive, else nil.
function Profit.marginal(run)
  local arm, ctrl = run.arm, run.control
  if arm.openError then return { error = arm.openError } end
  local minutes = arm.minutes
  local net = arm.netWorthDelta - ctrl.netWorthDelta
  local cash = arm.creditsDelta - ctrl.creditsDelta
  local m = { net = net, cashPerMin = cash / minutes, netPerMin = net / minutes, grossPerMin = arm.branchGross / minutes,
    controlPerMin = ctrl.netWorthDelta / minutes, armPerMin = arm.netWorthDelta / minutes,
    totalRevenueDelta = arm.totalRevenue - ctrl.totalRevenue,
    computeCredits = arm.computeCredits - ctrl.computeCredits, repairs = arm.repairs - ctrl.repairs }
  -- sustained crossing: the marginal net worth must stay at or above the unlock cost to the end of the window
  for i = #arm.timeline, 2, -1 do
    local diff = (arm.timeline[i].nw - arm.timeline[1].nw) - (ctrl.timeline[i].nw - ctrl.timeline[1].nw)
    if diff < arm.unlock then break end
    m.paybackAt = arm.timeline[i].t / 60
  end
  if not m.paybackAt and m.netPerMin > 0 then m.paybackExtrapolated = arm.unlock / m.netPerMin end
  return m
end

-- Markdown ---------------------------------------------------------------------------------------------------------------

local function f0(n) return ("%.0f"):format(n) end
local function f1(n) return ("%.1f"):format(n) end
local function signed(n) return ("%+.0f"):format(n) end

local function paybackText(m)
  if m.paybackAt then return f0(m.paybackAt) end
  if m.paybackExtrapolated then return ("~%s (extrap.)"):format(f0(m.paybackExtrapolated)) end
  return "never"
end

local function mins(sec) return sec and f1(sec / 60) or "-" end

-- `result` = Profit.run(...). The report Game Design reads; see docs/BRANCH_PROFIT_REPORT.md.
function Profit.markdown(result, opts)
  opts = opts or {}
  local seeds = opts.seeds or Cfg.seeds
  local out = {}
  local function add(line) out[#out + 1] = line end
  add("# GRIDMIND branch profitability report (GR5-64)")
  add("")
  add(("Generated by `luau tools/branch_report.luau` (`tools/branch_report.sh`). Deterministic: seeds %s, %d game minutes per window, stub AI, x1 game speed."):format(
    table.concat(seeds, ", "), opts.windowMinutes or Cfg.windowMinutes))
  add("")
  add("## Method")
  add("")
  add(("- Every arm replays the scripted pacing player (`config/pacing.luau`) on its seed from game second 0 to the **fork**: `t2` = minute %d (Engine Mk2 bought, the earliest Salvage can open), `t4` = minute %d (logistics hub standing; Raiding, Refining and Salvage are all openable on the same assets)."):format(
    Cfg.forks.t2 / 60, Cfg.forks.t4 / 60))
  add(("- Both arms of a pair receive the same credit grant at the fork (the largest branch unlock they are compared with, %d working capital%s). The branch arm opens its branch (paying the unlock) and briefs its agent with the directive shown; the control keeps the credits. The shop is frozen in both arms afterwards, Compute is topped up by the pacing player in both."):format(
    Cfg.workingCapital, ", and a freighter for the logistics controls"))
  add(("- Controls: `hmc` = Miners sell at HMC (the pacing player). `orbis` / `ship` = Miners store ore in the warehouse (saved skill `gm-store`, the stub Miner never stores) on %s, one Logistician and one freighter move it with the directive \"Sell at Orbis.\" / \"Ship everything you can to the markets.\" Refining is compared with these because it can only run on stored ore and sell through a Logistician, so the logistics uplift is not credited to the refinery."):format(
    table.concat(Cfg.controls.orbis.supply, " + ")))
  add("- **Net** = change in net worth over the window of the branch arm minus that of its control. Net worth = credits + stock at its best unlocked sale price (ore at the HMC rate) + freighter and ship loads + Compute at pack price, so unlock, operating, repair, Compute, input opportunity cost (ore not sold) and losses are all inside it; the unlock is paid before the window and is the payback target. **Net cash** is the same on credits only (nothing marked to market). **Gross** = credits the branch agent itself earned (Scavenger / Privateer sales and loot); Refining has no gross of its own, its goods are sold by the Logistician, so its revenue is shown as `refined sales`.")
  add("- Payback = first game minute from which the marginal net worth stays at or above the unlock cost to the end of the window; `~N (extrap.)` = unlock / marginal rate when not reached in the window; `never` = marginal rate is not positive.")
  add("- Missions are not claimed in the window (claiming pays V1 3,000 cr, V2 a blueprint, V3 5,000 cr: excluded from every figure); status shows what the directive achieved.")
  add("- **Assumptions and unreachable buyers.** Stub AI everywhere (no real LLM). Mark-to-market valuation: unsold stock counts at its best unlocked sale price, so a stalled stock inflates Net without being cash (compare Net with Net cash). Orbis buys neither Catalyst nor Processor and the stub Logistician stalls on a \"Sell at Orbis.\" directive when it holds one, so the `Sold at Orbis` Refining arms leave goods stranded: their Net is **not realizable** and the `Shipped` arms are the Refining result. Data cores sell only at Meridian (`can_meridian`). One freighter is the logistics bottleneck. Missions are not claimed.")
  add("")

  local order = {}
  for _, sc in ipairs(opts.scenarios or Cfg.scenarios) do order[#order + 1] = sc end

  add("## Controls (mining only), net worth per game minute")
  add("")
  add("| Control | Fork | " .. table.concat((function() local l = {} for _, sd in ipairs(seeds) do l[#l + 1] = "seed " .. sd end return l end)(), " | ") .. " | Mean |")
  add("|---|---|" .. string.rep("---|", #seeds + 1))
  local keys = {}
  for key in pairs(result.controls) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local row, vals = {}, {}
    for _, sd in ipairs(seeds) do
      local c = result.controls[key][sd]
      local v = c.netWorthDelta / c.minutes
      vals[#vals + 1] = v
      row[#row + 1] = f0(v)
    end
    local fork, name = key:match("^(%w+):(%w+)$")
    add(("| %s | %s | %s | %s |"):format(name, fork, table.concat(row, " | "), f0(mean(vals))))
  end
  add("")

  local byScenario = {}
  for _, run in ipairs(result.runs) do
    local list = byScenario[run.scenario.id]
    if not list then list = {}; byScenario[run.scenario.id] = list end
    list[#list + 1] = run
  end

  add("## Summary (mean over seeds, per game minute)")
  add("")
  add("| Scenario | Directive | Gross | Net | Net cash | Payback (min, median) | Disabled / seed | Failure rate | Mission |")
  add("|---|---|---|---|---|---|---|---|---|")
  local detail = {}
  for _, sc in ipairs(order) do
    local runs = byScenario[sc.id] or {}
    local g, n, c, d, paybacks, fails, fightsN, missionDone = {}, {}, {}, {}, {}, 0, 0, 0
    local never = 0
    for _, run in ipairs(runs) do
      local m = Profit.marginal(run)
      if not m.error then
        g[#g + 1], n[#n + 1], c[#c + 1], d[#d + 1] = m.grossPerMin, m.netPerMin, m.cashPerMin, run.arm.disabled
        paybacks[#paybacks + 1] = m.paybackAt or m.paybackExtrapolated or math.huge
        if run.arm.mission and (run.arm.mission.status == "complete" or run.arm.mission.status == "claimed") then missionDone += 1 end
        if sc.branch == "raiding" then fails += run.arm.losses; fightsN += run.arm.wins + run.arm.losses
        elseif sc.branch == "salvage" then fails += (run.arm.counts.hazard or 0); fightsN += (run.arm.counts.salvaged or 0) + (run.arm.counts.hazard or 0) end
        detail[#detail + 1] = { sc = sc, run = run, m = m }
      end
    end
    table.sort(paybacks)
    local med = paybacks[math.ceil(#paybacks / 2)]
    local pb = med == nil and "-" or (med == math.huge and "never" or ("%s%s"):format(med > (opts.windowMinutes or Cfg.windowMinutes) and "~" or "", f0(med)))
    local fail = sc.branch == "refining" and "n/a" or (fightsN > 0 and ("%.0f%% (%d/%d)"):format(100 * fails / fightsN, fails, fightsN) or "-")
    add(("| %s | `%s` | %s | %s | %s | %s | %s | %s | %d/%d seeds |"):format(sc.label, sc.directive, f0(mean(g)), signed(mean(n)), signed(mean(c)), pb, f1(mean(d)), fail, missionDone, #runs))
  end
  add("")
  add("Failure rate: Salvage = hazards per layer worked, Raiding = attacks lost per attack, Refining = n/a (nothing can fail; see `Disabled` and stalls in the per-seed table).")
  add("")

  add("## Per seed")
  add("")
  add("| Scenario | Seed | Gross | Net | Net cash | Payback (min) | Compute cr (vs control) | Repairs and other spend (vs control) | Disabled | Paused | Wins / losses | Retaliation units lost | Mission (status @ min) | Refined / sold units (>=1.5x) | Unsold at end |")
  add("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
  for _, d in ipairs(detail) do
    local a, m = d.run.arm, d.m
    local unsold = {}
    if a.unsoldHold then for good, q in pairs(a.unsoldHold) do unsold[#unsold + 1] = ("%d %s"):format(q, good) end end
    table.sort(unsold)
    if d.sc.branch == "refining" then
      local st = d.run.arm.stockEnd
      unsold[#unsold + 1] = ("stock worth %s cr"):format(f0(st))
    end
    add(("| %s | %d | %s | %s | %s | %s | %s | %s | %d | %d | %s | %s | %s | %s | %s |"):format(d.sc.id, d.run.seed, f0(m.grossPerMin), signed(m.netPerMin), signed(m.cashPerMin),
      paybackText(m), signed(m.computeCredits), signed(m.repairs), a.disabled, a.paused,
      d.sc.branch == "raiding" and ("%d / %d"):format(a.wins, a.losses) or "-", d.sc.branch == "raiding" and tostring(a.retaliationLost) or "-",
      a.mission and ("%s @ %s"):format(a.mission.status, mins(a.mission.at)) or "-",
      d.sc.branch == "refining" and ("%d / %d (%d)"):format(a.refinedUnits, a.refinedSold, a.refinedGoodSold) or "-",
      #unsold > 0 and table.concat(unsold, ", ") or "-"))
  end
  add("")
  add("Gross, Net and Net cash are credits per game minute over the window. Compute and repairs columns are credits over the whole window, branch arm minus control.")
  return table.concat(out, "\n")
end

return Profit
