-- Debug screen (spec §16.4): the panel as data (`model`) and the click route (`act`), both pure so the whole path is testable
-- headless; the shell only lays the model out. Every button's action is "debug.<name>[.<arg>]"; `act` maps it to
-- sim/debug.luau `Debug.run`. Reachable from the nav only while config/debug.luau `enabled` is true (see Model.nav).
local DebugConfig = require("@scripts/config/debug")
local Screens = require("@scripts/config/screens")
local Debug = require("@scripts/sim/debug")
local Ai = require("@scripts/sim/ai")

local DebugPanel = {}

-- The debug actions the panel exposes, one entry each (test_debug checks it against Debug.actions).
DebugPanel.entries = {
  { name = "addCredits", label = "+ Credits" },
  { name = "addCompute", label = "+ Compute" },
  { name = "setStuck", label = "Stuck state" },
  { name = "setTier", label = "Set tier" },
  { name = "revealVeins", label = "Reveal all veins" },
  { name = "triggerShortage", label = "Trigger shortage" },
  { name = "simulateAway", label = "Simulate N h away" },
  { name = "setProvider", label = "Provider" },
  { name = "lastPrompt", label = "Show last prompt" },
  { name = "resetSave", label = "Reset save" },
}

local PREFIX = "debug."

function DebugPanel.actionOf(entry, arg)
  return PREFIX .. entry.name .. (arg ~= nil and ("." .. tostring(arg)) or "")
end

-- "debug.setTier.3" -> "setTier", "3"; nil for any other action or an unknown name.
function DebugPanel.parseAction(action)
  if type(action) ~= "string" or string.sub(action, 1, #PREFIX) ~= PREFIX then return nil end
  local name, arg = string.match(string.sub(action, #PREFIX + 1), "^(%w+)%.?(.*)$")
  for _, e in ipairs(DebugPanel.entries) do
    if e.name == name then return name, arg ~= "" and arg or nil end
  end
  return nil
end

function DebugPanel.new() return { toast = nil, prompt = nil, confirmReset = false } end

local function entry(name)
  for _, e in ipairs(DebugPanel.entries) do if e.name == name then return e end end
end

local function btn(name, label, arg, selected)
  return { label = label, action = DebugPanel.actionOf(entry(name), arg), selected = selected or false }
end

-- Prompt text cut into display lines: split at newlines, long lines at the width, the rest dropped with a closing "...".
local function promptLines(text)
  local c, lines = Screens.debug, {}
  for raw in string.gmatch(text .. "\n", "(.-)\n") do
    while #raw > c.promptChars do
      lines[#lines + 1] = string.sub(raw, 1, c.promptChars)
      raw = string.sub(raw, c.promptChars + 1)
    end
    lines[#lines + 1] = raw
  end
  return lines
end

-- -> { title, groups = { { label, buttons = { { label, action, selected } } } }, status, toast, promptTitle, promptLines }
function DebugPanel.model(sim, state)
  local c = DebugConfig
  local tiers, away = {}, {}
  for t = 1, c.maxTier do tiers[#tiers + 1] = btn("setTier", "T" .. t, t, sim.tier == t) end
  for _, h in ipairs(c.awayChoices) do away[#away + 1] = btn("simulateAway", ("%d h"):format(h), h) end
  local provider = Ai.provider()
  local groups = {
    { label = "Economy", buttons = { btn("addCredits", ("+%d credits"):format(c.creditBoost)), btn("addCompute", ("+%d Compute"):format(c.computeBoost)),
      btn("setStuck", "Stuck state") } },
    { label = "Progress", buttons = tiers },
    { label = "World", buttons = { btn("revealVeins", "Reveal veins"), btn("triggerShortage", "Shortage") } },
    { label = "Away", buttons = away },
    { label = "AI", buttons = { btn("setProvider", "Stub", "stub", provider == "stub"), btn("setProvider", "Axis", "axis", provider == "axis"),
      btn("lastPrompt", "Last prompt") } },
    { label = "Save", buttons = { btn("resetSave", state.confirmReset and "Confirm reset" or "Reset save") } },
  }
  local boosts = sim.debug.creditBoosts
  return {
    title = "DEBUG",
    groups = groups,
    status = ("Provider %s   Tier T%d   Credit boosts %d/%d%s"):format(provider, sim.tier, boosts, c.demoMaxCreditBoosts,
      Debug.withinDemoBudget(sim) and "" or "  OVER DEMO BUDGET"),
    toast = state.toast,
    confirmReset = state.confirmReset,
    promptTitle = state.prompt and "LAST PROMPT" or "NO PROMPT YET",
    promptLines = state.prompt and promptLines(state.prompt) or {},
  }
end

function DebugPanel.signature(sim, state)
  return table.concat({ Ai.provider(), sim.debug.creditBoosts, state.toast or "", state.prompt and #state.prompt or -1, tostring(state.confirmReset) }, "|")
end

local function describe(name, arg, res)
  if name == "addCredits" then return ("+%d credits (now %d)"):format(arg and tonumber(arg) or DebugConfig.creditBoost, res) end
  if name == "addCompute" then return ("+%d Compute (now %.1f)"):format(arg and tonumber(arg) or DebugConfig.computeBoost, res) end
  if name == "setStuck" then return res and "Stuck: HMC offers an emergency advance" or "Stuck state set (a skill or cargo still blocks the offer)" end
  if name == "setTier" then return "Tier set to T" .. res end
  if name == "revealVeins" then return ("Revealed %d veins"):format(res) end
  if name == "triggerShortage" then return ("Shortage started at %s on %s"):format(DebugConfig.shortage.market, DebugConfig.shortage.ore) end
  if name == "simulateAway" then return ("Simulated %d h away: %+d credits"):format(res.hours, res.credits) end
  if name == "setProvider" then return "AI provider: " .. res end
  return "Done"
end

-- ctx = { storage, path, savedAt } for the save reset. -> handled, freshSim. A reset returns the new Sim: the caller swaps it in.
function DebugPanel.act(sim, state, action, ctx)
  if action == "debug.cancelReset" then state.confirmReset = false; return true end
  local name, arg = DebugPanel.parseAction(action)
  if not name then return false end
  if not DebugConfig.enabled then state.toast = "debug disabled"; return true end
  if name == "resetSave" and not state.confirmReset then
    state.confirmReset, state.toast = true, "Click Confirm reset again to erase the save."
    return true
  end
  state.confirmReset = false
  local args = {}
  if name == "setTier" then args.tier = tonumber(arg)
  elseif name == "simulateAway" then args.hours = tonumber(arg)
  elseif name == "setProvider" then args.provider = arg
  elseif name == "triggerShortage" then args.market, args.ore = DebugConfig.shortage.market, DebugConfig.shortage.ore end
  local ok, res = Debug.run(sim, name, args, ctx)
  if not ok then
    state.toast = tostring(res)
    return true
  end
  if name == "lastPrompt" then
    state.prompt, state.toast = res.text, ("Prompt sent by %s at tick %d"):format(res.agent, res.tick)
    return true
  end
  if name == "resetSave" then
    state.prompt, state.toast = nil, "Save reset: new game"
    return true, res
  end
  state.toast = describe(name, arg, res)
  return true
end

return DebugPanel
