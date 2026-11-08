-- Screens of the UI shell (GR5-3): the left nav, what each empty screen says, and where things sit on the system map.
-- Words and layout only, no colours (config/theme.luau) and no balance numbers (config/balance.luau).
return {
  -- Left nav, top to bottom. unlockTier: the tier at which the entry appears (spec §6.6). `milestone` names the milestone
  -- that fills the screen, shown in its empty state.
  nav = {
    { id = "map", label = "Map", unlockTier = 1 },
    { id = "agents", label = "Agents", unlockTier = 1 },
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
    logs = { title = "No decisions logged yet", hint = "Every agent decision is recorded here once an agent has thought." },
    missions = { title = "No active mission", hint = "Missions teach one idea at a time and appear as you progress." },
    archive = { title = "The Archive is empty", hint = "Skills you save are stored here and keep running with zero Compute." },
    shop = { title = "The shop is closed", hint = "Reach tier 2 to buy upgrades, scanners and engines." },
    branches = { title = "No branches yet", hint = "Salvage, refining and raiding become buyable from tier 2." },
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
    routeThickness = 2,
    routeSpacing = 14, -- view pixels between two dashes of a route line
    convoyDot = 6,
  },

  -- Agent editor (GR5-5): view pixels inside the main panel. The two text inputs are their own UI tree, so typing never
  -- loses focus when the shell redraws; the shell leaves a hole at each field.
  editor = {
    leftWidth = 600, fieldHeight = 36, directiveY = 60, orderY = 136, buttonsY = 200, toastY = 244, costX = 624,
    agent = "miner", -- the agent the screen edits until there are several (GR5-28)
    placeholder = { directive = "Permanent instruction (max 400 tokens)", order = "One-off order, until cleared (max 100 tokens)" },
  },

  -- Feed strip: how many of the latest feed lines the bottom strip shows.
  feedLines = 5,
  refreshSeconds = 0.25, -- the shell redraws at most this often, and only when what it shows changed
}
