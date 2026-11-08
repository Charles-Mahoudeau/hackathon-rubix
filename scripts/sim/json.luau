-- Minimal JSON codec (the engine gives scripts none: docs/Http.md). Pure Luau, deterministic output (sorted keys).
-- encode(value) -> string (a Json.map table keeps its key order), nil encodes as null; errors on NaN/inf, functions and mixed tables. decode(text) -> value, errors on bad input.
local Json = {}

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encodeString(s)
  return '"' .. string.gsub(s, '[%c"\\]', function(c) return ESCAPES[c] or string.format("\\u%04x", string.byte(c)) end) .. '"'
end

local function encodeNumber(n)
  if n ~= n or n == math.huge or n == -math.huge then error("json: cannot encode " .. tostring(n), 0) end
  if n == math.floor(n) and math.abs(n) < 2 ^ 53 then return string.format("%d", n) end
  return string.format("%.17g", n)
end

local encodeValue

local function isArray(t)
  local n = 0
  for _ in pairs(t) do n += 1 end
  for i = 1, n do if t[i] == nil then return false end end
  return true
end

function encodeValue(v, out)
  local t = type(v)
  if v == nil then out[#out + 1] = "null"
  elseif t == "string" then out[#out + 1] = encodeString(v)
  elseif t == "number" then out[#out + 1] = encodeNumber(v)
  elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
  elseif t == "table" then
    if v.__map then
      out[#out + 1] = "{"
      for i, p in ipairs(v) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = encodeString(p[1]) .. ":"
        encodeValue(p[2], out)
      end
      out[#out + 1] = "}"
    elseif isArray(v) then
      out[#out + 1] = "["
      for i = 1, #v do
        if i > 1 then out[#out + 1] = "," end
        encodeValue(v[i], out)
      end
      out[#out + 1] = "]"
    else
      local keys = {}
      for k in pairs(v) do
        if type(k) ~= "string" then error("json: object keys must be strings, got " .. type(k), 0) end
        keys[#keys + 1] = k
      end
      table.sort(keys)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = encodeString(k) .. ":"
        encodeValue(v[k], out)
      end
      out[#out + 1] = "}"
    end
  else error("json: cannot encode a " .. t, 0) end
end

function Json.encode(value)
  local out = {}
  encodeValue(value, out)
  return table.concat(out)
end

-- Ordered object: Json.map({ {"a", 1}, {"b", 2} }) encodes with the keys in the given order (prompts need a stable layout).
function Json.map(pairs_)
  pairs_.__map = true
  return pairs_
end

local UNESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function fail(text, pos, msg) error(("json: %s at byte %d"):format(msg, pos), 0) end

local function skip(text, pos) return string.find(text, "[^ \t\r\n]", pos) or #text + 1 end

local decodeValue

local function decodeString(text, pos)
  local out, i = {}, pos + 1
  while true do
    local j = string.find(text, '["\\%c]', i)
    if not j then fail(text, pos, "unterminated string") end
    out[#out + 1] = string.sub(text, i, j - 1)
    local c = string.sub(text, j, j)
    if c == '"' then return table.concat(out), j + 1 end
    if c ~= "\\" then fail(text, j, "control character in string") end
    local e = string.sub(text, j + 1, j + 1)
    if e == "u" then
      local hex = string.match(text, "^%x%x%x%x", j + 2)
      if not hex then fail(text, j, "bad \\u escape") end
      local cp = tonumber(hex, 16)
      i = j + 6
      if cp >= 0xD800 and cp <= 0xDBFF then -- a high surrogate pairs with the \uDC00-\uDFFF escape that follows
        local low = string.match(text, "^\\u(%x%x%x%x)", i)
        local lo = low and tonumber(low, 16)
        if lo and lo >= 0xDC00 and lo <= 0xDFFF then
          cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
          i = i + 6
        end
      end
      out[#out + 1] = (cp >= 0xD800 and cp <= 0xDFFF) and "\239\191\189" or utf8.char(cp)
    elseif UNESCAPES[e] then
      out[#out + 1] = UNESCAPES[e]
      i = j + 2
    else fail(text, j, "bad escape") end
  end
end

local depth, MAX_DEPTH = 0, 64

local function decodeInner(text, pos)
  pos = skip(text, pos)
  local c = string.sub(text, pos, pos)
  if c == "{" then
    local obj = {}
    pos = skip(text, pos + 1)
    if string.sub(text, pos, pos) == "}" then return obj, pos + 1 end
    while true do
      pos = skip(text, pos)
      if string.sub(text, pos, pos) ~= '"' then fail(text, pos, "expected a key") end
      local key
      key, pos = decodeString(text, pos)
      pos = skip(text, pos)
      if string.sub(text, pos, pos) ~= ":" then fail(text, pos, "expected ':'") end
      obj[key], pos = decodeValue(text, pos + 1)
      pos = skip(text, pos)
      local d = string.sub(text, pos, pos)
      if d == "}" then return obj, pos + 1 end
      if d ~= "," then fail(text, pos, "expected ',' or '}'") end
      pos += 1
    end
  elseif c == "[" then
    local arr = {}
    pos = skip(text, pos + 1)
    if string.sub(text, pos, pos) == "]" then return arr, pos + 1 end
    while true do
      arr[#arr + 1], pos = decodeValue(text, pos)
      pos = skip(text, pos)
      local d = string.sub(text, pos, pos)
      if d == "]" then return arr, pos + 1 end
      if d ~= "," then fail(text, pos, "expected ',' or ']'") end
      pos += 1
    end
  elseif c == '"' then return decodeString(text, pos)
  elseif string.sub(text, pos, pos + 3) == "true" then return true, pos + 4
  elseif string.sub(text, pos, pos + 4) == "false" then return false, pos + 5
  elseif string.sub(text, pos, pos + 3) == "null" then return nil, pos + 4
  end
  local num = string.match(text, "^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
  local n = num and tonumber(num)
  if not n then fail(text, pos, "unexpected character") end
  return n, pos + #num
end

function decodeValue(text, pos)
  depth += 1
  if depth > MAX_DEPTH then fail(text, pos, "nested too deeply") end
  local v, nextPos = decodeInner(text, pos)
  depth -= 1
  return v, nextPos
end

function Json.decode(text)
  if type(text) ~= "string" then error("json: expected a string", 0) end
  depth = 0
  local value, pos = decodeValue(text, 1)
  if skip(text, pos) <= #text then fail(text, skip(text, pos), "trailing data") end
  return value
end

-- For untrusted text (AI replies, network bodies): value, or nil + the error message. A JSON null is nil too.
function Json.tryDecode(text)
  local ok, value = pcall(Json.decode, text)
  if ok then return value end
  return nil, tostring(value)
end

return Json
