-- Display words for sim events (GR5-92): maps machine codes to the strings of config/copy.luau. The codes themselves stay in
-- the records, history and prompts; only what the player reads goes through here. Pure Luau, headless.
local Words = require("@scripts/config/copy")

local Copy = {}

-- The player-facing text of a refused call's error code; unknown codes are an ordinary failed action.
function Copy.error(code)
  local e = tostring(code)
  local exact = Words.errors.byCode[e]
  if exact then return exact end
  for _, p in ipairs(Words.errors.byPrefix) do
    if e:sub(1, #p.prefix) == p.prefix then return p.text end
  end
  return Words.errors.failed
end

function Copy.alert(kind) return Words.alerts[kind] or kind end

return Copy
