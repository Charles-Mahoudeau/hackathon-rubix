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
      "last 10 minutes, at=location (vein@planet), net_h=net credits per hour, compute_h=Compute per hour.",
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
    -- Monitor only (spec §9.2.4): extra detail per agent ("summary" | "results"), and which optional sections show.
    agent_detail = "summary",
    show_skills = true,
    show_veins = true,
    show_prices = false,
  },
  -- Agent editor (spec §9.4, GR5-5). Limits are in tokens of the text itself (ceil(utf8_length / charsPerToken)).
  editor = {
    directiveMaxTokens = 400, -- permanent instruction
    orderMaxTokens = 100,     -- one-off, from the next decision until cleared
    amberFraction = 0.9,      -- the counter turns amber from this share of the limit
    savedToast = "Applied: takes effect on the agent's next decision",
    presets = {
      vague = { label = "Vague", directive = "mine" },
      precise = { label = "Precise", directive = "Mine cobalt on K3 until the hold is 100%, then sell at HMC. If the vein is empty, scan K3 and pick the richest vein." },
    },
  },
  feedMax = 200, -- agent feed lines kept (spec §12)
  -- spec §8.4: an agent stops (paused_error) until the player resumes it
  errorRules = { invalidResponses = 2, providerErrors = 3, sameFailingCall = 2 },
  -- spec §10.5: what the stub picks at random when the directive leaves a choice open
  stub = { holdPct = { 10, 100 }, waitSeconds = 30 },
  recentMax = 10,
  inboxMax = 5,
  timeoutSeconds = 20, -- real seconds for a whole provider turn (spec §8.4); GR5-15 said 10, tune here
  reasoningMaxChars = 200, -- spec §10.3 step 4
  recordsMax = 500, -- spec §12.1: decision records kept
  versions = { minSeconds = 180 }, -- spec §12.3: a prompt version with less activity is "not enough data"
  axis = {
    platformUrl = "https://api.platform.lacale-atlantle.com",
    relaisUrl = "https://relais.lacale-atlantle.com/v1/messages",
    -- Env vars the headers name as {{env:NAME}}. Keep project.luau's http.secrets and http.allowedHosts in step with
    -- these two names and the two URLs above.
    secrets = { platform = "AXIS_API_KEY", relais = "AXIS_GATEWAY_KEY" },
    model = "claude-haiku-4-5", -- or "claude-sonnet-5-5"
    agentSlug = "harponneur-theo",
    -- We are Groupe 5; 9 groups share the platform. conversation = <prefix>-<agent>-<run>, user = <prefix>:<player>.
    idPrefix = "g5",
    userName = "player",
    workerClass = "tech",
    systemPromptTtlSeconds = 600, -- agent system prompt is re-fetched at most this often (0: every turn)
    memoryNoteMaxChars = 300,     -- the short note recorded as the user turn (the full prompt is not stored)
    observe = true,               -- fire-and-forget POST /v1/observe after each turn
    anthropicVersion = "2023-06-01",
  },
}
