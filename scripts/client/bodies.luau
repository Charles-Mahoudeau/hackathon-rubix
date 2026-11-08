-- Asteroids (veins), stars and galaxy backdrop built on the planet shader (see Planet.fromDef). Client only.
-- Each returns an entity description for ctx.commands:spawn(). No new shader code.
-- Stars: this is the only star renderer; the GR5-17 background must call Star.new rather than build its own.
local Planet = require("./planet")
local config = require("@scripts/config/bodies")

local Asteroid = {}
local Star = {}
local Galaxy = {}

local function look(base, land)
	return {
		seed = base.seed, tilt = base.tilt or 0, phase = base.phase or 0,
		waterLevel = 0, cloudCover = 1, -- all rock, no clouds
		land = land, water = land, cloud = { "bone", "ice" },
		pixels = base.pixels, layer = base.layer,
	}
end

local function tierFor(richness: number)
	for _, t in ipairs(config.asteroid.tiers) do
		if richness <= t.max then
			return t, "r" .. tostring(_)
		end
	end
end

-- veinSeed: the planet's stable seed (number); index: vein number 1..4; richness: 0.5..1.5.
-- revealed=false (before `scan`) draws a dark rock that hides richness (same size too); true shows the richness tell.
function Asteroid.new(veinSeed: number, index: number, richness: number, revealed: boolean, position)
	local c = config.asteroid
	local seed = veinSeed + index * c.seedStep
	local radius, land, state
	if revealed then
		local tier, name = tierFor(richness)
		land, state = tier.land, name
		radius = c.baseRadius * (1 + (richness - 1) * c.richnessScale)
	else
		land, state = c.hidden.land, "hidden"
		radius = c.baseRadius
	end
	local def = look({ seed = seed, phase = index * 17, pixels = c.pixels }, land)
	def.size = c.size
	-- the material name is keyed by seed+state, so flipping state (call Asteroid.new again, swap SpriteRenderer) is cheap
	return Planet.fromDef("asteroid." .. seed .. "." .. state, def, radius, position)
end

function Star.new(radius: number, position)
	local c = config.star
	local def = look({ seed = c.seed, pixels = c.pixels, layer = c.layer }, c.land)
	def.size = c.size
	return Planet.fromDef("star", def, radius, position)
end

function Galaxy.new(radius: number, position)
	local c = config.galaxy
	local def = look({ seed = c.seed, tilt = c.tilt, pixels = c.pixels, layer = c.layer }, c.land)
	def.size = c.size
	return Planet.fromDef("galaxy", def, radius, position)
end

return { Asteroid = Asteroid, Star = Star, Galaxy = Galaxy }
