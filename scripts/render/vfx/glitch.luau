-- AI-error glitch. Triggered only by trigger("ai_error"); never by idle/hover/etc. One short flicker.
local cfg = require("@scripts/config/vfx").glitch

local Glitch = {}

function Glitch.new()
	return { t = nil, rng = cfg.seed }
end

-- Deterministic LCG, one stream per glitch instance (no math.random).
local function nextRand(self): number
	self.rng = (self.rng * 1664525 + 1013904223) % 4294967296
	return self.rng / 4294967296
end

-- Returns true if accepted. Unknown sources (hover, idle, ...) are rejected.
function Glitch.trigger(self, source: string): boolean
	if not cfg.allowedSources[source] then
		return false
	end
	self.t = 0
	return true
end

function Glitch.isActive(self): boolean
	return self.t ~= nil
end

-- Advance by dt; returns nil when inactive, else the frame's effect params.
function Glitch.update(self, dt: number)
	if self.t == nil then
		return nil
	end
	self.t += dt
	if self.t >= cfg.duration then
		self.t = nil
		return nil
	end
	local k = 1 - self.t / cfg.duration -- fades out
	local slices = {}
	for i = 1, cfg.sliceCount do
		slices[i] = { y = nextRand(self), shift = (nextRand(self) * 2 - 1) * cfg.maxSliceShiftPx * k }
	end
	return {
		rgbSplitPx = cfg.rgbSplitPx * k,
		scanlineAlpha = cfg.scanlineAlpha * k,
		freezeFrame = self.t < cfg.holdFrames / 60,
		slices = slices,
	}
end

return Glitch
