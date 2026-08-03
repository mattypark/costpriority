--- One line of English becomes one structured action.
---
--- The parsing itself is Brain's job; this module owns the contract: what shapes
--- are acceptable, and what counts as safe enough to act on.
---
--- The validation here is stricter than the ranking validators, because the
--- consequences are. A wrong rank is cosmetic and self-correcting. A wrong
--- calendar write puts a real event in a real calendar, or removes one, and the
--- person may not notice for weeks. So: uids are never accepted unless they
--- match an event actually on the calendar, times are sanity-checked against the
--- clock, and anything that fails becomes `unclear` rather than a best guess.

local Intent = {}

local MAX_DRIFT = 400 * 86400   -- refuse dates absurdly far from now

local SCOPES = { daily = true, weekly = true, monthly = true }

local function clean(value, limit)
  if type(value) ~= "string" then return nil end
  local text = value:gsub("%c", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil end
  if #text > limit then text = text:sub(1, limit - 1) .. "…" end
  return text
end

local function epoch(value)
  local number = tonumber(value)
  if not number then return nil end

  -- Milliseconds are a common slip; convert rather than reject.
  if number > 1e11 then number = number / 1000 end

  local now = os.time()
  if math.abs(number - now) > MAX_DRIFT then return nil end
  return math.floor(number)
end

--- Build the payload the model sees: what was said, when it is now, what exists.
function Intent.payload(text, events, calendars, defaultCalendar)
  local list = {}
  for index, event in ipairs(events or {}) do
    if index > 40 then break end
    list[#list + 1] = {
      uid = event.uid,
      title = event.title,
      start = event.start,
      endTime = event.endTime,
      allDay = event.allDay and true or false,
      calendar = event.calendar,
    }
  end

  return hs.json.encode({
    said = text,
    now = os.time(),
    now_local = os.date("%Y-%m-%d %H:%M"),
    weekday = os.date("%A"),
    timezone = os.date("%Z"),
    calendars = calendars or {},
    defaultCalendar = defaultCalendar or "",
    events = list,
  })
end

--- Validate a parsed intent against reality.
--- @param raw table            the model's object
--- @param events table         today's events, for uid checking
--- @return table|nil, string   a safe intent, or nil and why
function Intent.validate(raw, events)
  if type(raw) ~= "table" then return nil, "not an object" end

  local action = type(raw.action) == "string" and raw.action:lower() or nil
  if not action then return nil, "no action" end

  -- Every uid the model may legitimately reference.
  local known = {}
  for _, event in ipairs(events or {}) do
    if event.uid then known[event.uid] = event end
  end

  if action == "priority" then
    local text = clean(raw.text, 120)
    if not text then return nil, "no text for the priority" end

    local scope = type(raw.scope) == "string" and raw.scope:lower() or "daily"
    if not SCOPES[scope] then scope = "daily" end

    return { action = "priority", text = text, scope = scope }
  end

  if action == "add" then
    local title = clean(raw.title, 80)
    local start = epoch(raw.start)
    if not title then return nil, "no title for the event" end
    if not start then return nil, "no usable start time" end

    local allDay = raw.allDay == true
    local finish = epoch(raw["end"]) or (start + 3600)
    if finish <= start then finish = start + 3600 end

    local calendar = clean(raw.calendar, 60)

    return {
      action = "add", title = title, start = start,
      ["end"] = finish, allDay = allDay, calendar = calendar,
    }
  end

  if action == "move" or action == "delete" then
    local uid = type(raw.uid) == "string" and raw.uid or nil

    -- Never trust a uid the calendar doesn't actually have. A hallucinated one
    -- would either fail confusingly or, worse, match something unintended.
    if not uid or not known[uid] then
      return nil, "couldn't find that event on today's calendar"
    end

    local event = known[uid]
    local title = clean(raw.title, 80) or event.title or "that event"

    if action == "delete" then
      return { action = "delete", uid = uid, title = title, event = event }
    end

    local start = epoch(raw.start)
    if not start then return nil, "no usable new time" end

    local finish = epoch(raw["end"])
    if not finish and event.start and event.endTime then
      finish = start + (event.endTime - event.start)   -- keep the duration
    end
    if not finish or finish <= start then finish = start + 3600 end

    return {
      action = "move", uid = uid, title = title,
      start = start, ["end"] = finish, event = event,
    }
  end

  if action == "ask" or action == "unclear" then
    local answer = clean(raw.answer, 600) or "I'm not sure what you meant."
    return { action = action, answer = answer }
  end

  return nil, "unknown action: " .. action
end

--- A one-line human description of what is about to happen, for the confirm
--- card. Times are absolute and spelled out — the whole point of confirming is
--- to catch a date the model resolved wrongly.
function Intent.describe(intent)
  if intent.action == "priority" then
    return ("Add to %s list"):format(intent.scope), intent.text
  end

  if intent.action == "add" then
    local when = intent.allDay
      and os.date("%a %d %b · all day", intent.start)
      or  os.date("%a %d %b · %H:%M", intent.start) ..
          os.date("–%H:%M", intent["end"])
    local where = intent.calendar and (" · " .. intent.calendar) or ""
    return "Add to calendar", intent.title .. "\n" .. when .. where
  end

  if intent.action == "move" then
    local from = intent.event and intent.event.start
      and os.date("%H:%M", intent.event.start) or "?"
    local to = os.date("%a %d %b · %H:%M", intent.start)
    return "Reschedule", intent.title .. "\n" .. from .. "  →  " .. to
  end

  if intent.action == "delete" then
    local when = intent.event and intent.event.start
      and os.date("%a %d %b · %H:%M", intent.event.start) or ""
    return "Delete from calendar", intent.title .. (when ~= "" and ("\n" .. when) or "")
  end

  return "", intent.answer or ""
end

return Intent
