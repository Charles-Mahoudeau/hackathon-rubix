-- Prints every texture path the station art can ask for (one per line, relative to assets/), for check_station_assets.sh.
local config = require("@scripts/config/stations")
local Stations = require("@scripts/client/stations")
local Remap = require("@scripts/client/remap")

local seen = {}
local assets = {
  shader = function(path) return path end,
  texture = function(path) seen[path] = true; return path end,
  material = function(def) return def end,
}
Remap.assets, Stations.assets = assets, assets

local all = {}
for _, stage in ipairs({ "warehouse", "tradingPost", "hub", "commandCenter" }) do all[stage] = true end
for id in pairs(config.stations) do
  Stations.entities(id, "idle", { x = 0, y = 0 }, 1, nil, all)
  for _, t in ipairs(Stations.parts(id, all).turrets) do
    if t.kind then
      assets.texture(Stations.turretParked(t.kind))
      for i = 0, 63 do assets.texture(Stations.turretEngaged(t.kind, i / config.turrets.fps, false)) end
    end
  end
end
local list = {}
for path in pairs(seen) do list[#list + 1] = path end
table.sort(list)
for _, path in ipairs(list) do print(path) end
