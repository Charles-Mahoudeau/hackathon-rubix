-- AI provider, Compute economy and context-weight tunables (spec §6.4, §9, §10.4). No such number lives in logic.
return {
  provider = "stub", -- "stub" | "axis" (spec §10.1); also switchable at runtime (Sim:setProvider)
  maxOutputTokens = 150,
  maxConcurrent = 4,         -- in-flight requests per player; the rest queue, Monitor first, then oldest (spec §10.4)
  tokensPerHour = 400000,    -- rolling real hour per player; beyond it AI agents go to no_compute (spec §10.4)
  windowSeconds = 3600,
  budgetMessage = "Server AI budget reached",
  estimatedOutputTokens = 40, -- output assumed when the request is charged on send; corrected on response
  charsPerToken = 4, -- token estimate = ceil(utf8_length / charsPerToken)
  compute = {
    tokensPerCompute = 1000,
    priceCredits = 40, -- per Compute
    packSize = 5, -- Compute is sold in packs (200 cr)
    roundTo = 0.1, -- a decision is billed rounded UP to this step
    rateWindowSeconds = 600, -- game seconds averaged for the per-agent Compute/h readout
    rateMinElapsedSeconds = 60, -- floor on the averaging span, so the first decision does not read as a huge rate
  },
  -- Game rules header (§9.1). `compact` adds the format legend.
  rules = {
    intro = "You control one agent of a small space mining company in the game GRIDMIND.",
    role = {
      miner = "mining pilot: you fly one mining ship, mine veins and sell the ore",
      logistician = "logistician: you run one station's stock and its freighters",
      monitor = "supervisor: you watch the other agents and act on them",
    },
    act = "You act only by calling exactly one tool from the TOOLS list.",
    reply = "Reply with JSON only, no other text:",
    replyShape = '{"reasoning": "<at most 25 words>", "tool": "<tool name>", "args": { ... }}',
    fallback = "If there is nothing useful to do, call wait.",
    compactLegend = {
      'CONTEXT format: "key: value" lines; "name[n] col col ..." starts a table with one row per item;',
      '"k=v,k=v" groups values in one cell; "?" means unknown; y/n are yes/no.',
      "Abbreviations: res=resource, rich=richness, res%=reserve percent, _s=seconds, _h=per hour, err_10m=errors in the",
      "last 10 minutes, at=location (vein@planet).",
    },
  },
  -- Context settings defaults (§9.3). `prices_hmc`: "off" | "current" | "all". `veins`: "all" | "planet" | "vein".
  contextDefaults = {
    prices_hmc = "current",
    prices_orbis = true,
    prices_halcyon = false,
    prices_meridian = false,
    price_trends = false,
    format = "compact",
    recent_results = 3,
    veins = "planet",
    inbox = true,
    warehouse = true,
  },
  recentMax = 10,
  inboxMax = 5,
}
