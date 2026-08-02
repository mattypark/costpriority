--- Persistent state — position, visibility, theme, sprite size — via hs.settings.
---
--- Note the absent x/y: a nil in a Lua table constructor means the key simply
--- isn't there, so anything defaulting to nil can't live in `defaults`. `load`
--- reads what was stored first for exactly that reason, otherwise a dragged
--- position would never survive a reload.

local KEY = "cost.state"

local defaults = {
  hidden    = false,
  theme     = "claude",
  petWidth  = 96,
  boardOpen = false,
  model     = "",        -- empty = whatever `claude` defaults to
  useAI     = true,      -- off falls back to the deterministic ranker
}

local KEYS = {
  "x", "y", "hidden", "theme", "petWidth", "boardOpen", "model", "useAI", "configured",
}

local State = {}

function State.load()
  local stored = hs.settings.get(KEY) or {}
  local out = {}

  -- Everything that was saved, including keys with no default (x, y).
  for _, key in ipairs(KEYS) do
    out[key] = stored[key]
  end

  -- Then fill in anything missing.
  for key, value in pairs(defaults) do
    if out[key] == nil then out[key] = value end
  end

  return out
end

function State.save(state)
  local out = {}
  for _, key in ipairs(KEYS) do
    out[key] = state[key]
  end
  hs.settings.set(KEY, out)
end

return State
