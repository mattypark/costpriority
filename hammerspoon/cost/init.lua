--- cost — a desktop pet that tells you today's top priorities.
---
--- Click him and a board appears: P0 through P3, then everything else. The
--- ranking comes from your calendar, ordered either by `claude -p` or, when that
--- is unavailable, by a deterministic ranker that always answers.
---
--- Phase 1: sprite, board, themes and the pet bus, driven by sample events. No
--- macOS permission is required to run any of this.

local State    = require("cost.state")
local Pet      = require("cost.pet")
local Board    = require("cost.board")
local Menu     = require("cost.menu")
local Ranker   = require("cost.ranker")
local Brain    = require("cost.brain")
local Cache    = require("cost.cache")
local Calendar = require("cost.sources.calendar")
local Fake     = require("cost.sources.fake")
local themes   = require("cost.themes")

local M = {}

local HOTKEY = { { "ctrl", "alt", "cmd" }, "i" }
local HOTKEY_HINT = "⌃⌥⌘I"
local MORNING = "07:00"

local state, pet, board, menu, menubar, hotkey, morningTimer, waker
local data                     -- the last ranking we drew
local generatedAt              -- epoch seconds of that ranking
local fetching = false         -- a refresh is in flight; clicks shouldn't stack

-- ------------------------------------------------------------------ ranking

local function today()
  return os.date("%Y-%m-%d")
end

--- Stale once the day rolls over, or after four hours — long enough that the
--- morning briefing survives a lunch break, short enough that an afternoon
--- click doesn't show you this morning's plan.
local function isStale()
  if not data or not generatedAt then return true end
  if os.date("%Y-%m-%d", generatedAt) ~= today() then return true end
  return (os.time() - generatedAt) > (4 * 3600)
end

--- Draw a finished ranking, and remember it for the rest of the day.
local function present(ranked, opts)
  opts = opts or {}

  data = ranked
  generatedAt = ranked.generatedAt or os.time()
  ranked.generatedAt = generatedAt

  pet:setBusy(false)

  if not opts.fromCache then Cache.write(ranked) end

  if opts.open then
    board:setAnchor(pet:frame())
    board:show(data)
    if not opts.quiet then pet:nudge() end
  else
    board:update(data)
  end

  return data
end

--- Which engine produced this, said plainly on the board. Silent degradation is
--- the failure mode worth designing against here: an offline ranking that looks
--- identical to a considered one is worse than an obviously blunt one.
local function note(engine, events, detail)
  local count = #events .. (#events == 1 and " event" or " events") .. " today"
  if engine == "ai" then return "Ranked by Claude · " .. count end
  if detail then return "Offline ranking · " .. detail end
  return "Offline ranking · " .. count
end

--- Fetch today's events, rank them, draw the board.
---
--- calendar -> claude -> deterministic ranker, each falling through to the next.
--- Every failure path still produces a board: an empty one carrying the reason
--- beats a click that appears to do nothing.
function M.refresh(opts)
  opts = opts or {}

  if fetching then return end
  fetching = true
  pet:setBusy(true)

  local function offline(events, detail)
    local ranked = Ranker.rank(events)
    ranked.heading = os.date("%A %d %B")
    ranked.note = note("offline", events, detail)
    ranked.engine = "offline"
    present(ranked, opts)
  end

  Calendar.fetch(function(events, err)
    if err then
      fetching = false
      -- Sample data rather than a blank board, labelled so it cannot be
      -- mistaken for the real day.
      local ranked = Ranker.rank(Fake.events())
      ranked.heading = os.date("%A %d %B") .. "  ·  sample data"
      ranked.note = "Couldn't read the calendar — " .. err
      ranked.engine = "sample"
      present(ranked, opts)
      return
    end

    if not state.useAI or not Brain.available() or #events == 0 then
      fetching = false
      offline(events, not Brain.available() and "claude CLI not found" or nil)
      return
    end

    Brain.rank(events, { model = state.model }, function(ranked, brainErr)
      fetching = false

      if not ranked then
        offline(events, brainErr)
        return
      end

      ranked.heading = os.date("%A %d %B")
      ranked.note = note("ai", events)
      ranked.engine = "ai"
      ranked.empty = "Nothing left on the calendar today."
      present(ranked, opts)
    end)
  end)
end

--- Refresh only if what we hold is stale. The morning timer and the wake
--- watcher both come through here, so neither re-ranks a day that is already
--- ranked.
function M.refreshIfStale(opts)
  if not isStale() then return end
  M.refresh(opts)
end

--- Click behaviour: toggle the board, and refresh on the way if what we're
--- holding is stale. A plain click on fresh data costs nothing.
function M.toggleBoard()
  if board:isOpen() then
    board:hide()
    state.boardOpen = false
    State.save(state)
    return
  end

  if isStale() then
    M.refresh({ open = true })
  else
    board:setAnchor(pet:frame())
    board:show(data)
  end

  state.boardOpen = true
  State.save(state)
end

-- --------------------------------------------------------------------- menu

local actions   -- forward declaration; submenu pages reference each other

