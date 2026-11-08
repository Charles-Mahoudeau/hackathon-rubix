-- Per-agent context settings (spec §9.3): defaults, validation, and which toggles the player may use yet.
local Ai = require("@scripts/config/ai")
local World = require("@scripts/config/world")
local Balance = require("@scripts/config/balance")

local Settings = {}

-- Panel order. `options` lists every legal value (the UI shows each option's live token weight).
Settings.order = { "prices_hmc", "prices_orbis", "prices_halcyon", "prices_meridian", "price_trends", "format",
  "recent_results", "veins", "inbox", "warehouse" }

-- The settings a Monitor has (spec §9.2.4); the other agent types have the ones above.
Settings.monitorOrder = { "agent_detail", "show_skills", "show_veins", "show_prices", "format" }

-- Panel order for an agent type.
function Settings.orderFor(agentType) return agentType == "monitor" and Settings.monitorOrder or Settings.order end

local recentOptions = {}
for i = 0, Ai.recentMax do recentOptions[#recentOptions + 1] = i end

Settings.options = {
  prices_hmc = { "off", "current", "all" },
  prices_orbis = { false, true },
  prices_halcyon = { false, true },
  prices_meridian = { false, true },
  price_trends = { false, true },
  format = { "compact", "json" },
  recent_results = recentOptions,
  veins = { "vein", "planet", "all" },
  inbox = { false, true },
  warehouse = { false, true },
  agent_detail = { "summary", "results" },
  show_skills = { false, true },
  show_veins = { false, true },
  show_prices = { false, true },
}

-- The cheapest option of each setting: the weight of an option is measured against it.
Settings.minimal = { prices_hmc = "off", prices_orbis = false, prices_halcyon = false, prices_meridian = false,
  price_trends = false, format = "compact", recent_results = 0, veins = "vein", inbox = false, warehouse = false,
  agent_detail = "summary", show_skills = false, show_veins = false, show_prices = false }

function Settings.defaults()
  local d = {}
  for k, v in pairs(Ai.contextDefaults) do d[k] = v end
  return d
end

local function legal(key, value)
  local opts = Settings.options[key]
  if not opts then return false end
  for _, o in ipairs(opts) do if o == value then return true end end
  return false
end

-- Returns a copy of `settings` with `key` changed, or nil + reason. Never mutates `settings`.
function Settings.with(settings, key, value)
  if not Settings.options[key] then return nil, "unknown_setting" end
  if not legal(key, value) then return nil, "bad_value" end
  local out = {}
  for k, v in pairs(settings) do out[k] = v end
  out[key] = value
  return out
end

-- Fill missing keys with defaults and drop unknown or illegal ones (a loaded save may be old).
function Settings.normalize(settings)
  local out = Settings.defaults()
  for k, v in pairs(settings or {}) do
    if legal(k, v) then out[k] = v end
  end
  return out
end

-- Toggles that need a station building or a tier: false + the unlocking tier while locked.
function Settings.available(sim, key)
  local marketOf = { prices_orbis = "orbis", prices_halcyon = "halcyon", prices_meridian = "meridian" }
  if marketOf[key] then
    local m = World.markets[marketOf[key]]
    return sim:marketUnlocked(marketOf[key]), m.unlockTier
  end
  if key == "warehouse" then return sim:hasWarehouse(), Balance.warehouse.unlockTier end
  return true, 1
end

return Settings
