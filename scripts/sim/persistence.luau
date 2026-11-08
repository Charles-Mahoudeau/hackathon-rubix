-- Save / load (spec §16.3). Pure Luau: turns a Sim into a JSON-able table and back. File access is the caller's
-- `storage` ({ read(path) -> string?, write(path, text) -> boolean, err? }) because the engine has no file API yet [ENGINE].
-- Only mutable state is saved; planets, ore data and balance come from config, so a rebalance applies to old saves.
local Json = require("./json")
local Sim = require("./sim")
local Upgrades = require("./upgrades")
local Market = require("./market")
local Offline = require("./offline")

local Persistence = {}

Persistence.SCHEMA_VERSION = 1

local function err(code, message, extra)
  local e = { code = code, message = message }
  if extra then for k, v in pairs(extra) do e[k] = v end end
  return e
end

-- savedAt: real UTC seconds, given by the caller so the sim itself never reads a clock.
function Persistence.serialize(sim, savedAt)
  local veins = {}
  for id, v in pairs(sim.veins) do veins[id] = { reserve = v.reserve, scanned = v.scanned } end
  local ships = {}
  for id, ship in pairs(sim.ships) do
    local copy = Sim.deepCopy(ship)
    copy.vein = ship.vein and ship.vein.id or nil
    copy.feedEntry = ship.feedEntry and ship.feedEntry.id or nil -- relinked to the feed list on load
    ships[id] = copy
  end
  return {
    schema_version = Persistence.SCHEMA_VERSION,
    seed = sim.seed,
    rng = Sim.deepCopy(sim.rng),
    game_time = sim.tick * sim.b.tickSeconds,
    saved_at = savedAt,
    state = Sim.deepCopy({
      tick = sim.tick,
      tier = sim.tier,
      resources = sim.resources,
      warehouse = sim.warehouse,
      lifetimeRevenue = sim.lifetimeRevenue,
      upgrades = sim.upgrades,
      agentOrder = sim.agentOrder,
      shipOrder = sim.shipOrder,
      deepNav = sim.deepNav,
      home = sim.home,
      agents = sim.agents,
      skills = sim.skills,
      logs = sim.logs,
      debug = sim.debug,
      lastDecision = sim.lastDecision,
      feed = sim.feed,
      feedSeq = sim.feedSeq,
      records = sim.records,
      recordSeq = sim.recordSeq,
      missions = sim.missions,
      market = Market.serialize(sim.market),
    }),
    veins = veins,
    ships = ships,
  }
end

-- Rebuilds a Sim from a decoded save. Does not check the version (see load). The caller re-attaches the decider.
function Persistence.restore(data, opts)
  local sim = Sim.new({ seed = data.seed, balance = opts and opts.balance })
  local st = Sim.deepCopy(data.state)
  for _, key in ipairs({ "tick", "tier", "lifetimeRevenue", "upgrades", "agentOrder", "shipOrder", "deepNav", "home", "skills", "logs", "debug", "lastDecision", "feed", "feedSeq", "records", "recordSeq", "missions" }) do
    if st[key] ~= nil then sim[key] = st[key] end
  end
  for k, v in pairs(st.resources) do sim.resources[k] = v end
  for k, v in pairs(st.warehouse) do sim.warehouse[k] = v end
  for id, saved in pairs(st.agents) do
    if saved.mode == "default" then saved.mode = "ai" end
    sim.agents[id] = saved
  end
  if st.market then Market.load(sim.market, st.market) end
  for k, v in pairs(data.rng) do sim.rng[k] = v end
  for id, saved in pairs(data.veins) do
    local vein = sim.veins[id]
    if vein then vein.reserve, vein.scanned = saved.reserve, saved.scanned end
  end
  sim.ships = {}
  for id, saved in pairs(Sim.deepCopy(data.ships)) do
    saved.vein = saved.vein and sim.veins[saved.vein] or nil
    if saved.feedEntry then
      local id = saved.feedEntry
      saved.feedEntry = nil
      for _, e in ipairs(sim.feed) do if e.id == id then saved.feedEntry = e end end
    end
    sim.ships[id] = saved
  end
  Upgrades.applyToFleet(sim)
  sim.savedAt = data.saved_at
  return sim
end

function Persistence.encode(data) return Json.encode(data) end
function Persistence.decode(text) return Json.decode(text) end

-- Parses and checks a save. Returns data, or nil + error { code = "corrupt" | "unknown_schema" }.
local function parse(text)
  local ok, data = pcall(Json.decode, text)
  if not ok or type(data) ~= "table" then return nil, err("corrupt", "save is not valid JSON: " .. tostring(data)) end
  if data.schema_version ~= Persistence.SCHEMA_VERSION then
    return nil, err("unknown_schema", ("save has schema_version %s, this build reads %d"):format(
      tostring(data.schema_version), Persistence.SCHEMA_VERSION), { found = data.schema_version })
  end
  return data
end

-- Returns sim, or nil + error { code = "no_file" | "corrupt" | "unknown_schema", message }. Never writes.
function Persistence.load(storage, path, opts)
  local text = storage.read(path)
  if text == nil then return nil, err("no_file", "no save at " .. path) end
  local data, e = parse(text)
  if not data then return nil, e end
  local ok, sim = pcall(Persistence.restore, data, opts)
  if not ok then return nil, err("corrupt", "save is missing data: " .. tostring(sim)) end
  return sim
end

-- Writes the sim. Refuses to overwrite a readable save of another schema_version (so a build that cannot read it
-- never destroys it); opts.force skips that check (reset). Returns true, or false + error.
function Persistence.save(sim, storage, path, savedAt, opts)
  if not (opts and opts.force) then
    local existing = storage.read(path)
    if existing ~= nil then
      local _, e = parse(existing)
      if e and e.code == "unknown_schema" then return false, e end
    end
  end
  local text = Persistence.encode(Persistence.serialize(sim, savedAt))
  local ok, werr = storage.write(path, text)
  if ok == false then return false, err("write_failed", tostring(werr or "write failed")) end
  return true
end

-- Loads the save, or starts a new game when there is none. A save that exists but cannot be read is an error,
-- not a silent new game, so the caller can show it and keep the file.
function Persistence.loadOrNew(storage, path, opts)
  local sim, e = Persistence.load(storage, path, opts)
  if sim then return sim end
  if e.code == "no_file" then return Sim.new(opts) end
  return nil, e
end

-- After a load: simulates the time between the save and `now` (real UTC seconds) as offline progression (spec §14).
-- Returns the "While you were away" report, nil when the absence is ignored (< 60 s) or the save has no timestamp.
function Persistence.catchUp(sim, now)
  if type(sim.savedAt) ~= "number" or type(now) ~= "number" then return nil end
  return Offline.run(sim, now - sim.savedAt)
end

-- Replaces the save with a fresh game and returns it.
function Persistence.reset(storage, path, savedAt, opts)
  local sim = Sim.new(opts)
  local ok, e = Persistence.save(sim, storage, path, savedAt, { force = true })
  if not ok then return nil, e end
  return sim
end

function Persistence.memoryStorage()
  local files = {}
  return {
    files = files,
    read = function(path) return files[path] end,
    write = function(path, text) files[path] = text; return true end,
  }
end

return Persistence
