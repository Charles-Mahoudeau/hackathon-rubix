-- Tool schemas shown to the AI and checked on its replies (spec §10.3, §11). They follow the arg names the sim accepts
-- today (`ship` is left out: there is one ship). `enum` lists may be given as a function of the sim in the prompt.
-- Module: `local Tools = require("@scripts/config/tools")`.
return {
  mine = { description = "Send the ship to mine a vein until the hold is full.",
    args = { vein = { type = "string", required = true, desc = "vein id from veins[]" } } },
  ["return"] = { description = "Bring the ship back to a dock.",
    args = { to = { type = "string", enum = { "home", "local_depot" }, desc = "default home" } } },
  sell = { description = "Sell the hold at the depot where the ship is docked.",
    args = { buyer = { type = "string", enum = { "hmc" } }, planet = { type = "string" } } },
  scan = { description = "Reveal the exact richness and reserve of a planet's veins.",
    args = { planet = { type = "string", required = true } } },
  wait = { description = "Do nothing for some seconds.",
    args = { seconds = { type = "integer", required = true, min = 10, max = 300 } } },
  report = { description = "Send a short message to the player.",
    args = { message = { type = "string", required = true, maxLength = 200 } } },
  store = { description = "Move a resource into the warehouse.",
    args = { resource = { type = "string", required = true }, amount = { type = "number", required = true, min = 1 } } },
  ship = { description = "Send a freighter to a market.",
    args = { destination = { type = "string", required = true, enum = { "orbis", "halcyon", "meridian" } } } },
  run_skill = { description = "Run a saved skill.",
    args = { name = { type = "string", required = true } } },
}
