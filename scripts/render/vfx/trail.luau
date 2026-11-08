-- Ship/convoy engine trail: ring buffer of fading points. Feed with position each frame.
local cfg = require("@scripts/config/vfx").trail
local UiTheme = require("@scripts/ui/theme")

local Trail = {}

function Trail.new()
	return { points = {}, acc = 0 }
end

function Trail.update(self, dt: number, x: number, y: number)
	self.acc += dt
	if self.acc >= cfg.sampleInterval then
		self.acc = 0
		table.insert(self.points, { x = x, y = y, age = 0 })
		if #self.points > cfg.maxPoints then
			table.remove(self.points, 1)
		end
	end
	for i = #self.points, 1, -1 do
		local p = self.points[i]
		p.age += dt
		if p.age >= cfg.lifetime then
			table.remove(self.points, i)
		end
	end
end

-- Draw data: position, alpha and width fading with age.
function Trail.draw(self)
	local out = {}
	for i, p in self.points do
		local k = 1 - p.age / cfg.lifetime
		out[i] = { x = p.x, y = p.y, alpha = k, width = cfg.startWidth * k, color = UiTheme.rgba(cfg.color) }
	end
	return out
end

return Trail
