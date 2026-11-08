-- Engine services the headless sim code needs. In the game `Host.json` is the engine's rtype.Json plugin (engine.json.encode / decode /
-- tryDecode / map), read at call time. The tests run on the plain `luau` CLI, where there is no `engine` global (and required modules
-- cannot be given one): there the stand-in in tests/support/engine_json.luau is loaded on first use. No JSON code lives in scripts/.
local Host = {}

local double

Host.json = setmetatable({}, {
  __index = function(_, name)
    local backend = engine ~= nil and engine.json
    if not backend then
      double = double or require("../../tests/support/engine_json")
      backend = double
    end
    return backend[name]
  end,
})

return Host
