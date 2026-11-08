-- Tool schemas shown in the [TOOLS] section of every prompt (spec §11, D14). Each equipped tool adds its schema
-- to every prompt, so the schema text is the tool's token weight. Static text only: no per-game data in here.
return {
  order = { "mine", "return", "sell", "store", "scan", "report", "wait", "run_skill", "ship" },
  schemas = {
    mine = { description = "Fly to a vein, mine it, stop at the target hold %.",
      args = { vein = "known vein id", stop_at_hold_pct = "int 10-100, default 100" } },
    ["return"] = { description = "Fly back to a dock.", args = { to = "home|local_depot, default home" } },
    sell = { description = "Sell from the hold (docked) at a buyer.",
      args = { resource = "ore id", qty = "int>=1|all", buyer = "hmc|orbis" } },
    store = { description = "Store cargo in the warehouse.", args = { resource = "ore id", qty = "int>=1|all" } },
    scan = { description = "Reveal exact richness and reserve of a planet's veins.", args = { planet = "planet id" } },
    report = { description = "Send a message.", args = { message = "string<=200", to = "player|agent id|monitor" } },
    wait = { description = "Do nothing for a while.", args = { seconds = "int 10-300" } },
    run_skill = { description = "Run a saved skill.", args = { name = "skill name", params = "object if the skill has any" } },
    ship = { description = "Send a freighter to a market.",
      args = { resource = "ore id", qty = "int 1-500", destination = "orbis|halcyon|meridian" } },
  },
}
