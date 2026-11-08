-- GR5-53 gate: icons show up next to resources, agents, tools and missions, tinted from the palette; the click cue exists.
-- Headless: with no engine loader an icon's texture is its file path (ui/icon.luau).
local Sim = require("@scripts/sim/sim")
local Ai = require("@scripts/sim/ai")
local Skills = require("@scripts/sim/skills")
local Shell = require("@scripts/ui/shell")
local IconSet = require("@scripts/ui/icon_set")
local Icon = require("@scripts/ui/icon")
local Audio = require("@scripts/client/audio")
local Cfg = require("@scripts/config/audio")

local function icons(spec, out)
  out = out or {}
  if spec.image and spec.image.slice == nil then out[spec.image.texture] = (out[spec.image.texture] or 0) + 1 end
  for _, c in ipairs(spec.children or {}) do icons(c, out) end
  return out
end
local function onScreen(sim, id, opts) return icons((Shell.spec(sim, id, opts or {}))) end

-- helpers: lookups only answer for icons the set has
assert(Icon.toolKey("mine") == "tool.mine" and Icon.toolKey("wait") == nil)
assert(Icon.agentKey("miner") == "agent.miner" and Icon.agentKeyOfId("logistician_2") == "agent.logistician")
assert(Icon.resourceKey("cobalt") == "resource.cobalt" and Icon.resourceKey("iridium") == nil)
local blank = Icon.node(nil, 12)
assert(blank.image == nil and blank.style.width == 12, "no key: an empty box that keeps the column aligned")
for key, def in pairs(IconSet.icons) do assert(def.file:match("%.png$"), key .. ": the engine decodes rasters only") end

-- top bar (every screen): credits, Compute, reputation
local sim = Sim.new()
sim.tier = 5
sim:setDecider(Ai.decide)
sim:setDirective("miner", "Mine cobalt on K3 until the hold is 100%, then sell at HMC.")
sim:run(6000)
for _, id in ipairs({ "map", "shop", "team", "missions", "archive" }) do
  local seen = onScreen(sim, id)
  for _, f in ipairs({ "resource_credits", "resource_compute", "resource_reputation" }) do
    assert(seen["icons/" .. f .. ".png"], id .. ": top bar icon " .. f)
  end
end

-- feed: the running Miner's calls carry an agent icon and a tool icon
local feed = onScreen(sim, "map")
assert(feed["icons/agent_miner.png"] and (feed["icons/tool_mine.png"] or feed["icons/tool_sell.png"] or feed["icons/tool_scan.png"]), "feed line icons")

-- per screen
assert(onScreen(sim, "team")["icons/agent_miner.png"] >= 2, "team row")
assert(onScreen(sim, "agents")["icons/tool_mine.png"], "editor tool list")
assert(onScreen(sim, "missions")["icons/resource_credits.png"] >= 3, "mission rewards")
assert(onScreen(sim, "shop")["icons/resource_credits.png"] >= 2, "shop prices")
assert(onScreen(sim, "logs")["icons/agent_miner.png"] >= 1, "log header")
assert(Skills.save(sim, { name = "loop-k1", agent_type = "miner", params = {}, loop = true,
  steps = { { tool = "mine", args = { vein = "K1" } }, { tool = "return" }, { tool = "sell" } } }, { agent = "miner" }))
local archive = onScreen(sim, "archive")
assert(archive["icons/tool_mine.png"] and archive["icons/tool_sell.png"] and archive["icons/tool_return.png"], "archive steps")

-- a failed call reads red in the feed: same icon, error tint
local failing = Sim.new()
failing.feed[#failing.feed + 1] = { agent = "miner", kind = "call", tool = "mine", status = "failed", text = "mine() -> no vein" }
local function tintOf(spec, texture)
  if spec.image and spec.image.texture == texture then return spec.image.color end
  for _, c in ipairs(spec.children or {}) do local t = tintOf(c, texture) if t then return t end end
  return nil
end
local red = tintOf((Shell.spec(failing, "map", {})), "icons/tool_mine.png")
assert(red and red[1] > red[3], "a failed call's icon takes the error colour")

-- the UI click cue is routed and plays at x16 too
local a = Audio.new()
Audio.beginFrame(a, 0)
local play = Audio.onEvent(a, { name = "ui_click" }, { speed = 1 })
assert(play and play.cue == "click" and play.file == Cfg.cues.click.file)
print("icons OK")
