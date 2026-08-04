--- cost — a desktop pet that holds what you decided actually matters.
---
--- Priorities are things you tell it, kept in three independent lists: daily,
--- weekly, monthly. Your calendar is context around them, not the content —
--- it's always shown, but it never becomes a priority on its own.
---
--- Nothing calls Claude on its own. Ranking happens when you ask for it.

local State      = require("cost.state")
local Pet        = require("cost.pet")
local Board      = require("cost.board")
local Menu       = require("cost.menu")
local Priorities = require("cost.priorities")
local Input      = require("cost.input")
local Bubble     = require("cost.bubble")
local Intent     = require("cost.intent")
local Brain      = require("cost.brain")
local Reminders  = require("cost.reminders")
local Calendar   = require("cost.sources.calendar")
local themes     = require("cost.themes")

local M = {}

local HOTKEY = { { "ctrl", "alt", "cmd" }, "i" }
local HOTKEY_HINT = "⌃⌥⌘I"
local ASK_HOTKEY = { { "ctrl", "alt", "cmd" }, "k" }
local ASK_HINT = "⌃⌥⌘K"

local state, pet, board, menu, menubar, hotkey, askHotkey, waker, bubble
local calendarTimer
local lists                    -- the three priority lists
local events = {}              -- today's calendar, for context
local calendarNote             -- why the calendar is missing, when it is
local calendars = {}           -- writable calendar names, from the helper
local defaultCalendar          -- where a new event lands by default
local busy = false             -- a Claude call is in flight

-- ------------------------------------------------------------------- helpers

local function scope()
  return state.scope or "daily"
end

--- The time line under a block's title: "09:30 – 10:15", or "all day".
local function eventWhen(event)
  if event.allDay then return "all day" end
  if not event.start then return "" end

  local from = os.date("%H:%M", event.start)
  if not event.endTime then return from end
  return from .. " – " .. os.date("%H:%M", event.endTime)
end

--- done / now / ahead — drives how strongly the block is drawn.
local function eventState(event, now)
  if event.allDay then return "ahead" end
  if not event.start then return "ahead" end
  if event.endTime and event.endTime <= now then return "done" end
  if event.start <= now then return "now" end
  return "ahead"
end

-- --------------------------------------------------------------------- board

