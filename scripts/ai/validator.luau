-- Validation of an AI reply, in the order of spec §10.3. Never throws; the first failure is the error returned.
local Json = require("@scripts/sim/json")

local Validator = {}

-- The reply may wrap its JSON in a code fence or a sentence: take the outermost {...}.
local function extractObject(text)
  local first = text:find("{", 1, true)
  if not first then return nil end
  local last = first
  for i = #text, first, -1 do
    if text:sub(i, i) == "}" then last = i; break end
  end
  return text:sub(first, last)
end

local function checkArg(name, spec, value)
  local t = spec.type
  if t == "string" then
    if type(value) ~= "string" then return "arg '" .. name .. "' must be a string" end
    if spec.maxLength and #value > spec.maxLength then return "arg '" .. name .. "' is too long" end
  elseif t == "number" or t == "integer" then
    if type(value) ~= "number" then return "arg '" .. name .. "' must be a number" end
    if t == "integer" and value ~= math.floor(value) then return "arg '" .. name .. "' must be an integer" end
    if spec.min and value < spec.min then return "arg '" .. name .. "' is below " .. spec.min end
    if spec.max and value > spec.max then return "arg '" .. name .. "' is above " .. spec.max end
  end
  if spec.enum then
    for _, e in ipairs(spec.enum) do if e == value then return nil end end
    return "arg '" .. name .. "' must be one of " .. table.concat(spec.enum, ", ")
  end
  return nil
end

-- equipped: { [toolName] = schema } (the tools this agent holds, with their args specs). cfg.reasoningMaxChars.
-- Returns ok, toolCall | nil, error.
function Validator.parse(text, equipped, cfg)
  if type(text) ~= "string" or text:match("^%s*$") then return false, nil, "empty reply" end
  local body = extractObject(text)
  if not body then return false, nil, "no JSON object in reply" end
  local obj, err = Json.tryDecode(body)
  if type(obj) ~= "table" then return false, nil, "bad JSON: " .. tostring(err or "not an object") end
  if type(obj.tool) ~= "string" then return false, nil, "missing 'tool'" end
  local schema = equipped[obj.tool]
  if not schema then return false, nil, "unknown or unequipped tool: " .. obj.tool end
  local args = obj.args == nil and {} or obj.args
  if type(args) ~= "table" then return false, nil, "'args' must be an object" end
  for name, spec in pairs(schema.args or {}) do
    if args[name] == nil then
      if spec.required then return false, nil, "missing arg '" .. name .. "'" end
    else
      local e = checkArg(name, spec, args[name])
      if e then return false, nil, e end
    end
  end
  for name in pairs(args) do
    if not (schema.args and schema.args[name]) then return false, nil, "unexpected arg '" .. tostring(name) .. "'" end
  end
  local reasoning = type(obj.reasoning) == "string" and obj.reasoning or ""
  local max = cfg.reasoningMaxChars
  local cut = utf8.offset(reasoning, max + 1)
  if cut then reasoning = reasoning:sub(1, cut - 1) end
  return true, { tool = obj.tool, args = args, reasoning = reasoning }
end

return Validator
