-- AI provider settings (spec §10). No key lives here: keys are environment variables the engine injects into
-- headers (`{{env:NAME}}`), so Luau never sees them. Module: `local AiConfig = require("@scripts/config/ai")`.
return {
  provider = "stub", -- "stub" | "axis"; also switchable at runtime from the debug panel (Sim:setProvider)

  timeoutSeconds = 20,       -- real seconds for a whole turn (spec §8.4); GR5-15 said 10, tune here
  maxConcurrent = 4,         -- spec §10.4: decisions in flight per player; the rest queue, Monitor first
  tokensPerHour = 400000,    -- spec §10.4: rolling real hour per player
  maxOutputTokens = 150,     -- spec §10.1
  reasoningMaxChars = 200,   -- spec §10.3 step 4
  recordsMax = 500,          -- spec §12.1: decision records kept

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