--- Everything the board draws, assembled from the three sources: the current
--- list, the calendar, and whatever Claude last said.
local function compose()
  local ranked, rest, done = Priorities.view(lists, scope())

  local priorities = {}
  for _, item in ipairs(ranked) do
    priorities[#priorities + 1] = {
      rank = item.rank,
      title = item.text,
      why = item.why,
      when = item.pinned and "pinned" or nil,
      id = item.id,
    }
  end

  local restRows = {}
  for _, item in ipairs(rest) do
    restRows[#restRows + 1] = { title = item.text, id = item.id }
  end

  local doneRows = {}
  for _, item in ipairs(done) do
    doneRows[#doneRows + 1] = { title = item.text, id = item.id }
  end

  -- The calendar is always shown, whatever state it's in. A board that says
  -- nothing about the day is worse than one that says the day is over.
  local now = os.time()
  local calendarRows = {}
  for _, event in ipairs(events) do
    -- Named `phase`, not `state`: `state` is the settings table in this file's
    -- scope and shadowing it here would be a trap for the next change.
    local phase = eventState(event, now)
    calendarRows[#calendarRows + 1] = {
      title = event.title or "Untitled",
      when = eventWhen(event) .. (phase == "now" and "  ·  now" or ""),
      state = phase,
      color = event.color,
      sortKey = event.allDay and 0 or (event.start or math.huge),
      calendarEvent = true,
    }
  end

  -- Chronological, so the column reads like a day. All-day events sort first,
  -- the way a calendar puts them across the top.
  table.sort(calendarRows, function(a, b)
    if a.sortKey ~= b.sortKey then return a.sortKey < b.sortKey end
    return (a.title or "") < (b.title or "")
  end)

  -- Past today, listing every event is unreadable and says nothing: a month of
  -- a repeating morning routine is a hundred identical rows. Weekly becomes a
  -- seven-column grid; monthly drops the per-day breakdown entirely and answers
  -- the only questions that matter at that range — how much is on, and what is
  -- actually worth knowing about.
  local calendarTitle = "TODAY'S CALENDAR"
  local weekGrid, keyEvents

  if scope() ~= "daily" then
    -- Routine is whatever repeats. An event whose title recurs across the range
    -- is a habit block, not news, so frequency alone separates signal from
    -- scaffolding without asking a model anything.
    local frequency = {}
    for _, event in ipairs(events) do
      local title = event.title or ""
      frequency[title] = (frequency[title] or 0) + 1
    end

    keyEvents = {}
    for _, event in ipairs(events) do
      local title = event.title or ""
      if (frequency[title] or 0) <= 2 and #keyEvents < 7 then
        keyEvents[#keyEvents + 1] = {
          title = title,
          when = os.date("%a %d %b", event.start or now)
                 .. (event.allDay and "" or os.date(" · %H:%M", event.start or now)),
          color = event.color,
          state = (event.start or now) < now and "done" or "ahead",
          sortKey = event.start or now,
        }
      end
    end
    table.sort(keyEvents, function(a, b) return a.sortKey < b.sortKey end)

    calendarRows = {}
  end

  if scope() == "weekly" then
    local perDay = {}
    for _, event in ipairs(events) do
      local key = os.date("%Y-%m-%d", event.start or now)
      perDay[key] = perDay[key] or { count = 0, colors = {} }
      perDay[key].count = perDay[key].count + 1
      if #perDay[key].colors < 5 and event.color then
        perDay[key].colors[#perDay[key].colors + 1] = event.color
      end
    end

    weekGrid = {}
    local today = os.date("*t", now)
    for offset = 0, 6 do
      local when = os.time({
        year = today.year, month = today.month, day = today.day + offset,
        hour = 12,
      })
      local key = os.date("%Y-%m-%d", when)
      local day = perDay[key] or { count = 0, colors = {} }
      weekGrid[#weekGrid + 1] = {
        letter = os.date("%a", when):sub(1, 1),
        number = os.date("%d", when),
        count = day.count,
        colors = day.colors,
        today = (offset == 0),
      }
    end
    calendarTitle = "NEXT 7 DAYS  ·  " .. #events .. " events"

  elseif scope() == "monthly" then
    calendarTitle = "THIS MONTH  ·  " .. #events .. " events"
  end
  local scopes = {}
  for _, id in ipairs(Priorities.scopes) do
    scopes[#scopes + 1] = {
      id = id,
      label = Priorities.label[id],
      count = Priorities.count(lists, id),
    }
  end

  local note
  if busy then
    note = "Thinking…"
  elseif calendarNote then
    note = calendarNote
  elseif lists.rankedAt and lists.rankedAt[scope()] then
    note = "Ranked by Claude at " .. os.date("%H:%M", lists.rankedAt[scope()])
  else
    note = "Not ranked yet — click ↻ or add something"
  end

  local empty = "Nothing on your " .. Priorities.label[scope()]:lower() .. " list."
  if #restRows > 0 or #doneRows > 0 then
    empty = "Nothing ranked yet — press ↻."
  end

  return {
    scope = scope(),
    scopes = scopes,
    priorities = priorities,
    rest = restRows,
    restTitle = "NOT RANKED",
    done = doneRows,
    calendar = calendarRows,
    calendarTitle = calendarTitle,
    weekGrid = weekGrid,
    keyEvents = keyEvents,
    calendarEmpty = (state.calendars and #state.calendars > 0)
      and "Nothing today on the calendars you picked."
      or "Nothing scheduled today.",
    empty = empty,
    note = note,
  }
end

--- Redraw in place if the board is open. Every mutation ends here.
local function redraw()
  if board and board:isOpen() then
    board:setAnchor(pet:frame())
    board:show(compose())
  end
end

local function persist()
  Priorities.save(lists)
  State.save(state)
end

-- ------------------------------------------------------------------ calendar

--- Refresh the calendar only. Never calls Claude, so this is free and safe to
--- run in the background.
--- How far ahead each scope looks. Daily wants blocks for today; weekly and
--- monthly want a count, not a wall of every event in the range.
local SPAN = { daily = 1, weekly = 7, monthly = 31 }

function M.refreshCalendar(callback)
  Calendar.fetch(function(fetched, err, meta)
    if err then
      calendarNote = "Calendar unavailable — " .. err
      events = {}
    else
      calendarNote = nil
      -- Which calendars can be written to, so the parser never invents a name.
      calendars = (meta and meta.calendars) or calendars
      defaultCalendar = (meta and meta.defaultCalendar) or defaultCalendar

      -- Honour the chosen subset. An empty selection means all of them: with
      -- fifteen calendars synced, showing every one is noise, but showing none
      -- would look broken on a fresh install.
      local wanted = {}
      local filtering = false
      for _, name in ipairs(state.calendars or {}) do
        wanted[name] = true
        filtering = true
      end

      events = {}
      for _, event in ipairs(fetched or {}) do
        if not filtering or wanted[event.calendar] then
          events[#events + 1] = event
        end
      end
    end
    redraw()
    if callback then callback() end
  end, SPAN[scope()] or 1)
end

-- ------------------------------------------------------------------- ranking

--- Ask Claude to order the current list. Only ever runs because you asked.
function M.rank()
  if busy then return end

  local list = lists[scope()] or {}
  if #list == 0 then
    redraw()
    return
  end

  busy = true
  pet:setBusy(true)
  redraw()

  local function done(message)
    busy = false
    pet:setBusy(false)
    calendarNote = message
    redraw()
  end

  -- Fresh calendar first: ranking against yesterday's context is worse than not
  -- ranking at all.
  M.refreshCalendar(function()
    Brain.rankPriorities(list, events, scope(), { model = state.model },
      function(result, err)
        if not result then
          done("Couldn't rank — " .. tostring(err))
          return
        end

        Priorities.applyRanking(lists, scope(), result.ranking)

        for id, why in pairs(result.why or {}) do
          local item = Priorities.find(lists, id)
          if item then item.why = why end
        end

        persist()
        done(nil)
      end)
  end)
end

-- ----------------------------------------------------------------- mutations

function M.addPriority(text, targetScope)
  local item = Priorities.add(lists, targetScope or scope(), text)
  if not item then return nil end

  persist()
  redraw()
  return item
end

function M.setScope(id)
  if not Priorities.label[id] then return end
  state.scope = id
  State.save(state)
  redraw()
  -- Each scope looks at a different window, so the calendar has to be refetched
  -- rather than re-sliced from what we already hold.
  M.refreshCalendar()
end

--- Clicking an item toggles it done. Direct, reversible, and the thing you want
--- ninety percent of the time.
function M.onRow(row)
  if not row or not row.id then return end
  Priorities.toggleDone(lists, row.id)
  persist()
  redraw()
end

-- --------------------------------------------------------------------- input

--- Open the input bar next to the pet.
---
--- It's a real text field, so your macOS dictation shortcut works in it — set
--- one under System Settings › Keyboard › Dictation and you can talk instead of
--- type, with no permission granted to Hammerspoon at all.
function M.promptAdd(targetScope)
  targetScope = targetScope or scope()

  Input.show({
    anchor = pet:frame(),
    hint = "ADD TO " .. string.upper(Priorities.label[targetScope]),
    placeholder = "what matters?",
  }, function(text)
    M.addPriority(text, targetScope)

    if not board:isOpen() then
      board:setAnchor(pet:frame())
      board:show(compose())
    end
  end)
end

-- ------------------------------------------------------------------- talking

--- Show what was parsed and wait for a yes.
---
--- Always, for every write. The model resolves dates, and a date resolved wrongly
--- puts a real event in a real calendar where you may not notice it for weeks.
--- Reading back an absolute date is the only way to catch that.
local function confirm(intent, onYes)
  local title, detail = Intent.describe(intent)

  say(detail, {
    title = title,
    actions = {
      { title = "Do it", fn = onYes },
      { title = "Cancel", fn = function() end },
    },
  })
end

--- Speak. The bubble stays until dismissed — a message you missed is a message
--- that may as well not have been shown.
local function say(message, opts)
  if not message or message == "" then
    bubble:hide()
    calendarNote = nil
    redraw()
    return
  end

  bubble:setAnchor(pet:frame())
  bubble:say(message, opts)
end

--- Apply a validated intent. Reads route straight through; every write goes via
--- confirm() first.
local function perform(intent)
  if intent.action == "priority" then
    M.addPriority(intent.text, intent.scope)
    if not board:isOpen() then M.toggleBoard() end
    return
  end

  if intent.action == "ask" or intent.action == "unclear" then
    say(intent.answer, { title = "cost" })
    return
  end

  confirm(intent, function()
    local mode = intent.action
    local spec

    if mode == "add" then
      spec = {
        title = intent.title, start = intent.start, ["end"] = intent["end"],
        allDay = intent.allDay, calendar = intent.calendar,
      }
    elseif mode == "move" then
      spec = { uid = intent.uid, start = intent.start, ["end"] = intent["end"] }
    else
      spec = { uid = intent.uid }
    end

    say("Working on it…", { title = "cost" })
    Calendar.write(mode, spec, function(_, err)
      if err then
        say(err, { title = "couldn't " .. mode })
        return
      end
      -- Re-read rather than patching the local copy: the calendar is the source
      -- of truth and it may have changed other things too.
      M.refreshCalendar(function() say(nil) end)
    end)
  end)
end

--- The main way in: say something, it works out what you meant.
function M.talk()
  Input.show({
    anchor = pet:frame(),
    hint = "TELL COST",
    placeholder = "a priority, an event, or a question…",
  }, function(text)
    if not Brain.available() then
      -- Without the CLI there is nothing to parse with, so treat it as a plain
      -- priority rather than failing.
      M.addPriority(text, scope())
      if not board:isOpen() then M.toggleBoard() end
      return
    end

    busy = true
    pet:setBusy(true)
    say("Thinking…", { title = "cost" })

    Brain.parseIntent(text, events, calendars, defaultCalendar,
      { model = state.model }, function(raw, err)
        busy = false
        pet:setBusy(false)

        if not raw then
          say(tostring(err), { title = "couldn't understand that" })
          return
        end

        local intent, invalid = Intent.validate(raw, events)
        if not intent then
          say(tostring(invalid), { title = "couldn't do that" })
          return
        end

        calendarNote = nil
        perform(intent)
      end)
  end)
end

-- ---------------------------------------------------------------- reminders

--- Show a nudge. Bubble beside the pet, a hop, a sound, and a system
--- notification — because the pet may be hidden, on another Space, or behind a
--- full-screen window, and a reminder you didn't see is not a reminder.
local function nudge(event, lead)
  local text = Reminders.text(event, lead)

  if pet and not pet:isHidden() then
    pet:nudge()
    bubble:setAnchor(pet:frame())
  end

  bubble:say(text, {
    title = event.title,
    actions = {
      { title = "Got it", fn = function() end },
    },
  })

  hs.sound.getByName("Submarine"):play()

  local notification = hs.notify.new({
    title = event.title or "Coming up",
    subTitle = lead <= 0 and "starting now" or ("in " .. lead .. " minutes"),
    informativeText = text,
    withdrawAfter = 0,
  })
  if notification then notification:send() end
end

--- Fire a reminder, asking Claude for the wording first when there's time.
---
--- The 3-minute nudge never waits on the model: at that range a late-but-clever
--- line is worse than an instant plain one. Longer leads have room, and the
--- wording is cached per event so the later nudges reuse it for free.
--- Is this worth spending a model call on?
---
--- A nudge costs about three cents, and most of a day is routine: "Wake up,
--- showering" needs no wording help and asking for some is money burnt several
--- times a day. Something is worth it if it has other people in it, a place, a
--- link, or is simply not a thing that repeats.
local function worthWording(event)
  if (event.attendees or 0) >= 1 then return true end
  if event.location and event.location ~= "" then return true end
  if event.notes and event.notes ~= "" then return true end

  local repeats = 0
  for _, other in ipairs(events) do
    if other.title == event.title then repeats = repeats + 1 end
  end
  return repeats <= 1
end

local function fireReminder(event, lead)
  local urgent = lead <= 3

  if urgent or not Brain.available() or not state.smartNudges
     or Reminders.hasLine(event.uid) or not worthWording(event) then
    nudge(event, lead)
    return
  end

  nudge(event, lead)   -- show the plain line immediately, upgrade it after

  Brain.nudge(event, events, lists[scope()], { model = state.model },
    function(result)
      if result and result.line then
        Reminders.remember(event.uid, result.line)
        -- Only rewrite the bubble if it is still the one we just put up.
        if bubble:isOpen() then
          bubble:say(Reminders.text(event, lead), {
            title = event.title,
            actions = { { title = "Got it", fn = function() end } },
          })
        end
      end
    end)
end

-- --------------------------------------------------------------------- menu

local actions

local function themePage()
  local rows = { { kind = "header", title = "THEME" } }

  for _, id in ipairs(themes.order) do
    local palette = themes.get(id)
    local active = (themes.id == id)

    rows[#rows + 1] = {
      title = (active and "● " or "   ") .. palette.label,
      hint = active and "on" or (palette.dark and "dark" or "light"),
      swatch = { palette.card, palette.accent, palette.p0, palette.p1 },
      keepOpen = true,
      rebuild = themePage,
      fn = function()
        state.theme = themes.set(id)
        State.save(state)
        pet:reskin()
        redraw()
      end,
    }
  end

  rows[#rows + 1] = { kind = "sep" }
  rows[#rows + 1] = { title = "← Back", submenu = function() return actions() end }
  return rows
end

local function sizePage()
  local rows = { { kind = "header", title = "PET SIZE" } }

  for _, width in ipairs(themes.petWidths) do
    local active = (state.petWidth == width)
    rows[#rows + 1] = {
      title = (active and "● " or "   ") .. width .. " px",
      hint = active and "on" or nil,
      keepOpen = true,
      rebuild = sizePage,
      fn = function()
        state.petWidth = width
        State.save(state)
        pet:reskin()
        redraw()
      end,
    }
  end

  rows[#rows + 1] = { kind = "sep" }
  rows[#rows + 1] = { title = "← Back", submenu = function() return actions() end }
  return rows
end

--- Pin, unpin or delete one item.
local function itemPage(item)
  local rows = { { kind = "header", title = string.upper(item.text:sub(1, 30)) } }

  for _, rank in ipairs(Priorities.ranks) do
    local active = (item.pinned == rank)
    rows[#rows + 1] = {
      title = (active and "● " or "   ") .. "Pin to " .. rank,
      hint = active and "pinned" or nil,
      fn = function()
        Priorities.pin(lists, item.id, rank)
        persist()
        redraw()
      end,
    }
  end

  rows[#rows + 1] = { kind = "sep" }
  rows[#rows + 1] = {
    title = item.done and "Mark not done" or "Mark done",
    fn = function()
      Priorities.toggleDone(lists, item.id)
      persist()
      redraw()
    end,
  }
  rows[#rows + 1] = {
    title = "Delete",
    fn = function()
      Priorities.remove(lists, item.id)
      persist()
      redraw()
    end,
  }
  rows[#rows + 1] = { kind = "sep" }
  rows[#rows + 1] = { title = "← Back", submenu = function() return actions() end }
  return rows
end

--- Which calendars cost reads. Nothing selected means all of them.
local LEAD_SETS = {
  { label = "30 · 10 · 3 min", leads = { 30, 10, 3 } },
  { label = "15 · 5 min",      leads = { 15, 5 } },
  { label = "10 · 2 min",      leads = { 10, 2 } },
  { label = "5 min only",      leads = { 5 } },
  { label = "1 hour · 15 · 5", leads = { 60, 15, 5 } },
}

local function remindersPage()
  local rows = { { kind = "header", title = "REMIND ME BEFORE" } }

  local on = state.reminders ~= false
  rows[#rows + 1] = {
    title = (on and "◉ " or "○ ") .. (on and "Reminders on" or "Reminders off"),
    keepOpen = true,
    rebuild = function() return remindersPage() end,
    fn = function()
      state.reminders = not on
      State.save(state)
      -- Clearing what has already fired lets a re-enable catch anything that is
      -- already inside a window, rather than staying silent until the next one.
      if state.reminders then Reminders.reset() end
    end,
  }

  rows[#rows + 1] = { kind = "sep" }

  local current = table.concat(state.leads or Reminders.defaultLeads, ",")
  for _, set in ipairs(LEAD_SETS) do
    local active = (table.concat(set.leads, ",") == current)
    rows[#rows + 1] = {
      title = (active and "● " or "   ") .. set.label,
      keepOpen = true,
      rebuild = function() return remindersPage() end,
      fn = function()
        state.leads = set.leads
        State.save(state)
        Reminders.reset()
      end,
    }
  end

  rows[#rows + 1] = { kind = "sep" }
  rows[#rows + 1] = {
    title = (state.smartNudges and "☑ " or "☐ ") .. "Let Claude word them",
    preview = state.smartNudges and "~$0.005 each · timing never waits on it"
                                or "plain \"X starts in 10 minutes\"",
    keepOpen = true,
    rebuild = function() return remindersPage() end,
    fn = function()
      state.smartNudges = not state.smartNudges
      State.save(state)
    end,
  }

  rows[#rows + 1] = { kind = "sep" }
  rows[#rows + 1] = { title = "← Back", submenu = function() return actions() end }
  return rows
end

local function calendarsPage()
  local chosen = {}
  local count = 0
  for _, name in ipairs(state.calendars or {}) do
    chosen[name] = true
    count = count + 1
  end
  local filtering = count > 0

  local rows = {
    { kind = "header",
      title = filtering and ("SHOWING " .. count .. " OF " .. #calendars)
                        or "SHOWING ALL CALENDARS" },
  }

  -- Tick as many as you like; the page stays open so picking several is one
  -- visit rather than one visit each.
  rows[#rows + 1] = {
    title = (not filtering and "◉ " or "○ ") .. "All of them",
    keepOpen = true,
    rebuild = function() return calendarsPage() end,
    fn = function()
      state.calendars = {}
      State.save(state)
      M.refreshCalendar()
    end,
  }
  rows[#rows + 1] = { kind = "sep" }

  for _, name in ipairs(calendars) do
    local on = chosen[name]
    rows[#rows + 1] = {
      title = (on and "☑ " or "☐ ") .. name,
      keepOpen = true,
      rebuild = function() return calendarsPage() end,
      fn = function()
        local next_ = {}
        for _, existing in ipairs(state.calendars or {}) do
          if existing ~= name then next_[#next_ + 1] = existing end
        end
        if not on then next_[#next_ + 1] = name end
        state.calendars = next_
        State.save(state)
        M.refreshCalendar()
      end,
    }
  end

  if #calendars == 0 then
    rows[#rows + 1] = { title = "No calendars found yet", hint = nil }
  end

  rows[#rows + 1] = { kind = "sep" }
  rows[#rows + 1] = { title = "← Back", submenu = function() return actions() end }
  return rows
end

local function appearancePage()
  return {
    { kind = "header", title = "APPEARANCE" },
    { title = "Theme", hint = "▸ " .. themes.label(), submenu = themePage },
    { title = "Pet size", hint = "▸ " .. state.petWidth, submenu = sizePage },
    { title = "Choose sprite…", preview = "any PNG — copied into assets/",
      fn = function() M.chooseSprite() end },
    { kind = "sep" },
    { title = "← Back", submenu = function() return actions() end },
  }
end

local function itemsPage()
  local rows = { { kind = "header", title = "EDIT AN ITEM" } }

  for _, item in ipairs(lists[scope()] or {}) do
    rows[#rows + 1] = {
      title = (item.done and "✓ " or "   ") .. item.text,
      hint = item.pinned or item.rank or nil,
      submenu = function() return itemPage(item) end,
    }
  end

  if #(lists[scope()] or {}) == 0 then
    rows[#rows + 1] = { title = "Nothing here yet", hint = nil }
  end

  rows[#rows + 1] = { kind = "sep" }
  rows[#rows + 1] = {
    title = "Clear completed",
    fn = function()
      Priorities.clearDone(lists, scope())
      persist()
      redraw()
    end,
  }
  rows[#rows + 1] = { title = "Refresh calendar", fn = function() M.refreshCalendar() end }
  rows[#rows + 1] = { kind = "sep" }
  rows[#rows + 1] = { title = "← Back", submenu = function() return actions() end }
  return rows
end

function actions()
  local rows = {}

  rows[#rows + 1] = {
    title = "Tell cost something…",
    hint = ASK_HINT,
    fn = function() M.talk() end,
  }
  rows[#rows + 1] = {
    title = "Add to " .. Priorities.label[scope()]:lower() .. " list",
    preview = "typed in exactly as written, no AI",
    fn = function() M.promptAdd() end,
  }
  rows[#rows + 1] = {
    title = "Rank with Claude",
    hint = Brain.available() and "↻" or "no CLI",
    fn = function() if Brain.available() then M.rank() end end,
  }
  rows[#rows + 1] = {
    title = board:isOpen() and "Close board" or "Show board",
    fn = function() M.toggleBoard() end,
  }

  rows[#rows + 1] = { kind = "sep" }

  for _, id in ipairs(Priorities.scopes) do
    local open = Priorities.count(lists, id)
    rows[#rows + 1] = {
      title = (scope() == id and "● " or "   ") .. Priorities.label[id],
      hint = open > 0 and tostring(open) or nil,
      fn = function() M.setScope(id) end,
    }
  end

  -- Everything below is grouped into submenus rather than listed flat. The
  -- drawn menu has no scrolling, so a long top level silently loses its last
  -- rows off the bottom of the screen.
  rows[#rows + 1] = { kind = "sep" }
  rows[#rows + 1] = { title = "Items", hint = "▸", submenu = itemsPage }
  rows[#rows + 1] = {
    title = "Calendars",
    hint = "▸ " .. ((state.calendars and #state.calendars > 0)
                    and (#state.calendars .. " chosen") or "all"),
    submenu = calendarsPage,
  }
  rows[#rows + 1] = {
    title = "Reminders",
    hint = "▸ " .. ((state.reminders ~= false)
             and table.concat(state.leads or Reminders.defaultLeads, "·") .. " min"
             or "off"),
    submenu = remindersPage,
  }
  rows[#rows + 1] = { title = "Appearance", hint = "▸ " .. themes.label(), submenu = appearancePage }

  rows[#rows + 1] = { kind = "sep" }
  rows[#rows + 1] = { title = "Hide pet", hint = HOTKEY_HINT, fn = function() M.hide() end }
  rows[#rows + 1] = { title = "Reload", fn = function() hs.reload() end }

  return rows
end

function M.showMenu()
  if menu:isOpen() then
    menu:hide()
    return
  end
  menu:show(actions(), hs.mouse.absolutePosition())
end

local function nativeMenu()
  local items = {}

  for _, row in ipairs(actions()) do
    if row.kind == "sep" then
      items[#items + 1] = { title = "-" }
    elseif row.kind == "header" then
      items[#items + 1] = { title = row.title, disabled = true }
    elseif row.submenu then
      local nested = {}
      for _, child in ipairs(row.submenu()) do
        if child.kind ~= "sep" and child.kind ~= "header" and not child.submenu then
          nested[#nested + 1] = {
            title = child.hint and (child.title .. "   " .. child.hint) or child.title,
            fn = child.fn,
          }
        end
      end
      items[#items + 1] = { title = row.title, menu = nested }
    else
      items[#items + 1] = {
        title = row.hint and (row.title .. "   " .. row.hint) or row.title,
        fn = row.fn,
      }
    end
  end

  return items
end

-- ------------------------------------------------------------------ control

--- Clicking the pet opens the board. It never triggers a Claude call — ranking
--- is always something you ask for.
function M.toggleBoard()
  if board:isOpen() then
    board:hide()
    state.boardOpen = false
  else
    board:setAnchor(pet:frame())
    board:show(compose())
    state.boardOpen = true
  end
  State.save(state)
end

function M.show()
  pet:show()
  State.save(state)
end

function M.hide()
  board:hide()
  pet:hide()
  state.boardOpen = false
  State.save(state)
end

function M.toggle()
  if pet:isHidden() then M.show() else M.hide() end
end

function M.chooseSprite()
  local picked = hs.dialog.chooseFileOrFolder(
    "Pick a PNG for your pet", os.getenv("HOME"), true, false, false, { "png" })
  if not picked or not picked["1"] then return end

  local input = io.open(picked["1"], "rb")
  if not input then return hs.alert.show("cost: couldn't read that file") end
  local bytes = input:read("*a")
  input:close()

  local output = io.open(hs.configdir .. "/cost/assets/pet.png", "wb")
  if not output then return hs.alert.show("cost: couldn't write the sprite") end
  output:write(bytes)
  output:close()

  pet:reskin()
  redraw()
  hs.alert.show("cost: new sprite in place")
end

function M.debug()
  return {
    hidden = pet and pet:isHidden(),
    scope = scope(),
    theme = themes.id,
    counts = {
      daily = Priorities.count(lists, "daily"),
      weekly = Priorities.count(lists, "weekly"),
      monthly = Priorities.count(lists, "monthly"),
    },
    events = #events,
    calendarNote = calendarNote,
    busy = busy,
    claude = Brain.executable() or "not found",
    helper = Calendar.available(),
    file = Priorities.file,
  }
end

-- -------------------------------------------------------------------- start

local function start()
  state = State.load()
  themes.set(state.theme or "claude")
  lists = Priorities.load()

  pet = Pet.new({
    state = state,
    onClick = function() M.toggleBoard() end,
    onDragEnd = function()
      State.save(state)
      if board then board:setAnchor(pet:frame()) end
      if bubble then bubble:setAnchor(pet:frame()) end
    end,
  })
  if not pet then return end

  board = Board.new({
    onRefresh = function() M.rank() end,
    onScope = function(id) M.setScope(id) end,
    onMenu = function() M.showMenu() end,
    onRow = function(row) M.onRow(row) end,
  })
  board:setAnchor(pet:frame())
  menu = Menu.new()
  bubble = Bubble.new()
  bubble:setAnchor(pet:frame())

  menubar = hs.menubar.new()
  if menubar then
    local icon = hs.image.imageFromPath(hs.configdir .. "/cost/assets/pet.png")
    if icon then
      local size = icon:size()
      local h = 18
      menubar:setIcon(icon:setSize({ w = math.floor(h * (size.w / size.h) + 0.5), h = h }), false)
    else
      menubar:setTitle("P0")
    end
    menubar:setMenu(nativeMenu)
  end

  hotkey = hs.hotkey.bind(HOTKEY[1], HOTKEY[2], function() M.toggle() end)
  askHotkey = hs.hotkey.bind(ASK_HOTKEY[1], ASK_HOTKEY[2], function() M.talk() end)

  -- The calendar refreshes on its own because it is free and local. Claude
  -- never does — that only happens when asked.
  M.refreshCalendar()

  -- Watch for what is about to start. Deterministic, local, and free — no
  -- model is involved in deciding when this fires.
  Reminders.start({
    events = function() return events end,
    leads = function() return state.leads or Reminders.defaultLeads end,
    enabled = function() return state.reminders ~= false end,
    onFire = fireReminder,
  })

  -- The calendar has to stay current or reminders fire against a stale day.
  -- Reading it is local and costs nothing, unlike ranking.
  calendarTimer = hs.timer.doEvery(300, function() M.refreshCalendar() end)

  waker = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake
       or event == hs.caffeinate.watcher.screensDidUnlock then
      hs.timer.doAfter(6, function() M.refreshCalendar() end)
    end
  end)
  waker:start()

  _G.PETS = _G.PETS or {}
  _G.PETS.cost = {
    name = "cost", label = "Cost", version = "0.2.0", api = 1,

    show = M.show, hide = M.hide, toggle = M.toggle, menu = M.showMenu,
    refresh = function() M.refreshCalendar() end,
    isHidden = function() return pet and pet:isHidden() end,
    frame    = function() return pet and pet:frame() end,

    -- Named so custom command bindings can reach them by action name.
    board = function() M.toggleBoard() end,
    add   = function() M.promptAdd() end,
    talk  = function() M.talk() end,
    rank  = function() M.rank() end,

    moveTo = function(x, y)
      if not pet then return end
      pet.baseX, pet.baseY = pet:clamp(x, y)
      state.x, state.y = pet.baseX, pet.baseY
      State.save(state)
      board:setAnchor(pet:frame())
    end,

    quit = function()
      if menu then menu:hide() end
      if board then board:delete(); board = nil end
      if bubble then bubble:delete(); bubble = nil end
      if pet then pet:delete(); pet = nil end
      if menubar then menubar:delete(); menubar = nil end
      if hotkey then hotkey:delete(); hotkey = nil end
      if askHotkey then askHotkey:delete(); askHotkey = nil end
      if Input then Input.hide() end
      if waker then waker:stop(); waker = nil end
      if calendarTimer then calendarTimer:stop(); calendarTimer = nil end
      Reminders.stop()
    end,
  }
end

start()

return M
