-- The branches of the game, in display order. A new branch is one file in this folder plus its line here and its numbers
-- in config/branches.luau; nothing outside branches/ and config/ changes (spec B-0).
local Mining = require("./mining")

return {
  all = { Mining },
}
