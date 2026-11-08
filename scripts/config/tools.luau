-- Tool schemas: shown in the [TOOLS] section of every prompt (spec §11, D14) and checked on every AI reply (spec §10.3).
-- Each equipped tool adds its schema to every prompt, so the schema text is the tool's token weight. Static text only.
-- Arg spec: { type = "string"|"integer"|"number"|"any", required, enum, min, max, maxLength, desc }.
local function str(desc, extra)
  local s = { type = "string", desc = desc }
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end

return {
  -- `recent` rows in the agent context (spec §9.2.2/§11): argument aliases and the order args and result fields appear in.
  argAlias = { stop_at_hold_pct = "pct" },
  argOrder = {
    mine = { "vein", "stop_at_hold_pct" }, ["return"] = { "to" }, sell = { "buyer", "planet", "resource", "qty" },
    store = { "resource", "qty" }, ship = { "resource", "qty", "destination" }, set_order = { "agent", "text" },
    assign_skill = { "agent", "skill", "params" }, run_skill = { "name", "params" }, report = { "to", "message" },
  },
  resultOrder = {
    mine = { "mined", "hold_pct", "vein_reserve_pct", "duration_s", "stopped_because", "crowded_by" },
    ["return"] = { "docked_at", "hold", "sold", "unit_price", "total" },
    sell = { "sold", "unit_price", "total" },
    store = { "stored", "partial", "warehouse_free" },
    scan = { "veins" },
    report = { "delivered" },
    run_skill = { "skill_ended_because" },
    ship = { "freighter_id", "eta_s" },
    set_order = { "order_set" },
    assign_skill = { "assigned" },
    resume_agent = { "previous_error" },
  },
  order = { "mine", "return", "sell", "store", "scan", "report", "wait", "run_skill", "ship", "set_order", "assign_skill", "pause_agent", "resume_agent" },
  schemas = {
    mine = { description = "Fly to a vein, mine it, stop at the target hold %.",
      args = { vein = str("known vein id", { required = true }),
        stop_at_hold_pct = { type = "integer", min = 10, max = 100, desc = "default 100" } } },
    ["return"] = { description = "Fly back to a dock.",
      args = { to = str("default home", { enum = { "home", "local_depot" } }) } },
    sell = { description = "Sell the hold (Miner, docked) or a warehouse stock (Logistician) at a buyer.",
      args = { buyer = str("default hmc", { enum = { "hmc", "orbis", "meridian" } }), planet = str("planet id"),
        resource = str("ore id (Logistician)"), qty = { type = "any", desc = "int>=1|all (Logistician)" } } },
    store = { description = "Move a resource into the warehouse.",
      args = { resource = str("ore id", { required = true }), qty = { type = "any", desc = "int>=1|all, default all" } } },
    scan = { description = "Reveal exact richness and reserve of a planet's veins.",
      args = { planet = str("planet id", { required = true }) } },
    report = { description = "Send a short message to the player or to another agent.",
      args = { message = str("text", { required = true, maxLength = 200 }), to = str("player|monitor|agent id, default player") } },
    wait = { description = "Do nothing for a while.",
      args = { seconds = { type = "integer", required = true, min = 10, max = 300 } } },
    run_skill = { description = "Run a saved skill.",
      args = { name = str("skill name", { required = true }), params = { type = "any", desc = "values of the skill parameters" } } },
    ship = { description = "Send a freighter to a market.",
      args = { resource = str("ore id", { required = true }), qty = { type = "any", desc = "int 1-500|all" },
        destination = str("market", { required = true, enum = { "orbis", "halcyon", "meridian" } }) } },
    set_order = { description = "Set or clear another agent's one-off order.",
      args = { agent = str("agent id", { required = true }), text = str("order, max 100 tokens; empty clears", { maxLength = 400 }) } },
    assign_skill = { description = "Run a saved skill on another agent, or none to return it to AI mode.",
      args = { agent = str("agent id", { required = true }), skill = str("skill name or none", { required = true }),
        params = { type = "any", desc = "values of the skill parameters" } } },
    pause_agent = { description = "Stop another agent until it is resumed.",
      args = { agent = str("agent id", { required = true }) } },
    resume_agent = { description = "Resume a paused agent.",
      args = { agent = str("agent id", { required = true }) } },
  },
}
