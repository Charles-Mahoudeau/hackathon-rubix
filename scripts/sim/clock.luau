-- Game speed (spec §3): x1 / x4 / x16 and pause, from the first minute. The sim itself always steps at 10 Hz of game time;
-- speed only changes how many steps the host runs per real second, so skills, offline progress and the markets are
-- speed-independent (speed changes are events, never log lines, so a save is the same at any speed). The sim keeps `speed` / `paused` and `realTicks` (real time elapsed, in ticks) for the AI budget.
local Clock = {}

function Clock.init(sim)
  sim.speed, sim.paused, sim.clockAcc, sim.realTicks = sim.b.speed.default, false, 0, 0
end

function Clock.isLevel(sim, n)
  for _, level in ipairs(sim.b.speed.levels) do if level == n then return true end end
  return false
end

-- -> ok, err. Unknown speeds are refused; picking a speed also resumes a paused game.
function Clock.setSpeed(sim, n)
  if not Clock.isLevel(sim, n) then return false, "bad speed" end
  local was = sim.speed
  sim.speed, sim.paused = n, false
  if was ~= n then
    sim:emit("speed_changed", { speed = n })
  end
  return true
end

function Clock.setPaused(sim, paused)
  paused = paused == true
  if sim.paused == paused then return end
  sim.paused = paused
  sim:emit("speed_changed", { speed = sim.speed, paused = paused })
end

-- Runs the steps due after `dt` real seconds and returns how many. Nothing runs while paused. A stall longer than
-- maxStepsPerFrame steps drops the rest instead of spiralling.
local function runSteps(sim, dt: number, step: number): number
  sim.clockAcc += dt * sim.speed
  local n = math.floor(sim.clockAcc / step + 1e-9)
  local cap = sim.b.speed.maxStepsPerFrame
  if n > cap then n = cap; sim.clockAcc = n * step end
  sim.clockAcc -= n * step
  for _ = 1, n do sim:step() end
  return n
end

function Clock.advance(sim, dt: number): number
  if type(dt) ~= "number" or dt ~= dt or dt <= 0 then return 0 end
  local step = sim.b.tickSeconds
  local n = sim.paused and 0 or runSteps(sim, dt, step)
  -- The hourly AI token window is REAL time (spec §10.4): it also passes while paused and over a dropped stall. Each step
  -- already added 1/speed, so only the rest of `dt` is added here.
  sim.realTicks += dt / step - n / sim.speed
  return n
end

-- Control rows for the UI: { action, label, active }.
function Clock.controls(sim)
  local rows = { { action = "speed.pause", label = "||", active = sim.paused } }
  for _, level in ipairs(sim.b.speed.levels) do
    rows[#rows + 1] = { action = "speed." .. level, label = "x" .. level, active = not sim.paused and sim.speed == level }
  end
  return rows
end

-- UI click: "speed.pause" toggles, "speed.<n>" selects. Returns true when the action was a speed action.
function Clock.act(sim, action: string): boolean
  if action == "speed.pause" then Clock.setPaused(sim, not sim.paused); return true end
  local n = action:match("^speed%.(%d+)$")
  if n then Clock.setSpeed(sim, tonumber(n)); return true end
  return false
end

return Clock
