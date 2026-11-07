-- Headless checks. Load order mimics the engine: scripts/**/*.luau sorted, shared globals, no require.
-- Runner must load scripts/config/vfx.luau then scripts/render/vfx/*.luau before this file.

local g = Glitch.new()
for _, src in { "idle", "hover", "select", "" } do
	assert(not Glitch.trigger(g, src), "glitch must reject " .. src)
	assert(Glitch.update(g, 0.016) == nil and not Glitch.isActive(g))
end
assert(Glitch.trigger(g, "ai_error"))
assert(Glitch.update(g, 0.016) ~= nil)
Glitch.update(g, 1.0)
assert(not Glitch.isActive(g), "glitch is a short flicker")

local safe, risky = Route.style(0.1, true, 0.5), Route.style(0.9, true, 0.5)
assert(not safe.risky and risky.risky and safe.color[3] > safe.color[1] and risky.color[1] > risky.color[3])
assert(Route.style(0.1, false, 3).dashOffset == 0 and Route.style(0.1, true, 0.5).dashOffset > 0)

local a, b, c = Halo.style("idle", 0.1), Halo.style("pending", 0.1), Halo.style("executing", 0.1)
assert(a.radius ~= b.radius and b.radius ~= c.radius and a.alpha ~= c.alpha)

assert(not Bloom.isNeon(0.9, false) and Bloom.isNeon(0.9, true) and not Bloom.isNeon(0.1, true))
print("vfx tests passed")
