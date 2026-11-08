-- Animated trade-route style: blue = safe, orange = risky; dashes move when a convoy is active.
local cfg = VfxConfig.route
Route = {}

-- risk in [0,1]; active = convoy on the route; t = time in seconds.
function Route.style(risk: number, active: boolean, t: number)
	local risky = risk >= cfg.riskyThreshold
	local base = if risky then cfg.risky else cfg.safe
	local period = cfg.dashLength + cfg.gapLength
	return {
		color = { base[1], base[2], base[3], if active then cfg.activeAlpha else cfg.idleAlpha },
		dash = cfg.dashLength,
		gap = cfg.gapLength,
		dashOffset = if active then (t * cfg.pulseSpeed) % period else 0,
		risky = risky,
	}
end


