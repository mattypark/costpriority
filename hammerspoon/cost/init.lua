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
local Calendar = require("cost.sources.calendar")
local Fake     = require("cost.sources.fake")
local themes   = require("cost.themes")

local M = {}

local HOTKEY = { { "ctrl", "alt", "cmd" }, "i" }
local HOTKEY_HINT = "⌃⌥⌘I"

local state, pet, board, menu, menubar, hotkey
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

--- Draw a finished ranking.
local function present(ranked, opts)
  data = ranked
  generatedAt = os.time()

  pet:setBusy(false)

  if opts.open then
    board:setAnchor(pet:frame())
    board:show(data)
    pet:nudge()
  else
    board:update(data)
  end

  return data
end

--- Fetch today's events, rank them, draw the board.
---
--- Every failure path still produces a board: an empty one with the reason on
--- it beats a click that appears to do nothing.
function M.refresh(opts)
  opts = opts or {}

  if fetching then return end
  fetching = true

  pet:setBusy(true)

  Calendar.fetch(function(events, err)
    fetching = false

    if err then
      -- Fall back to the sample day rather than showing nothing, and say so
      -- plainly on the board so it can't be mistaken for real events.
      local ranked = Ranker.rank(Fake.events())
      ranked.heading = os.date("%A %d %B") .. "  ·  sample data"
      ranked.note = "Couldn't read the calendar — " .. err
      present(ranked, opts)
      return
    end

    local ranked = Ranker.rank(events)
    ranked.heading = os.date("%A %d %B")
    ranked.note = "Offline ranking · " .. #events .. " events today"
    ranked.empty = "Nothing on the calendar today."
    present(ranked, opts)
  end)
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
    end,
  }
end

start()

return M
