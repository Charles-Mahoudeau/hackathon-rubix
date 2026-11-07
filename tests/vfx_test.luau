-- Headless checks (run with a Luau runner that supports require by path).
local glitch = require("render/vfx/glitch")
local route = require("render/vfx/route")
local halo = require("render/vfx/halo")
local bloom = require("render/vfx/bloom")

local g = glitch.new()
for _, src in { "idle", "hover", "select", "" } do
	assert(not glitch.trigger(g, src), "glitch must reject " .. src)
	assert(glitch.update(g, 0.016) == nil and not glitch.isActive(g))
end
assert(glitch.trigger(g, "ai_error"))
assert(glitch.update(g, 0.016) ~= nil)
glitch.update(g, 1.0)
assert(not glitch.isActive(g), "glitch is a short flicker")

local safe, risky = route.style(0.1, true, 0.5), route.style(0.9, true, 0.5)
assert(not safe.risky and risky.risky and safe.color[3] > safe.color[1] and risky.color[1] > risky.color[3])
assert(route.style(0.1, false, 3).dashOffset == 0 and route.style(0.1, true, 0.5).dashOffset > 0)

local a, b, c = halo.style("idle", 0.1), halo.style("pending", 0.1), halo.style("executing", 0.1)
assert(a.radius ~= b.radius and b.radius ~= c.radius and a.alpha ~= c.alpha)

assert(not bloom.isNeon(0.9, false) and bloom.isNeon(0.9, true) and not bloom.isNeon(0.1, true))
print("vfx tests passed")
