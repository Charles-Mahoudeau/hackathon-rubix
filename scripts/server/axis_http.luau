-- Engine glue for the Axis provider: the transport of ai/axis.luau over `engine.http.request` (rtype.Http plugin, server
-- side only). The plugin fills `{{env:NAME}}` in headers, so no key passes through Luau. Needs project.luau to list
-- "rtype.Http", the two hosts and the two secrets; required by the server entry only.
local AxisHttp = {}

local nextLocal = 1
local outbox = {}   -- { id, req } waiting for the next frame
local inbox = {}    -- responses for ai/axis.luau
local toLocal = {}  -- engine request id -> local id
local toEngine = {} -- local id -> engine request id
local cancels = {}  -- local ids to cancel
local clock = 0
local frameHook = nil

function AxisHttp.send(req)
  local id = nextLocal
  nextLocal += 1
  outbox[#outbox + 1] = { id = id, req = req }
  return id
end

function AxisHttp.poll()
  local out = inbox
  inbox = {}
  return out
end

function AxisHttp.cancel(id) cancels[#cancels + 1] = id end

-- Real seconds, advanced by the frame system below (0 until it first runs).
function AxisHttp.now() return clock end

-- fn runs once per frame, after the responses are read and before the new requests are sent.
function AxisHttp.onFrame(fn) frameHook = fn end

local function failNow(id, message) inbox[#inbox + 1] = { id = id, ok = false, status = 0, body = "", error = message } end

engine.ecs.system("game.AxisHttp", {
  phase = "Update",
  query = {},
  calls = { "rtype.http.request", "rtype.http.cancel" },
  events = { read = { "rtype.HttpResponse" } },
  run = function(ctx)
    clock = ctx.time.elapsed
    for response in ctx.events.read("rtype.HttpResponse") do
      local id = toLocal[response.request]
      if id then
        toLocal[response.request], toEngine[id] = nil, nil
        inbox[#inbox + 1] = { id = id, ok = response.ok, status = response.status, body = response.body, error = response.error }
      end
    end
    if frameHook then frameHook() end
    for _, id in ipairs(cancels) do
      local eid = toEngine[id]
      if eid then
        toLocal[eid], toEngine[id] = nil, nil
        pcall(ctx.call, "rtype.http.cancel", { request = eid })
      end
    end
    cancels = {}
    local batch = outbox
    outbox = {}
    for _, item in ipairs(batch) do
      local ok, eid = pcall(engine.http.request, ctx, { method = item.req.method, url = item.req.url, headers = item.req.headers,
        body = item.req.body, timeout = item.req.timeout })
      if ok then toLocal[eid], toEngine[item.id] = item.id, eid
      else failNow(item.id, "send_failed: " .. tostring(eid)) end
    end
  end,
})

return AxisHttp
