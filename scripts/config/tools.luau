-- Tool schemas: shown in the [TOOLS] section of every prompt (spec §11, D14) and checked on every AI reply (spec §10.3).
-- Each equipped tool adds its schema to every prompt, so the schema text is the tool's token weight. Static text only.
-- Arg spec: { type = "string"|"integer"|"number"|"any", required, enum, min, max, maxLength, desc }.
local function str(desc, extra)
  local s = { type = "string", desc = desc }
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end

return {
  order = { "mine", "return", "sell", "store", "scan", "report", "wait", "run_skill", "ship" },
  schemas = {
    mine = { description = "Fly to a vein, mine it, stop at the target hold %.",
      args = { vein = str("known vein id", { required = true }),
        stop_at_hold_pct = { type = "integer", min = 10, max = 100, desc = "default 100" } } },
    ["return"] = { description = "Fly back to a dock.",
      args = { to = str("default home", { enum = { "home", "local_depot" } }) } },
    sell = { description = "Sell the hold (Miner, docked) or a warehouse stock (Logistician) at a buyer.",
      args = { buyer = str("default hmc", { enum = { "hmc" } }), planet = str("planet id"),
        resource = str("ore id (Logistician)"), qty = { type = "any", desc = "int>=1|all (Logistician)" } } },
    store = { description = "Move a resource into the warehouse.",
      args = { resource = str("ore id", { required = true }), amount = { type = "number", required = true, min = 1 } } },
    scan = { description = "Reveal exact richness and reserve of a planet's veins.",
      args = { planet = str("planet id", { required = true }) } },
    report = { description = "Send a short message to the player.",
      args = { message = str("text", { required = true, maxLength = 200 }) } },
    wait = { description = "Do nothing for a while.",
      args = { seconds = { type = "integer", required = true, min = 10, max = 300 } } },
    run_skill = { description = "Run a saved skill.", args = { name = str("skill name", { required = true }) } },
    ship = { description = "Send a freighter to a market.",
      args = { resource = str("ore id", { required = true }), qty = { type = "any", desc = "int 1-500|all" },
        destination = str("market", { required = true, enum = { "orbis", "halcyon", "meridian" } }) } },
  },
}
