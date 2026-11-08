-- Agent context halo: idle / pending (decision pending) / executing.
local cfg = require("@scripts/config/vfx").halo
local UiTheme = require("@scripts/ui/theme")

local Halo = {}

function Halo.style(state: string, t: number)
	local s = cfg[state]
	assert(s, "unknown halo state: " .. tostring(state))
	local pulse = 1
	if s.pulseHz > 0 then
		pulse = 0.65 + 0.35 * math.sin(t * s.pulseHz * 2 * math.pi)
	end
	return { color = UiTheme.rgba(s.color), alpha = s.alpha * pulse, radius = s.radius }
end

return Halo