--- The theme page. Rows stay open when clicked so you can flick through the
--- palettes and watch the board change under the menu.
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
        pet:reskin()                 -- a theme may ship its own sprite
        board:setAnchor(pet:frame())
        if board:isOpen() then board:show(data) end
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
        board:setAnchor(pet:frame())
      end,
    }
  end

  rows[#rows + 1] = { kind = "sep" }
  rows[#rows + 1] = { title = "← Back", submenu = function() return actions() end }
  return rows
end

--- Copy a chosen PNG into assets/ so swapping the sprite never means a trip to
--- the Finder. Reads as the pet's own drawing from then on.
function M.chooseSprite()
  local picked = hs.dialog.chooseFileOrFolder(
    "Pick a PNG for your pet", os.getenv("HOME"), true, false, false, { "png" })
  if not picked or not picked["1"] then return end

  local source = picked["1"]
  local target = hs.configdir .. "/cost/assets/pet.png"

  local input = io.open(source, "rb")
  if not input then
    hs.alert.show("cost: couldn't read " .. source)
    return
  end
  local bytes = input:read("*a")
  input:close()

  local output = io.open(target, "wb")
  if not output then
    hs.alert.show("cost: couldn't write " .. target)
    return
  end
  output:write(bytes)
  output:close()

  pet:reskin()
  board:setAnchor(pet:frame())
  hs.alert.show("cost: new sprite in place")
end

function actions()
  local rows = {}

  rows[#rows + 1] = {
    title = board:isOpen() and "Close board" or "Show board",
    fn = function() M.toggleBoard() end,
  }
  rows[#rows + 1] = {
    title = "Refresh now",
    hint = generatedAt and os.date("%H:%M", generatedAt) or nil,
    fn = function() M.refresh({ open = true }) end,
  }

  rows[#rows + 1] = { kind = "sep" }

  local brainReady = Brain.available()
  rows[#rows + 1] = {
    title = state.useAI and "Ranked by Claude" or "Offline ranking",
    hint = brainReady and (state.useAI and "on" or "off") or "no CLI",
    preview = brainReady
      and (state.useAI and "~$0.005 a refresh · falls back if it fails"
                       or "keyword scoring only, instant and free")
      or "install the claude CLI to enable",
    fn = function()
      if not brainReady then return end
      state.useAI = not state.useAI
      State.save(state)
      M.refresh({ open = true })
    end,
  }

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

--- The menu bar item needs AppKit's menu, so map the same rows onto it.
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

--- Current internals, for troubleshooting from the Hammerspoon console.
function M.debug()
  return {
    hidden = pet and pet:isHidden(),
    theme = themes.id,
    petWidth = state.petWidth,
    boardOpen = board and board:isOpen(),
    generatedAt = generatedAt and os.date("%Y-%m-%d %H:%M", generatedAt) or nil,
    stale = isStale(),
    engine = data and data.engine or nil,
    useAI = state.useAI,
    claude = Brain.executable() or "not found",
    helper = require("cost.sources.calendar").available(),
    priorities = data and #(data.priorities or {}) or 0,
    rest = data and #(data.rest or {}) or 0,
    position = pet and { x = pet.baseX, y = pet.baseY } or nil,
  }
end

-- -------------------------------------------------------------------- start

local function start()
  state = State.load()
  themes.set(state.theme or "claude")

  pet = Pet.new({
    state = state,
    onClick = function() M.toggleBoard() end,
    onDragEnd = function()
      State.save(state)
      board:setAnchor(pet:frame())
    end,
  })
  if not pet then return end

  board = Board.new({
    onRefresh = function() M.refresh({ open = true }) end,
  })
  board:setAnchor(pet:frame())
  menu = Menu.new()

  menubar = hs.menubar.new()
  if menubar then
    local icon = hs.image.imageFromPath(hs.configdir .. "/cost/assets/pet.png")
    if icon then
      -- Sized to the sprite's own proportions rather than a square, so the
      -- menu bar doesn't squash whichever drawing is in assets/.
      local size = icon:size()
      local h = 18
      menubar:setIcon(icon:setSize({ w = math.floor(h * (size.w / size.h) + 0.5), h = h }), false)
    else
      menubar:setTitle("P0")
    end
    menubar:setMenu(nativeMenu)
  end

  hotkey = hs.hotkey.bind(HOTKEY[1], HOTKEY[2], function() M.toggle() end)

  -- Today's ranking, if it was already worked out. Costs nothing and means a
  -- reload never re-ranks a day that's already ranked.
  Cache.prune()
  local cached = Cache.read()
  if cached and cached.priorities then
    data = cached
    generatedAt = cached.generatedAt
  end

  -- The morning briefing. doAt alone is not enough: it silently skips when the
  -- Mac is asleep at the appointed time, which for a 7am job is the normal case
  -- rather than the exception. The wake watcher is what actually makes this
  -- fire most mornings.
  morningTimer = hs.timer.doAt(MORNING, "1d", function() M.refreshIfStale() end)

  waker = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake
       or event == hs.caffeinate.watcher.screensDidUnlock then
      -- Let the network and calendar sync settle before asking.
      hs.timer.doAfter(6, function() M.refreshIfStale() end)
    end
  end)
  waker:start()

  -- Register with the pet bus so a manager can hide or quit every pet at once.
  _G.PETS = _G.PETS or {}
  _G.PETS.cost = {
    name = "cost", label = "Cost", version = "0.1.0", api = 1,

    show = M.show, hide = M.hide, toggle = M.toggle, menu = M.showMenu,
    refresh = function() M.refresh({ open = true }) end,
    isHidden = function() return pet and pet:isHidden() end,
    frame    = function() return pet and pet:frame() end,

    moveTo = function(x, y)
      if not pet then return end
      pet.baseX, pet.baseY = pet:clamp(x, y)
      state.x, state.y = pet.baseX, pet.baseY
      State.save(state)
      board:setAnchor(pet:frame())
    end,

    -- Idempotent: the manager calls this twice on "turn off".
    quit = function()
      if menu then menu:hide() end
      if board then board:delete(); board = nil end
      if pet then pet:delete(); pet = nil end
      if menubar then menubar:delete(); menubar = nil end
      if hotkey then hotkey:delete(); hotkey = nil end
      if morningTimer then morningTimer:stop(); morningTimer = nil end
      if waker then waker:stop(); waker = nil end
    end,
  }
end

start()

return M
