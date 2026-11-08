-- Test double for the engine's rtype.Json plugin (rtype docs/Json.md). The headless tests run on the plain `luau` CLI, which has no
-- engine, so scripts/sim/host.luau loads this stand-in when `engine` is absent. Same contract as the plugin: sorted object keys, engine.json.map
-- ordered objects marked in a weak set (no field), `[]` for the empty table, null array elements dropped, a strict decode (leading
-- zeros, lone surrogates, invalid UTF-8, out-of-range numbers), nesting capped at 64. The game never loads it: inside the game
-- Host.json is the real plugin.
local Json = {}

local MAX_DEPTH = 64
local ordered = setmetatable({}, { __mode = "k" })

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encodeString(s)
  return '"' .. string.gsub(s, '[%c"\\]', function(c) return ESCAPES[c] or string.format("\\u%04x", string.byte(c)) end) .. '"'
end

local function encodeNumber(n)
  if n ~= n or n == math.huge or n == -math.huge then error("json: cannot encode " .. tostring(n), 0) end
  if n == math.floor(n) and math.abs(n) < 2 ^ 53 then return string.format("%d", n) end
  for digits = 15, 17 do
    local s = string.format("%." .. digits .. "g", n)
    if tonumber(s) == n then return s end
  end
  return string.format("%.17g", n)
end

local function count(t)
  local n = 0
  for _ in pairs(t) do n += 1 end
  return n
end

local function isArray(t)
  for i = 1, count(t) do if rawget(t, i) == nil then return false end end
  return true
end

local encodeValue

function encodeValue(v, out, depth)
  local t = type(v)
  if v == nil then out[#out + 1] = "null"
  elseif t == "string" then out[#out + 1] = encodeString(v)
  elseif t == "number" then out[#out + 1] = encodeNumber(v)
  elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
  elseif t == "table" then
    if depth >= MAX_DEPTH then error("json: nested too deeply to encode", 0) end
    if ordered[v] then
      if not isArray(v) then error("json: a map must be a list of { key, value } entries with no gap and no other key", 0) end
      out[#out + 1] = "{"
      for i = 1, #v do
        local p = v[i]
        if type(p) ~= "table" or type(p[1]) ~= "string" then error("json: map entry " .. i .. " must be { key, value } with a string key", 0) end
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = encodeString(p[1]) .. ":"
        encodeValue(p[2], out, depth + 1)
      end
      out[#out + 1] = "}"
    elseif isArray(v) then
      out[#out + 1] = "["
      for i = 1, #v do
        if i > 1 then out[#out + 1] = "," end
        encodeValue(v[i], out, depth + 1)
      end
      out[#out + 1] = "]"
    else
      local keys = {}
      for k in pairs(v) do
        if type(k) ~= "string" then error("json: object keys must be strings, got a " .. type(k) .. " key (a table cannot mix array and object keys)", 0) end
        keys[#keys + 1] = k
      end
      table.sort(keys)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = encodeString(k) .. ":"
        encodeValue(v[k], out, depth + 1)
      end
      out[#out + 1] = "}"
    end
  else error("json: cannot encode a " .. t, 0) end
end

function Json.encode(value)
  local out = {}
  encodeValue(value, out, 0)
  return table.concat(out)
end

function Json.map(entries)
  if type(entries) ~= "table" then error("json: map expects a list of { key, value } entries", 0) end
  ordered[entries] = true
  return entries
end

local UNESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function fail(pos, msg) error(("json: malformed JSON at byte %d: %s"):format(pos, msg), 0) end

local function skip(text, pos) return string.find(text, "[^ \t\r\n]", pos) or #text + 1 end

local decodeValue

local function decodeString(text, pos)
  local out, i = {}, pos + 1
  while true do
    local j = string.find(text, '["\\%c]', i)
    if not j then fail(pos, "unterminated string") end
    out[#out + 1] = string.sub(text, i, j - 1)
    local c = string.sub(text, j, j)
    if c == '"' then return table.concat(out), j + 1 end
    if c ~= "\\" then fail(j, "control character in string") end
    local e = string.sub(text, j + 1, j + 1)
    if e == "u" then
      local hex = string.match(text, "^%x%x%x%x", j + 2)
      if not hex then fail(j, "bad \\u escape") end
      local cp = tonumber(hex, 16)
      i = j + 6
      if cp >= 0xD800 and cp <= 0xDBFF then
        local low = string.match(text, "^\\u(%x%x%x%x)", i)
        local lo = low and tonumber(low, 16)
        if not (lo and lo >= 0xDC00 and lo <= 0xDFFF) then fail(j, "lone surrogate") end
        cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
        i = i + 6
      elseif cp >= 0xDC00 and cp <= 0xDFFF then fail(j, "lone surrogate") end
      out[#out + 1] = utf8.char(cp)
    elseif UNESCAPES[e] then
      out[#out + 1] = UNESCAPES[e]
      i = j + 2
    else fail(j, "bad escape") end
  end
end

local function decodeInner(text, pos, depth)
  pos = skip(text, pos)
  local c = string.sub(text, pos, pos)
  if c == "{" then
    local obj = {}
    pos = skip(text, pos + 1)
    if string.sub(text, pos, pos) == "}" then return obj, pos + 1 end
    while true do
      pos = skip(text, pos)
      if string.sub(text, pos, pos) ~= '"' then fail(pos, "expected a key") end
      local key
      key, pos = decodeString(text, pos)
      pos = skip(text, pos)
      if string.sub(text, pos, pos) ~= ":" then fail(pos, "expected ':'") end
      obj[key], pos = decodeValue(text, pos + 1, depth)
      pos = skip(text, pos)
      local d = string.sub(text, pos, pos)
      if d == "}" then return obj, pos + 1 end
      if d ~= "," then fail(pos, "expected ',' or '}'") end
      pos += 1
    end
  elseif c == "[" then
    local arr = {}
    pos = skip(text, pos + 1)
    if string.sub(text, pos, pos) == "]" then return arr, pos + 1 end
    while true do
      local v
      v, pos = decodeValue(text, pos, depth)
      if v ~= nil then arr[#arr + 1] = v end
      pos = skip(text, pos)
      local d = string.sub(text, pos, pos)
      if d == "]" then return arr, pos + 1 end
      if d ~= "," then fail(pos, "expected ',' or ']'") end
      pos += 1
    end
  elseif c == '"' then return decodeString(text, pos)
  elseif string.sub(text, pos, pos + 3) == "true" then return true, pos + 4
  elseif string.sub(text, pos, pos + 4) == "false" then return false, pos + 5
  elseif string.sub(text, pos, pos + 3) == "null" then return nil, pos + 4
  end
  local num = string.match(text, "^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
  local n = num and tonumber(num)
  if not n then fail(pos, "unexpected character") end
  if string.match(num, "^-?0%d") then fail(pos, "leading zero") end
  if n ~= n or n == math.huge or n == -math.huge then fail(pos, "number out of range") end
  return n, pos + #num
end

function decodeValue(text, pos, depth)
  depth += 1
  if depth > MAX_DEPTH then fail(pos, "nested too deeply") end
  return decodeInner(text, pos, depth)
end

function Json.decode(text)
  if type(text) ~= "string" then error("json: expected a string, got a " .. type(text), 0) end
  if not utf8.len(text) then fail(1, "invalid UTF-8") end
  local value, pos = decodeValue(text, 1, 0)
  if skip(text, pos) <= #text then fail(skip(text, pos), "trailing data") end
  return value
end

function Json.tryDecode(text)
  local ok, value = pcall(Json.decode, text)
  if ok then return value end
  return nil, tostring(value)
end

return Json
