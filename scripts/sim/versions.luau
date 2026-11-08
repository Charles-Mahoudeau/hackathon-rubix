-- Prompt versions (spec §12.3): a version is the short hash of directive + equipped tools + context settings, one set per
-- agent. A new version starts when any of the three changes (the text of each is kept); going back to an earlier text is
-- the same hash, so it resumes that version. Per version: game time active, decisions, Compute, credits, errors, skill time.
-- Pure Luau, headless; `sim.versions` is saved with the game, `sim.versionFp` is a transient cache of what was last hashed.
local Versions = {}

function Versions.init(sim)
  sim.versions, sim.versionFp = {}, {}
end

local function hashOf(directive, tools, settings)
  local keys = {}
  for k in pairs(settings) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = { directive or "", table.concat(tools, ",") }
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(settings[k]) end
  local h = 2166136261 -- FNV-1a, 32 bit
  for _, byte in ipairs({ string.byte(table.concat(parts, "\n"), 1, -1) }) do
    h = bit32.band(bit32.bxor(h, byte) * 16777619, 0xFFFFFFFF)
  end
  return ("%08x"):format(h):sub(1, 6)
end

function Versions.list(sim, agentId)
  local l = sim.versions[agentId]
  if not l then l = {}; sim.versions[agentId] = l end
  return l
end

function Versions.find(sim, agentId, id)
  local l = sim.versions[agentId]
  if not l or not id then return nil end
  for i = #l, 1, -1 do
    if l[i].id == id then return l[i] end
  end
  return nil
end

local function copySettings(settings)
  local out = {}
  for k, v in pairs(settings) do out[k] = v end
  return out
end

-- The agent's current version, started on first sight of a new hash. Cheap when nothing changed: it compares the
-- directive string, the settings table (replaced by every change), the tier and the Scanner.
function Versions.sync(sim, agentId)
  local agent = sim.agents[agentId]
  local fp = sim.versionFp[agentId]
  local scanner = sim.upgrades.scanner
  if fp and fp.directive == agent.directive and fp.settings == agent.contextSettings and fp.tier == agent.tier and fp.scanner == scanner then
    return fp.version
  end
  local tools = sim:equippedTools(agentId)
  local id = hashOf(agent.directive, tools, agent.contextSettings)
  local v = Versions.find(sim, agentId, id)
  if not v then
    local l = Versions.list(sim, agentId)
    v = { id = id, number = #l + 1, directive = agent.directive or "", tools = { table.unpack(tools) },
      settings = copySettings(agent.contextSettings), started = sim.tick * sim.b.tickSeconds,
      ticks = 0, skill_ticks = 0, decisions = 0, compute = 0, credits = 0, errors = 0 }
    l[#l + 1] = v
  end
  sim.versionFp[agentId] = { directive = agent.directive, settings = agent.contextSettings, tier = agent.tier, scanner = scanner, version = v }
  return v
end

-- One tick of game time for every agent that is playing (offline only the skill-mode ones are).
function Versions.step(sim)
  local offline = sim.offline
  for _, id in ipairs(sim.agentOrder) do
    local agent = sim.agents[id]
    if not offline or agent.mode == "skill" then
      local v = Versions.sync(sim, id)
      v.ticks += 1
      if agent.mode == "skill" then v.skill_ticks += 1 end
    end
  end
end

function Versions.seconds(sim, v) return v.ticks * sim.b.tickSeconds end

-- Per active hour of the version. Below `minSeconds` of activity the rates are still computed but flagged.
function Versions.metrics(sim, v)
  local seconds = Versions.seconds(sim, v)
  local hours = seconds / 3600
  local per = function(x) return hours > 0 and x / hours or 0 end
  local creditsPerHour, computePerHour = per(v.credits), per(v.compute)
  return {
    id = v.id, number = v.number, seconds = seconds, skillSeconds = v.skill_ticks * sim.b.tickSeconds,
    decisions = v.decisions, compute = v.compute, credits = v.credits, errors = v.errors,
    creditsPerHour = creditsPerHour, computePerHour = computePerHour,
    netPerHour = creditsPerHour - computePerHour * sim.aiConfig.compute.priceCredits, errorsPerHour = per(v.errors),
    enoughData = seconds >= sim.aiConfig.versions.minSeconds,
  }
end

-- Word-level diff of two texts. A token is a word with the whitespace after it; tokens are compared by their word only.
local function tokens(str)
  local out = {}
  for tok in str:gmatch("%s*%S+%s*") do out[#out + 1] = tok end
  return out
end

local function word(tok) return tok:match("%S+") end

local function merge(list)
  local out = {}
  for _, s in ipairs(list) do
    local last = out[#out]
    if last and last.changed == s.changed then last.text ..= s.text else out[#out + 1] = { text = s.text, changed = s.changed } end
  end
  return out
end

-- -> segmentsA, segmentsB: arrays of { text, changed }; `changed` = removed from A / added in B.
function Versions.diff(a: string, b: string)
  local ta, tb = tokens(a), tokens(b)
  local n, m = #ta, #tb
  local lo = 1
  while lo <= n and lo <= m and word(ta[lo]) == word(tb[lo]) do lo += 1 end
  local hiA, hiB = n, m
  while hiA >= lo and hiB >= lo and word(ta[hiA]) == word(tb[hiB]) do hiA -= 1; hiB -= 1 end
  -- LCS over the middle part only
  local len = {}
  for i = hiA + 1, lo, -1 do
    len[i] = {}
    for j = hiB + 1, lo, -1 do
      if i > hiA or j > hiB then len[i][j] = 0
      elseif word(ta[i]) == word(tb[j]) then len[i][j] = len[i + 1][j + 1] + 1
      else len[i][j] = math.max(len[i + 1][j], len[i][j + 1]) end
    end
  end
  local sa, sb = {}, {}
  for i = 1, lo - 1 do sa[#sa + 1] = { text = ta[i], changed = false }; sb[#sb + 1] = { text = tb[i], changed = false } end
  local i, j = lo, lo
  while i <= hiA or j <= hiB do
    if i <= hiA and j <= hiB and word(ta[i]) == word(tb[j]) then
      sa[#sa + 1] = { text = ta[i], changed = false }; sb[#sb + 1] = { text = tb[j], changed = false }
      i += 1; j += 1
    elseif j > hiB or (i <= hiA and len[i + 1][j] >= len[i][j + 1]) then
      sa[#sa + 1] = { text = ta[i], changed = true }; i += 1
    else
      sb[#sb + 1] = { text = tb[j], changed = true }; j += 1
    end
  end
  for k = hiA + 1, n do sa[#sa + 1] = { text = ta[k], changed = false } end
  for k = hiB + 1, m do sb[#sb + 1] = { text = tb[k], changed = false } end
  return merge(sa), merge(sb)
end

-- Two versions of one agent side by side: the metrics of each, and the directive diff. nil when either is unknown.
function Versions.compare(sim, agentId, idA, idB)
  local va, vb = Versions.find(sim, agentId, idA), Versions.find(sim, agentId, idB)
  if not va or not vb then return nil end
  local segA, segB = Versions.diff(va.directive, vb.directive)
  return { a = Versions.metrics(sim, va), b = Versions.metrics(sim, vb), va = va, vb = vb, directiveA = segA, directiveB = segB }
end

return Versions
