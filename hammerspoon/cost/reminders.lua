--- Nudges before things start.
---
--- The timing is deterministic and the wording is not. That split is deliberate:
--- a reminder that arrives late because an LLM was slow, rate-limited, or
--- offline is worse than no reminder at all — the entire value is that it fires
--- when it said it would. So a plain-Lua clock decides *when*, and Claude only
--- decides *what it says*, with a flat fallback line ready if it doesn't answer.
---
--- Firing is deduped per (event, threshold), so a minute-by-minute check can't
--- turn into a minute-by-minute alarm.

local Reminders = {}

-- Minutes before the start. Descending, so the first match is the coarsest one
-- still unfired and you get "in 30" before "in 10".
Reminders.defaultLeads = { 30, 10, 3 }

local CHECK_EVERY = 60          -- seconds
local WINDOW = 90               -- how close to a lead time still counts, seconds

local fired = {}                -- "<uid>|<lead>" -> true
local lines = {}                -- uid -> the sentence Claude wrote for it
local day                       -- resets everything when the date rolls over

-- ------------------------------------------------------------------ helpers

local function today()
  return os.date("%Y-%m-%d")
end

--- Yesterday's fired-set would suppress today's reminders for a recurring
--- event, since the uid repeats. Clearing on the date change is the whole fix.
local function rollover()
  if day == today() then return end
  day = today()
  fired = {}
  lines = {}
end

local function key(uid, lead)
  return tostring(uid) .. "|" .. tostring(lead)
end

--- "in 30 minutes", "in 3 minutes", "now".
local function phrase(lead)
  if lead <= 0 then return "starting now" end
  if lead == 1 then return "in a minute" end
  return "in " .. lead .. " minutes"
end

--- A reminder worth giving: it hasn't happened, it isn't all-day, and you
--- haven't declined it.
local function eligible(event, now)
  if event.declined then return false end
  if event.allDay then return false end
  if not event.start then return false end
  return event.start > now - 60
end

-- -------------------------------------------------------------------- check

--- Which (event, lead) pairs are due right now.
---
--- Only the *closest* unfired lead per event is returned, so an event that
--- appears while already inside several windows produces one nudge rather than
--- three at once.
function Reminders.due(events, leads, now)
  now = now or os.time()
  rollover()

  local out = {}

  for _, event in ipairs(events or {}) do
    if eligible(event, now) then
      local minutes = (event.start - now) / 60

      for _, lead in ipairs(leads) do
        -- Inside the window for this lead, and not already sent.
        if minutes <= lead and minutes > (lead - WINDOW / 60)
           and not fired[key(event.uid, lead)] then
          fired[key(event.uid, lead)] = true
          out[#out + 1] = { event = event, lead = lead, minutes = minutes }
          break
        end
      end
    end
  end

  return out
end

--- The line to show. Claude's if it wrote one for this event, otherwise plain.
function Reminders.text(event, lead)
  local written = lines[event.uid]
  local when = phrase(lead)

  if written and written ~= "" then
    return when:gsub("^in", "In"):gsub("^starting", "Starting") .. " — " .. written
  end

  local title = event.title or "Something"
  return title .. " " .. when .. "."
end

function Reminders.remember(uid, line)
  if uid and line and line ~= "" then lines[uid] = line end
end

function Reminders.hasLine(uid)
  return lines[uid] ~= nil
end

-- --------------------------------------------------------------------- loop

--- @param opts table {events=fn, leads=fn, enabled=fn, onFire=fn(event, lead, text)}
function Reminders.start(opts)
  Reminders.stop()
  rollover()

  Reminders.timer = hs.timer.doEvery(CHECK_EVERY, function()
    if not opts.enabled() then return end

    for _, hit in ipairs(Reminders.due(opts.events(), opts.leads())) do
      opts.onFire(hit.event, hit.lead)
    end
  end)

  return Reminders.timer
end

function Reminders.stop()
  if Reminders.timer then
    Reminders.timer:stop()
    Reminders.timer = nil
  end
end

--- Forget everything fired so far. Used when reminders are switched back on, so
--- the next check can catch anything already inside a window.
function Reminders.reset()
  fired = {}
end

return Reminders
