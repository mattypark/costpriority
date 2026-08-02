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
local Brain      = require("cost.brain")
local Calendar   = require("cost.sources.calendar")
local themes     = require("cost.themes")

local M = {}

local HOTKEY = { { "ctrl", "alt", "cmd" }, "i" }
local HOTKEY_HINT = "⌃⌥⌘I"

local state, pet, board, menu, menubar, hotkey, waker
local lists                    -- the three priority lists
local events = {}              -- today's calendar, for context
local calendarNote             -- why the calendar is missing, when it is
local busy = false             -- a Claude call is in flight

-- ------------------------------------------------------------------- helpers

local function scope()
  return state.scope or "daily"
end

--- "in 2h", "12:30", "all day" — short enough for the right-hand column.
local function eventNote(event, now)
  if event.allDay then return "all day" end
  if not event.start then return "" end

  if event.endTime and event.endTime <= now then return "done" end
  if event.start <= now then return "now" end
  return os.date("%H:%M", event.start)
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
    calendarRows[#calendarRows + 1] = {
      title = event.title or "Untitled",
      why = eventNote(event, now),
      calendarEvent = true,
    }
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
    calendarTitle = "TODAY'S CALENDAR" ..
                    (#calendarRows == 0 and " — nothing scheduled" or ""),
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
function M.refreshCalendar(callback)
  Calendar.fetch(function(fetched, err)
    if err then
      calendarNote = "Calendar unavailable — " .. err
      events = {}
    else
      calendarNote = nil
      events = fetched or {}
    end
    redraw()
    if callback then callback() end
  end)
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

--- Ask for text. A native prompt for now — the themed input bar replaces this,
--- and is the thing that makes dictation work.
local function ask(title, message)
  local button, text = hs.dialog.textPrompt(title, message, "", "Add", "Cancel")
  if button ~= "Add" then return nil end
  return text
end

function M.promptAdd(targetScope)
  targetScope = targetScope or scope()
  local text = ask("Add to your " .. Priorities.label[targetScope]:lower() .. " list",
                   "One priority. You can add more after.")
  if not text or text == "" then return end

  M.addPriority(text, targetScope)

  if not board:isOpen() then
    board:setAnchor(pet:frame())
    board:show(compose())
  end
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
  rows[#rows + 1] = { title = "← Back", submenu = function() return actions() end }
  return rows
end

function actions()
  local rows = {}

  rows[#rows + 1] = {
    title = "Add a priority…",
    hint = Priorities.label[scope()],
    fn = function() M.promptAdd() end,
  }
  rows[#rows + 1] = {
    title = "Rank with Claude",
    hint = Brain.available() and "↻" or "no CLI",
    preview = "orders this list, using your calendar as context",
    fn = function() if Brain.available() then M.rank() end end,
  }
  rows[#rows + 1] = {
    title = board:isOpen() and "Close board" or "Show board",
    fn = function() M.toggleBoard() end,
  }

  rows[#rows + 1] = { kind = "sep" }

  for _, id in ipairs(Priorities.scopes) do
    local active = (scope() == id)
    rows[#rows + 1] = {
      title = (active and "● " or "   ") .. Priorities.label[id],
      hint = Priorities.count(lists, id) > 0 and tostring(Priorities.count(lists, id)) or nil,
      fn = function() M.setScope(id) end,
    }
  end

  rows[#rows + 1] = { kind = "sep" }
  rows[#rows + 1] = { title = "Edit an item", submenu = itemsPage }
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
  rows[#rows + 1] = { title = "Theme", hint = "▸ " .. themes.label(), submenu = themePage }
  rows[#rows + 1] = { title = "Pet size", hint = "▸ " .. state.petWidth, submenu = sizePage }
  rows[#rows + 1] = {
    title = "Choose sprite…",
    preview = "any PNG — it's copied into assets/",
    fn = function() M.chooseSprite() end,
  }

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
    end,
  })
  if not pet then return end

  board = Board.new({
    onRefresh = function() M.rank() end,
    onScope = function(id) M.setScope(id) end,
    onRow = function(row) M.onRow(row) end,
  })
  board:setAnchor(pet:frame())
  menu = Menu.new()

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

  -- The calendar refreshes on its own because it is free and local. Claude
  -- never does — that only happens when asked.
  M.refreshCalendar()

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
      if pet then pet:delete(); pet = nil end
      if menubar then menubar:delete(); menubar = nil end
      if hotkey then hotkey:delete(); hotkey = nil end
      if waker then waker:stop(); waker = nil end
    end,
  }
end

start()

return M
