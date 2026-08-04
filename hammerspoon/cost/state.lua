--- Persistent state — position, visibility, theme, sprite size — via hs.settings.
---
--- Note the absent x/y: a nil in a Lua table constructor means the key simply
--- isn't there, so anything defaulting to nil can't live in `defaults`. `load`
--- reads what was stored first for exactly that reason, otherwise a dragged
--- position would never survive a reload.

local KEY = "cost.state"

local defaults = {
  hidden    = false,
  theme     = "cost",
  petWidth  = 96,
  boardOpen = false,
  scope     = "daily",   -- which list the board is showing
  -- Which calendars to read. Empty means all of them, which is the right
  -- default: a fresh install should show your day, not nothing.
  calendars = {},
  model     = "",        -- empty = whatever `claude` defaults to
  reminders = true,      -- nudge before something starts
  leads     = { 30, 10, 3 },   -- minutes before, coarsest first
  smartNudges = true,    -- let Claude write the wording; timing never depends on it
}

local KEYS = {
  "x", "y", "hidden", "theme", "petWidth", "boardOpen", "scope", "calendars",
  "model", "reminders", "leads", "smartNudges", "configured",
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
