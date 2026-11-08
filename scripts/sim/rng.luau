-- Seeded streams stored in `sim.rng` (spec §3): the whole state of a stream is one integer, so a save resumes it exactly.
-- Linear congruential, computed without floating-point rounding (the multiply is split in 16-bit halves).
local Rng = {}

local A, C, M = 1103515245, 12345, 2147483648

function Rng.seedFor(seed: number, mult: number): number return (seed * mult + 7) % M end

-- Next value in [0, 1) of stream `key` of the table `rng`.
function Rng.next(rng, key: string): number
  local s = rng[key]
  local lo = s % 65536
  local hi = (s - lo) / 65536
  s = (((hi * A) % 32768) * 65536 + lo * A + C) % M
  rng[key] = s
  return s / M
end

-- Normal(0, sigma) from two draws (Box-Muller).
function Rng.normal(rng, key: string, sigma: number): number
  local u1, u2 = Rng.next(rng, key), Rng.next(rng, key)
  if u1 < 1e-9 then u1 = 1e-9 end
  return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2) * sigma
end

-- Uniform integer in [1, n].
function Rng.pick(rng, key: string, n: number): number return 1 + math.floor(Rng.next(rng, key) * n) end

return Rng
