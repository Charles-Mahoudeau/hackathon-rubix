-- The starting point of a game: a project with one counter, a window on the client and a network port.
-- Run it from the folder of the engine (the one with `runtime/`):
--   runtime/aylo-runtime --server --game templates/game        the server, no window
--   runtime/aylo-runtime --game templates/game                 a client, in a window
--   runtime/aylo-runtime --game templates/game --headless      a client without a window, to test the network

engine.settings.network.port = engine.args.port or 4242
engine.settings.scripts.server = "server/main"

local plugins = {}

if engine.isServer then
	-- Axis AI (GR5-15): requests go out from the server only. The keys are read from the environment by the engine
	-- (AXIS_API_KEY = apk-... platform key, AXIS_GATEWAY_KEY = Relais sk-... key) and never pass through a script.
	-- Keep in step with scripts/config/ai.luau.
	table.insert(plugins, "rtype.Http")
	engine.settings.http.allowedHosts = { "api.platform.lacale-atlantle.com", "relais.lacale-atlantle.com" }
	engine.settings.http.secrets = { "AXIS_API_KEY", "AXIS_GATEWAY_KEY" }
end

if engine.isClient then
	engine.settings.network.host = engine.args.host or "127.0.0.1"

	if engine.args.headless then
		-- The client sends its inputs to the server, so it needs the input plugin even with no window.
		table.insert(plugins, "rtype.Input")
	else
		table.insert(plugins, "rtype.graphics")
		engine.settings.platform = "glfw"
		engine.settings.renderer = "vulkan"
		engine.settings.window.title = "My game"
	end
end

if #plugins > 0 then
	engine.settings.plugins = plugins
end
