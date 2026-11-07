-- Shared neon-bloom primitive. Every other VFX/asset ticket asks this module for its params.
local cfg = require("config/vfx").bloom
local M = {}

-- Is this pixel part of the bloom? tagged = neon mask value in [0,1].
function M.isNeon(luminance: number, tagged: boolean?): boolean
	if cfg.neonTagOnly then
		return tagged == true and luminance >= cfg.threshold
	end
	return luminance >= cfg.threshold
end

-- Parameters for the bloom pass; `scale` (default 1) lets a caller dim/boost without a copy of the pass.
function M.params(scale: number?)
	return {
		threshold = cfg.threshold,
		intensity = cfg.intensity * (scale or 1),
		blurPasses = cfg.blurPasses,
		blend = cfg.blend,
	}
end

return M
