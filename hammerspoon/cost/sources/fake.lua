--- Sample events, shaped exactly like what sources/calendar.lua will return.
---
--- Phase 1 runs on these so the sprite, board, themes and pet bus can all be
--- proven before anything touches the calendar permission — which is the one
--- part of this project most likely to fight back.

local Fake = {}

--- Times are relative to now, so the board always looks like a plausible today
--- whenever you happen to open it.
function Fake.events(now)
  now = now or os.time()
  local hour = 3600

  return {
    { uid = "fake-1", title = "Physics final review session",
      start = now + hour * 2, endTime = now + hour * 3,
      allDay = false, attendees = 12, calendar = "School" },

    { uid = "fake-2", title = "Grant application deadline",
      start = nil, endTime = nil,
      allDay = true, attendees = 0, calendar = "Deadlines" },

    { uid = "fake-3", title = "1:1 with your manager",
      start = now + hour * 5, endTime = now + hour * 5 + 1800,
      allDay = false, attendees = 2, calendar = "Work" },

    { uid = "fake-4", title = "Tennis practice",
      start = now + hour * 7, endTime = now + hour * 9,
      allDay = false, attendees = 1, calendar = "Personal" },

    { uid = "fake-5", title = "Team sync",
      start = now + hour * 9, endTime = now + hour * 10,
      allDay = false, attendees = 6, calendar = "Work" },

    { uid = "fake-6", title = "Lunch",
      start = now + hour * 4, endTime = now + hour * 5,
      allDay = false, attendees = 0, calendar = "Personal" },

    { uid = "fake-7", title = "Optional: office hours",
      start = now + hour * 11, endTime = now + hour * 12,
      allDay = false, attendees = 20, calendar = "School" },
  }
end

return Fake
