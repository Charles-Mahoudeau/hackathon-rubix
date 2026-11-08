-- Token estimator (spec §6.4): ceil(utf8 length / 4). Used for the Compute charge at send and for budgeting.
local Tokens = {}

function Tokens.estimate(text)
  if type(text) ~= "string" or text == "" then return 0 end
  return math.ceil((utf8.len(text) or #text) / 4)
end

-- Compute cost of a decision (spec §6.4): tokens / 1000, rounded up to 0.1.
function Tokens.compute(tokens)
  return math.max(0.1, math.ceil(tokens / 100 - 1e-9) / 10)
end

return Tokens
