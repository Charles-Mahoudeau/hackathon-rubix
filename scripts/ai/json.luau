-- Minimal JSON for the AI layer (the engine has none yet). encode() is deterministic (sorted keys);
-- decode() never throws: it returns value, or nil + error.
local Json = {}

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encodeString(s)
  return '"' .. s:gsub('[%c"\\]', function(c) return ESC[c] or string.format("\\u%04x", string.byte(c)) end) .. '"'
end

local function isArray(t)
  local n = 0
  for _ in pairs(t) do n += 1 end
  return n == #t
end

local function enc(v, out)
  local ty = type(v)
  if v == nil then out[#out + 1] = "null"
  elseif ty == "boolean" then out[#out + 1] = v and "true" or "false"
  elseif ty == "number" then
    assert(v == v and v ~= math.huge and v ~= -math.huge, "Json.encode: non-finite number")
    out[#out + 1] = (v == math.floor(v) and math.abs(v) < 1e15) and string.format("%d", v) or string.format("%.14g", v)
  elseif ty == "string" then out[#out + 1] = encodeString(v)
  elseif ty == "table" then
    if isArray(v) then
      out[#out + 1] = "["
      for i, x in ipairs(v) do
        if i > 1 then out[#out + 1] = "," end
        enc(x, out)
      end
      out[#out + 1] = "]"
    else
      local keys = {}
      for k in pairs(v) do
        assert(type(k) == "string", "Json.encode: object keys must be strings")
        keys[#keys + 1] = k
      end
      table.sort(keys)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = encodeString(k) .. ":"
        enc(v[k], out)
      end
      out[#out + 1] = "}"
    end
  else error("Json.encode: unsupported type " .. ty) end
end

function Json.encode(v)
  local out = {}
  enc(v, out)
  return table.concat(out)
end

local MAX_DEPTH = 32

local function skip(s, i)
  return s:find("[^ \t\r\n]", i) or #s + 1
end

local function fail(i, msg) error({ json = msg .. " at " .. i }, 0) end

local parseValue

local function parseString(s, i)
  local out, j = {}, i + 1
  while true do
    local k = s:find('["\\%c]', j)
    if not k then fail(i, "unterminated string") end
    out[#out + 1] = s:sub(j, k - 1)
    local c = s:sub(k, k)
    if c == '"' then return table.concat(out), k + 1 end
    if c ~= "\\" then fail(k, "control character in string") end
    local e = s:sub(k + 1, k + 1)
    local simple = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
    if simple[e] then out[#out + 1] = simple[e]; j = k + 2
    elseif e == "u" then
      local hex = s:match("^%x%x%x%x", k + 2)
      if not hex then fail(k, "bad \\u escape") end
      local cp = tonumber(hex, 16)
      j = k + 6
      if cp >= 0xD800 and cp <= 0xDBFF then
        local lo = s:match("^\\u(%x%x%x%x)", j)
        local lcp = lo and tonumber(lo, 16)
        if lcp and lcp >= 0xDC00 and lcp <= 0xDFFF then
          cp = 0x10000 + (cp - 0xD800) * 0x400 + (lcp - 0xDC00)
          j += 6
        else cp = 0xFFFD end
      elseif cp >= 0xDC00 and cp <= 0xDFFF then cp = 0xFFFD end
      out[#out + 1] = utf8.char(cp)
    else fail(k, "bad escape") end
  end
end

function parseValue(s, i, depth)
  if depth > MAX_DEPTH then fail(i, "too deep") end
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local obj = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
      if s:sub(i, i) ~= '"' then fail(i, "expected key") end
      local key
      key, i = parseString(s, i)
      i = skip(s, i)
      if s:sub(i, i) ~= ":" then fail(i, "expected ':'") end
      obj[key], i = parseValue(s, i + 1, depth + 1)
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "}" then return obj, i + 1 end
      if d ~= "," then fail(i, "expected ',' or '}'") end
      i = skip(s, i + 1)
    end
  elseif c == "[" then
    local arr, n = {}, 0
    i = skip(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
      local v
      v, i = parseValue(s, i, depth + 1)
      n += 1
      arr[n] = v
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "]" then return arr, i + 1 end
      if d ~= "," then fail(i, "expected ',' or ']'") end
      i += 1
    end
  elseif c == '"' then return parseString(s, i)
  elseif s:sub(i, i + 3) == "true" then return true, i + 4
  elseif s:sub(i, i + 4) == "false" then return false, i + 5
  elseif s:sub(i, i + 3) == "null" then return nil, i + 4
  end
  local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
  local n = num and tonumber(num)
  if not n then fail(i, "unexpected character") end
  return n, i + #num
end

function Json.decode(s)
  if type(s) ~= "string" then return nil, "not a string" end
  local ok, v, i = pcall(parseValue, s, 1, 0)
  if not ok then return nil, type(v) == "table" and v.json or tostring(v) end
  if skip(s, i) <= #s then return nil, "trailing characters at " .. i end
  return v
end

return Json
