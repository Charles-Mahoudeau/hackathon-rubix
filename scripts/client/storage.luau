-- The storage the Persistence module wants, on top of the engine's rtype.Persistence plugin (GR5-32): atomic writes in
-- the per-user folder. `read` returns the text, nil for a missing save, or nil + the engine's error ("corrupt", "io: ...").
-- The calls must be listed by the system using it (`Storage.calls`) and `storage.ctx` set to that system's ctx every frame.
-- It uses the raw `rtype.persistence.*` calls, not the engine.persistence.* helpers: the write helper of the engine build we
-- tested (rtype 3e6d9cf3) rejects its own `data` field ("unexpected 'data', expected 'name'").
local Storage = {}

Storage.calls = { "rtype.persistence.read", "rtype.persistence.write", "rtype.persistence.delete", "rtype.persistence.exists" }

function Storage.engine()
  local storage = { ctx = nil }
  function storage.read(path)
    local res = storage.ctx.call("rtype.persistence.read", { name = path })
    if res.ok then return res.data end
    if res.error == "not_found" then return nil end
    return nil, res.error or "io"
  end
  function storage.write(path, text)
    local res = storage.ctx.call("rtype.persistence.write", { name = path, data = text })
    if res.ok then return true end
    return false, res.error
  end
  function storage.delete(path)
    return storage.ctx.call("rtype.persistence.delete", { name = path }).ok
  end
  return storage
end

return Storage
