-- Deterministic single-line JSON encoder (same value -> same bytes), used for tool schemas, the `json` context
-- format and the output-token estimate. Ordered object: a table with `__map = true` whose array part is {key, value}
-- pairs. Plain array (#t > 0) -> JSON array. Any other table -> object with keys sorted.
local Json = {}

local function esc(s)
  return (s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" elseif c == "\n" then return "\\n" end
    return string.format("\\u%04x", string.byte(c))
  end))
end

local function num(n)
  if n == math.floor(n) and math.abs(n) < 1e15 then return string.format("%d", n) end
  return string.format("%.14g", n)
end

local function enc(v, out)
  local t = type(v)
  if v == nil then out[#out + 1] = "null"
  elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
  elseif t == "number" then out[#out + 1] = num(v)
  elseif t == "string" then out[#out + 1] = '"' .. esc(v) .. '"'
  elseif t == "table" then
    if v.__map then
      out[#out + 1] = "{"
      for i, p in ipairs(v) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = '"' .. esc(p[1]) .. '":'
        enc(p[2], out)
      end
      out[#out + 1] = "}"
    elseif #v > 0 then
      out[#out + 1] = "["
      for i, x in ipairs(v) do
        if i > 1 then out[#out + 1] = "," end
        enc(x, out)
      end
      out[#out + 1] = "]"
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = '"' .. esc(tostring(k)) .. '":'
        enc(v[k], out)
      end
      out[#out + 1] = "}"
    end
  else error("Json.encode: unsupported type " .. t) end
end

function Json.encode(v)
  local out = {}
  enc(v, out)
  return table.concat(out)
end

-- Ordered object helper: Json.map({ {"a", 1}, {"b", 2} }).
function Json.map(pairs_)
  pairs_.__map = true
  return pairs_
end

return Json
