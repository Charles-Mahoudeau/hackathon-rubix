-- Shader colour uniforms are written to an sRGB swapchain, so palette hex (sRGB) must be handed over as linear light.
local Linear = {}

local function toLinear(c: number)
	if c <= 0.04045 then return c / 12.92 end
	return ((c + 0.055) / 1.055) ^ 2.4
end

function Linear.fromHex(hex: number)
	return {
		x = toLinear(bit32.extract(hex, 16, 8) / 255),
		y = toLinear(bit32.extract(hex, 8, 8) / 255),
		z = toLinear(bit32.extract(hex, 0, 8) / 255),
		w = 1,
	}
end

return Linear
