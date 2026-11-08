-- Screens of the UI shell (GR5-3): the left nav, what each empty screen says, and where things sit on the system map.
-- Words and layout only, no colours (config/theme.luau) and no balance numbers (config/balance.luau).
return {
  -- Left nav, top to bottom. unlockTier: the tier at which the entry appears (spec §6.6). `milestone` names the milestone
  -- that fills the screen, shown in its empty state.
  nav = {
    { id = "map", label = "Map", unlockTier = 1 },
    { id = "agents", label = "Agents", unlockTier = 1 },
    { id = "team", label = "Team", unlockTier = 2 },
    { id = "logs", label = "Logs", unlockTier = 1 },
    { id = "missions", label = "Missions", unlockTier = 1 },
    { id = "archive", label = "Archive", unlockTier = 1 },
    { id = "shop", label = "Shop", unlockTier = 2 },
    { id = "branches", label = "Branches", unlockTier = 2 },
    { id = "station", label = "Station", unlockTier = 3 },
    { id = "market", label = "Market", unlockTier = 3 },
    { id = "fleet", label = "Fleet", unlockTier = 4 },
    { id = "alerts", label = "Alerts", unlockTier = 5 },
  },
  defaultScreen = "map",

  -- Shown when a screen has nothing yet. `title` is the heading, `hint` tells the player what will appear and how.
  empty = {
    agents = { title = "No agents to show", hint = "Your Miner will appear here with its directive, tools and mode." },
    team = { title = "No team yet", hint = "Every agent appears here with its state, mode, Compute and earnings." },
    logs = { title = "No decisions logged yet", hint = "Every agent decision is recorded here once an agent has thought." },
    missions = { title = "No active mission", hint = "Missions teach one idea at a time and appear as you progress." },
    archive = { title = "The Archive is empty", hint = "Skills you save are stored here and keep running with zero Compute." },
    shop = { title = "The shop is closed", hint = "Reach tier 2 to buy upgrades, scanners and engines." },
    branches = { title = "No branches yet", hint = "Mining is open; new branches become buyable from tier 2." },
    station = { title = "No station", hint = "Build the warehouse (tier 3) to store ore and wait for better prices." },
    market = { title = "No market data", hint = "The warehouse lights the markets and shows who buys what." },
    fleet = { title = "No fleet", hint = "The logistics hub (tier 4) brings freighters and their routes." },
    alerts = { title = "No alerts", hint = "The command center (tier 5) watches your team and raises alerts." },
  },

  -- System map: positions as fractions of the main panel (0..1). Planets are drawn in the world, labels in the UI.
  map = {
    planetRadius = 44,
    planets = {
      kessa = { x = 0.17, y = 0.58 },
      varn = { x = 0.40, y = 0.28 },
      ashfall = { x = 0.60, y = 0.66 },
      lumen = { x = 0.84, y = 0.30 },
    },
    -- Markets show only once unlocked (World.markets[id].unlockTier). Station/market nodes: the art is GR5-16's.
    markets = {
      orbis = { x = 0.07, y = 0.26 },
      halcyon = { x = 0.74, y = 0.90 },
      meridian = { x = 0.93, y = 0.64 },
    },
    -- Freighter routes from the player's station on Kessa (spec §4.5). risk picks the cosmetic colour: low blue, else orange.
    routes = {
      { from = "kessa", to = "orbis", risk = "low" },
      { from = "kessa", to = "halcyon", risk = "medium" },
      { from = "kessa", to = "meridian", risk = "medium" },
    },
    safeRouteSeconds = 160, -- outpost routes up to this long are drawn blue
    routeThickness = 2,
    riskValue = { low = 0.2, medium = 0.6 }, -- the cosmetic risk fed to render/vfx/route for a route's colour
    animSeconds = 0.15, -- the map redraws this often (planet pulse, moving dashes); other screens use refreshSeconds
    routeSpacing = 14, -- view pixels between two dashes of a route line
    convoyDot = 6,
    rivalDot = 5, -- rival convoys (raiding branch): amber on the raidable orange routes, dim on the others
  },

  -- Agent editor (GR5-5): view pixels inside the main panel. The two text inputs are their own UI tree, so typing never
  -- loses focus when the shell redraws; the shell leaves a hole at each field.
  editor = {
    leftWidth = 600, fieldHeight = 36, directiveY = 60, orderY = 136, buttonsY = 200, toastY = 244, costX = 624,
    agent = "miner", -- the agent the screen edits until there are several (GR5-28)
    placeholder = { directive = "Permanent instruction (max 400 tokens)", order = "One-off order, until cleared (max 100 tokens)" },
  },

  -- Agents screen tabs (GR5-6): the editor and the Context panel share the left panel; the tab buttons sit in its header.
  tabs = { { id = "editor", label = "Editor", x = 300, w = 100 }, { id = "context", label = "Context", x = 408, w = 110 }, y = 8 },

  -- Compute block under the editor (GR5-6): per-agent Compute/h, the hourly AI budget and the buy packs.
  compute = { y = 280, rowHeight = 18, packs = 3, buyWidth = 176, buyGap = 8, barWidth = 220 },

  -- Context panel (GR5-6): one row per setting, each option a button showing the tokens it adds to every decision.
  context = {
    rowY = 64, rowHeight = 38, labelWidth = 176, optionX = 196, optionWidth = 116, optionGap = 6, stepWidth = 32,
    labels = {
      prices_hmc = "HMC depot prices", prices_orbis = "Orbis prices", prices_halcyon = "Halcyon prices",
      prices_meridian = "Meridian prices", price_trends = "Price trends", format = "Context format",
      recent_results = "Recent results", veins = "Veins shown", inbox = "Inbox", warehouse = "Warehouse stock",
      agent_detail = "Agent detail", show_skills = "Skills list", show_veins = "Veins list", show_prices = "Market prices",
    },
    values = { ["true"] = "on", ["false"] = "off" }, -- everything else is shown as its own text
  },

  -- Logs screen (GR5-8, spec §12.2): the list on the left (newest first), the clicked record on the right.
  logs = {
    listWidth = 640, rowHeight = 22, rows = 11, rowChars = 86, statRowHeight = 18, buttonHeight = 26,
    sources = { { id = "all", label = "All" }, { id = "ai", label = "AI" }, { id = "skill", label = "Skills" } },
    agentButtonWidth = 96, sourceButtonWidth = 64, errorsButtonWidth = 120,
    hint = "Click a record to see its tokens, reasoning, call and result.",
    compareButtonWidth = 150,
    -- Prompt-version comparison (GR5-13): version picker buttons, diff line width in characters, column layout.
    compare = { maxVersions = 8, lineChars = 58, maxLines = 9, lineHeight = 16, versionButtonWidth = 120, labelWidth = 150, valueWidth = 150, rowHeight = 20, wordGap = 5,
      hint = "Pick two versions of one agent. A version is the directive, the equipped tools and the context settings together." },
  },
  -- Shop screen (GR5-7): one row per upgrade, then the fleet and the tool slots under the list.
  shop = { rowY = 48, rowHeight = 36, descX = 190, noteX = 520, costX = 700, buyX = 790, buyWidth = 90, footerGap = 16 },

  -- Fleet screen (GR5-12): Reputation bar and hub on top, then one block per station, outposts to build, ships.
  fleet = { barY = 30, barWidth = 360, barHeight = 10, hubX = 520, stationY = 78, blockGap = 14, lineHeight = 18, buttonWidth = 150,
    buttonGap = 8, outpostButtonWidth = 190, convoyX = 420 },

  -- Team screen (GR5-28): one row per agent.
  team = { rowY = 48, rowHeight = 26, nameX = 0, assetX = 130, modeX = 270, stateX = 380, computeX = 500, netX = 590, errorsX = 690, alertX = 760,
    headerY = 28 },

  -- Archive screen (GR5-10): skills list, "While you were away" box and the demo button; Market screen: one row per price.
  archive = { awayHours = 1, rowY = 48, rowHeight = 18, skillGap = 10, buttonWidth = 190, offlineY = 48, offlineWidth = 360, dismissWidth = 110 },
  -- Skill studio (GR5-26, spec §13.3): record from the feed, the manual form, and assigning a skill with its parameter values.
  -- Rows are laid out top to bottom from rowY; `calls` is how many recordable feed calls the Record tab lists.
  studio = { tabX = 380, tabWidth = 96, tabGap = 6, rowY = 48, rowHeight = 34, rowGap = 6, textWidth = 520, argWidth = 150, smallWidth = 30,
    toolWidth = 70, bigButtonWidth = 190, callWidth = 700, calls = 12, autoNameFallback = "skill" },
  market = { rowY = 48, rowHeight = 20, sparkX = 520, sparkWidth = 160, sparkHeight = 14, noticeGap = 16 },

  -- Missions screen (GR5-9): y offsets inside the main panel, in view pixels.
  missions = { nameY = 30, goalY = 66, hintY = 120, barY = 170, barHeight = 12, barWidth = 420, rewardY = 250, buttonY = 282,
    buttonWidth = 140, listY = 340, rowHeight = 20, rewardX = 360, optionalRewardOffset = 120, optionalButtonOffset = 200 },

  -- Alerts screen (GR5-29): the Monitor's controls on top, the alert list below.
  alerts = { controlsY = 36, buttonWidth = 150, smallWidth = 32, gap = 8, typesY = 76, typeWidth = 150, typesPerRow = 4, typeRowHeight = 34,
    listY = 160, rowHeight = 20, maxRows = 14, noteX = 190 },

  -- Branches screen (B-0): one row per branch, y offsets inside the main panel.
  branches = { rowY = 40, rowHeight = 56, buttonWidth = 120, agentsX = 220, stateX = 120, moneyX = 520, noteGap = 20 },

  -- Feed strip: how many of the latest feed lines the bottom strip shows.
  feedLines = 5,
  refreshSeconds = 0.25, -- the shell redraws at most this often, and only when what it shows changed
}
