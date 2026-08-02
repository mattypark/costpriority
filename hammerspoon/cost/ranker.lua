--- Deterministic priority ranking, in pure Lua.
---
--- Two jobs: it drives the board before the AI path exists, and it is the
--- fallback whenever `claude` is missing, slow, or returns something that isn't
--- the agreed shape. Because it never calls out to anything it always answers,
--- which is the point — a briefing that sometimes shows nothing is worse than
--- one that is sometimes only roughly right.

local Ranker = {}

local RANKS = { "P0", "P1", "P2", "P3" }

-- Words that mark an event as consequential regardless of when it starts.
local HEAVY = {
  "interview", "deadline", "due", "exam", "final", "flight", "surgery",
  "presentation", "defen[cs]e", "audition", "test", "submission", "submit",
}
local MEDIUM = {
  "review", "1:1", "one%-on%-one", "standup", "stand%-up", "sync", "meeting",
  "call", "practice", "training", "rehearsal", "appointment",
}
local LOW = {
  "optional", "tentative", "fyi", "hold", "blocked", "focus", "lunch", "break",
}

local function matchesAny(text, patterns)
  local lower = string.lower(text or "")
  for _, pattern in ipairs(patterns) do
    if string.find(lower, pattern) then return true end
  end
  return false
end

--- HH:MM for a timed event, "all day" for one that isn't.
local function whenLabel(event)
  if event.allDay then return "all day" end
  if not event.start then return "today" end
  return os.date("%H:%M", event.start)
end

--- Score is deliberately coarse. Fine-grained weights invite tuning forever and
--- the AI path is what earns real nuance.
local function score(event, now)
  local points = 0
  local title = event.title or ""

  if event.allDay then
    points = points + 20
    if matchesAny(title, HEAVY) then points = points + 30 end
  elseif event.start then
    local minutes = (event.start - now) / 60

    if minutes < -30 then
      points = points - 120        -- already over; not today's problem any more
    elseif minutes < 0 then
      points = points + 60         -- happening right now
    elseif minutes <= 180 then
      points = points + 100        -- inside the next three hours
    elseif minutes <= 480 then
      points = points + 55
    else
      points = points + 25
    end
  end

  if (event.attendees or 0) >= 1 then points = points + 18 end
  if (event.attendees or 0) >= 5 then points = points + 8 end

  if matchesAny(title, HEAVY) then points = points + 40 end
  if matchesAny(title, MEDIUM) then points = points + 15 end
  if matchesAny(title, LOW) then points = points - 35 end

  if event.declined then points = points - 200 end

  return points
end

--- Deterministic ordering: score, then start time, then title. No ties left to
--- table iteration order, so the same day always ranks the same way.
local function compare(a, b)
  if a._score ~= b._score then return a._score > b._score end
  local aStart, bStart = a.start or math.huge, b.start or math.huge
  if aStart ~= bStart then return aStart < bStart end
  return (a.title or "") < (b.title or "")
end

local function reason(event, now)
  if event.allDay then return "All day" end
  if not event.start then return "No time set" end

  local minutes = math.floor((event.start - now) / 60)
  if minutes < 0 then return "Started already" end
  if minutes < 60 then return ("In %d min"):format(minutes) end

  local hours = minutes / 60
  local suffix = (event.attendees or 0) >= 1
                 and (", %d people"):format(event.attendees) or ""
  return ("In %.1f h%s"):format(hours, suffix)
end

--- Something that already finished cannot be a priority. Ranking this morning's
--- shower above this afternoon's deadline is the single most obvious way for a
--- briefing to look broken, so finished events are partitioned out entirely
--- rather than merely scored down.
local function isFinished(event, now)
  if event.allDay then return false end
  if event.endTime then return event.endTime <= now end
  if event.start then return event.start <= (now - 3600) end
  return false
end

--- @param events table  list of { title, start, endTime, allDay, attendees, calendar, uid }
--- @param now number|nil  epoch seconds; injectable so this stays testable
--- @return table  { priorities = {...}, rest = {...}, empty = ... }
function Ranker.rank(events, now)
  now = now or os.time()

  local upcoming, finished = {}, {}

  for _, event in ipairs(events or {}) do
    if not event.declined then
      if isFinished(event, now) then
        finished[#finished + 1] = event
      else
        event._score = score(event, now)
        upcoming[#upcoming + 1] = event
      end
    end
  end

  table.sort(upcoming, compare)
  table.sort(finished, function(a, b)
    return (a.start or 0) < (b.start or 0)
  end)

  local priorities, rest = {}, {}

  for index, event in ipairs(upcoming) do
    if index <= #RANKS then
      priorities[#priorities + 1] = {
        rank = RANKS[index],
        title = event.title or "Untitled",
        why = reason(event, now),
        when = whenLabel(event),
        source = "calendar",
        ref = event.uid,
      }
    elseif #rest < 8 then
      rest[#rest + 1] = {
        title = event.title or "Untitled",
        why = whenLabel(event),
        source = "calendar",
      }
    end
  end

  -- Done things go last and are marked as such, so the board still accounts for
  -- the whole day without pretending any of it is still ahead of you.
  local room = 8 - #rest
  for index, event in ipairs(finished) do
    if index > room then break end
    rest[#rest + 1] = {
      title = "✓ " .. (event.title or "Untitled"),
      why = "done",
      source = "calendar",
    }
  end

  local empty = "Nothing on the calendar today."
  if #priorities == 0 and #finished > 0 then
    empty = "Everything on today's calendar is done."
  end

  return { priorities = priorities, rest = rest, empty = empty }
end

return Ranker
