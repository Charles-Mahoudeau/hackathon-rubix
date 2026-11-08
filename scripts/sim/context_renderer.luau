-- ContextRenderer (spec §9.2): turns the ordered context data into text, `compact` (default) or `json`.
-- Deterministic: same data -> same bytes. Never touches the sim.
--
-- Context data = array of sections, in prompt order:
--   { key = "time",    kind = "scalar",  value = v }
--   { key = "ship",    kind = "object",  fields = { {name, value}, ... } }
--   { key = "stock",   kind = "map",     map = Renderer.map({ {k, v}, ... }) }
--   { key = "prices",  kind = "maps",    subs = { {sub, map}, ... } }
--   { key = "veins",   kind = "table",   cols = { "id", ... }, rows = { { v1, v2, ... }, ... } }
--   { key = "inbox",   kind = "strings", items = { "text", ... } }
-- A value is nil ("?"), boolean (y/n), number, string, a plain array (list) or a Renderer.map (ordered pairs).
local Host = require("./host")

local Renderer = {}

-- Host.json.map marks an entry list without a field, so the renderer keeps its own weak set to tell a map cell from a list.
local isMap = setmetatable({}, { __mode = "k" })

function Renderer.map(entries)
  isMap[entries] = true
  return Host.json.map(entries)
end

local function fmtNum(n)
  if n == math.floor(n) then return string.format("%d", n) end
  local s = string.format("%.1f", n)
  if s:sub(-2) == ".0" then return s:sub(1, -3) end
  return s
end
Renderer.fmtNum = fmtNum

-- sep: "=" for the top level of a table cell (k=v,k=v), ":" for anything nested (name:value).
local function cell(v, sep)
  local t = type(v)
  if v == nil then return "?" end
  if t == "boolean" then return v and "y" or "n" end
  if t == "number" then return fmtNum(v) end
  if t == "string" then
    if v == "" or v:find("%s") then return '"' .. v .. '"' end
    return v
  end
  if isMap[v] then
    if #v == 0 then return "-" end
    local parts = {}
    for _, p in ipairs(v) do parts[#parts + 1] = p[1] .. sep .. cell(p[2], ":") end
    return table.concat(parts, ",")
  end
  if #v == 0 then return "-" end
  local parts = {}
  for _, x in ipairs(v) do parts[#parts + 1] = cell(x, ":") end
  return table.concat(parts, ",")
end

-- One value as a table cell would show it: `k=v,k=v` for a map, `a,b` for a list.
function Renderer.inline(v) return cell(v, "=") end

local function mapLine(prefix, m)
  local parts = {}
  for _, p in ipairs(m) do parts[#parts + 1] = p[1] .. "=" .. cell(p[2], ":") end
  return prefix .. ": " .. table.concat(parts, " ")
end

local function isEmpty(sec)
  if sec.kind == "map" then return #sec.map == 0 end
  if sec.kind == "maps" then return #sec.subs == 0 end
  if sec.kind == "table" then return #sec.rows == 0 end
  if sec.kind == "strings" then return #sec.items == 0 end
  if sec.kind == "object" then return #sec.fields == 0 end
  return false
end

function Renderer.compact(data)
  local lines = {}
  for _, sec in ipairs(data) do
    if not isEmpty(sec) then
      if sec.kind == "scalar" then
        local value = sec.key == "compute" and type(sec.value) == "number" and string.format("%.1f", sec.value) or cell(sec.value, ":")
        lines[#lines + 1] = sec.key .. ": " .. value
      elseif sec.kind == "object" then
        local parts = {}
        for _, f in ipairs(sec.fields) do parts[#parts + 1] = f[1] .. "=" .. cell(f[2], ":") end
        lines[#lines + 1] = sec.key .. ": " .. table.concat(parts, " ")
      elseif sec.kind == "map" then
        lines[#lines + 1] = mapLine(sec.key, sec.map)
      elseif sec.kind == "maps" then
        for _, s in ipairs(sec.subs) do lines[#lines + 1] = mapLine(sec.key .. "." .. s[1], s[2]) end
      elseif sec.kind == "table" then
        lines[#lines + 1] = ("%s[%d] %s"):format(sec.key, #sec.rows, table.concat(sec.cols, " "))
        for _, row in ipairs(sec.rows) do
          local parts = {}
          for i = 1, #sec.cols do parts[i] = cell(row[i], "=") end
          lines[#lines + 1] = table.concat(parts, " ")
        end
      elseif sec.kind == "strings" then
        lines[#lines + 1] = ("%s[%d]"):format(sec.key, #sec.items)
        for _, it in ipairs(sec.items) do lines[#lines + 1] = "- " .. it end
      end
    end
  end
  return table.concat(lines, "\n")
end

local function jsonKey(name) return (name:gsub("%%", "_pct")) end

-- Cells become JSON values: "k=v" cells stay ordered maps, "?" becomes null.
local function jsonValue(v)
  if type(v) == "table" and isMap[v] then
    local out = {}
    -- Keys are stringified: a list shown as a map has numeric keys (1, 2, ...), which engine.json.map refuses.
    for i, p in ipairs(v) do out[i] = { tostring(p[1]), jsonValue(p[2]) } end
    return Host.json.map(out)
  end
  return v
end

function Renderer.json(data)
  local top = {}
  for _, sec in ipairs(data) do
    if not isEmpty(sec) then
      local v
      if sec.kind == "scalar" then v = sec.value
      elseif sec.kind == "object" then
        local o = {}
        for i, f in ipairs(sec.fields) do o[i] = { jsonKey(f[1]), jsonValue(f[2]) } end
        v = Host.json.map(o)
      elseif sec.kind == "map" then v = jsonValue(sec.map)
      elseif sec.kind == "maps" then
        local o = {}
        for i, s in ipairs(sec.subs) do o[i] = { s[1], jsonValue(s[2]) } end
        v = Host.json.map(o)
      elseif sec.kind == "table" then
        v = {}
        for r, row in ipairs(sec.rows) do
          local o = {}
          for i, c in ipairs(sec.cols) do o[i] = { jsonKey(c), jsonValue(row[i]) } end
          v[r] = Host.json.map(o)
        end
      elseif sec.kind == "strings" then v = sec.items end
      top[#top + 1] = { sec.key, v }
    end
  end
  return Host.json.encode(Host.json.map(top))
end

function Renderer.render(data, format)
  if format == "json" then return Renderer.json(data) end
  return Renderer.compact(data)
end

return Renderer
