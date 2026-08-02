--- The priority board: one panel, four ranked rows, then everything else.
---
--- Unlike claudepet's speech bubbles this does not auto-expire. A briefing you
--- glance at twice an hour has to stay put; that difference in lifecycle is most
--- of why this is its own module rather than a reused stack.

local themes = require("cost.themes")

local Board = {}
Board.__index = Board

local FADE = 0.14
local CLOSE = { size = 16, hit = 26, inset = 12 }
local REFRESH = { size = 16, hit = 26, inset = 38 }

function Board.new(opts)
  opts = opts or {}
  return setmetatable({
    anchor = { x = 0, y = 0, w = 0, h = 0 },
    data = nil,
    onRefresh = opts.onRefresh,
    onRow = opts.onRow,
  }, Board)
end

-- ------------------------------------------------------------------- text

local function styled(text, size, color, align, wrap)
  return hs.styledtext.new(text, {
    font = { name = themes.fontName, size = size },
    color = color,
    paragraphStyle = {
      lineBreak = wrap and "wordWrap" or "truncateTail",
      alignment = align or "left",
    },
  })
end

--- Height a wrapped string needs at a given width. hs.drawing measures without
--- drawing anything, which is how the panel sizes itself to its content instead
--- of clipping it.
local function textHeight(text, size, width)
  local measured = hs.drawing.getTextDrawingSize(
    styled(text, size, { white = 0 }, "left", true),
    { w = width, h = 10000 }
  )
  return math.ceil((measured and measured.h or size + 4) + 1)
end

-- ------------------------------------------------------------------ layout

local RANK_W = 30      -- the "P0" gutter
local TIME_W = 46      -- right-hand time column

--- Measure every row up front, so the panel is drawn exactly once at the right
--- height rather than resized after the fact.
function Board:layout()
  local pad = themes.boardPad
  local innerW = themes.boardW - pad * 2
  local titleW = innerW - RANK_W - TIME_W - 8
  local bodyW = innerW - RANK_W

  local rows = {}
  local y = pad + 26     -- below the header

  local data = self.data or {}
  local priorities = data.priorities or {}

  if #priorities == 0 then
    local text = data.empty or "Nothing scheduled today."
    rows[#rows + 1] = {
      kind = "empty", text = text, y = y,
      h = textHeight(text, themes.bodySize, innerW),
    }
    y = y + rows[#rows].h + themes.rowGap

  else
    for _, item in ipairs(priorities) do
      local titleH = textHeight(item.title or "", themes.titleSize, titleW)
      local whyH = 0
      if item.why and item.why ~= "" then
        whyH = textHeight(item.why, themes.bodySize, bodyW) + 3
      end

      rows[#rows + 1] = {
        kind = "priority", item = item, y = y,
        titleH = titleH, whyH = whyH,
        h = titleH + whyH,
      }
      y = y + rows[#rows].h + themes.rowGap
    end
  end

  -- A titled block of plain lines: unranked items, completed items, the day's
  -- calendar. Same shape each time, so adding another section is one call.
  local function section(title, items, prefix)
    if not items or #items == 0 then return end

    y = y + 2
    rows[#rows + 1] = { kind = "rule", y = y, h = 1 }
    y = y + 11

    rows[#rows + 1] = { kind = "sectionHeader", title = title, y = y, h = 14 }
    y = y + 18

    for _, item in ipairs(items) do
      local text = (prefix or "· ") .. (item.title or "")
      local h = textHeight(text, themes.bodySize, innerW - 52)
      rows[#rows + 1] = {
        kind = "line", item = item, text = text,
        note = item.why, y = y, h = h,
      }
      y = y + h + 4
    end
    y = y - 4
  end

  section(data.restTitle or "EVERYTHING ELSE", data.rest)
  section("DONE", data.done, "✓ ")
  -- The calendar is shown whatever state it is in. An empty board that says
  -- nothing about the day is worse than one that says the day is over.
  section(data.calendarTitle or "TODAY'S CALENDAR", data.calendar)

  if data.note and data.note ~= "" then
    y = y + 10
    rows[#rows + 1] = {
      kind = "note", text = data.note, y = y,
      h = textHeight(data.note, themes.smallSize, innerW),
    }
    y = y + rows[#rows].h
  end

  self.rows = rows
  self.height = y + pad
end

-- ------------------------------------------------------------------- render

function Board:render()
  if not self.canvas then return end

  local palette = themes.palette()
  local pad = themes.boardPad
  local w = themes.boardW
  local innerW = w - pad * 2
  local canvas = self.canvas

  canvas:replaceElements({
    type = "rectangle",
    action = "strokeAndFill",
    roundedRectRadii = { xRadius = themes.radius, yRadius = themes.radius },
    fillColor = palette.card,
    strokeColor = palette.stroke,
    strokeWidth = 1,
    frame = { x = 0, y = 0, w = w, h = self.height },
  })

  -- Header: scope tabs on the left, refresh and close on the right.
  local data = self.data or {}
  self.tabs = {}

  if data.scopes then
    local x = pad
    for _, scope in ipairs(data.scopes) do
      local active = (scope.id == data.scope)
      local label = scope.label .. (scope.count > 0 and ("  " .. scope.count) or "")
      local width = #label * 7 + 12

      if active then
        canvas:appendElements({
          type = "rectangle",
          action = "fill",
          roundedRectRadii = { xRadius = 6, yRadius = 6 },
          fillColor = palette.hover,
          frame = { x = x - 5, y = pad - 5, w = width, h = 21 },
        })
      end

      canvas:appendElements({
        type = "text",
        text = styled(label, themes.smallSize,
                      active and palette.accent or palette.dim),
        frame = { x = x, y = pad - 2, w = width, h = 16 },
      })

      self.tabs[#self.tabs + 1] = { id = scope.id, x = x - 5, w = width }
      x = x + width + 6
    end

  else
    canvas:appendElements({
      type = "text",
      text = styled(string.upper(data.heading or "TODAY"), themes.smallSize, palette.dim),
      frame = { x = pad, y = pad - 2, w = innerW - 60, h = 16 },
    })
  end

  canvas:appendElements({
    type = "text",
    text = styled("↻", REFRESH.size, self.hover == "refresh" and palette.accent or palette.dim, "center"),
    frame = { x = w - REFRESH.inset - REFRESH.size, y = pad - 5, w = REFRESH.size, h = REFRESH.size + 4 },
  })
  canvas:appendElements({
    type = "text",
    text = styled("✕", CLOSE.size, self.hover == "close" and palette.accent or palette.dim, "center"),
    frame = { x = w - CLOSE.inset - CLOSE.size, y = pad - 5, w = CLOSE.size, h = CLOSE.size + 4 },
  })

  for index, row in ipairs(self.rows) do
    if row.kind == "priority" then
      local item = row.item
      local hovered = (self.hover == index)

      canvas:appendElements({
        type = "text",
        text = styled(item.rank or "", themes.rankSize, themes.rank(item.rank)),
        frame = { x = pad, y = row.y + 1, w = RANK_W, h = 18 },
      })

      canvas:appendElements({
        type = "text",
        text = styled(item.title or "", themes.titleSize,
                      hovered and palette.accent or palette.text, "left", true),
        frame = { x = pad + RANK_W, y = row.y, w = innerW - RANK_W - TIME_W - 8, h = row.titleH },
      })

      if item.when and item.when ~= "" then
        canvas:appendElements({
          type = "text",
          text = styled(item.when, themes.smallSize, palette.dim, "right"),
          frame = { x = w - pad - TIME_W, y = row.y + 2, w = TIME_W, h = 16 },
        })
      end

      if row.whyH > 0 then
        canvas:appendElements({
          type = "text",
          text = styled(item.why, themes.bodySize, palette.dim, "left", true),
          frame = { x = pad + RANK_W, y = row.y + row.titleH + 2, w = innerW - RANK_W, h = row.whyH },
        })
      end

    elseif row.kind == "rule" then
      canvas:appendElements({
        type = "rectangle",
        action = "fill",
        fillColor = palette.rule,
        frame = { x = pad, y = row.y, w = innerW, h = 1 },
      })

    elseif row.kind == "sectionHeader" then
      canvas:appendElements({
        type = "text",
        text = styled(row.title, themes.smallSize, palette.dim),
        frame = { x = pad, y = row.y, w = innerW, h = 16 },
      })

    elseif row.kind == "line" then
      local hovered = (self.hover == index)
      canvas:appendElements({
        type = "text",
        text = styled(row.text, themes.bodySize,
                      hovered and palette.accent or palette.dim, "left", true),
        frame = { x = pad, y = row.y, w = innerW - 52, h = row.h },
      })

      if row.note and row.note ~= "" then
        canvas:appendElements({
          type = "text",
          text = styled(row.note, themes.smallSize, palette.dim, "right"),
          frame = { x = w - pad - 50, y = row.y, w = 50, h = 16 },
        })
      end

    elseif row.kind == "empty" then
      canvas:appendElements({
        type = "text",
        text = styled(row.text, themes.bodySize, palette.dim, "left", true),
        frame = { x = pad, y = row.y, w = innerW, h = row.h },
      })

    elseif row.kind == "note" then
      canvas:appendElements({
        type = "text",
        text = styled(row.text, themes.smallSize, palette.dim, "left", true),
        frame = { x = pad, y = row.y, w = innerW, h = row.h },
      })
    end
  end
end

-- --------------------------------------------------------------- hit testing

--- Returns "close", "refresh", { tab = id }, a row index, or nil.
function Board:hitAt(x, y)
  local w = themes.boardW
  local headerBottom = themes.boardPad + 22

  if y <= headerBottom then
    if x >= w - CLOSE.hit then return "close" end
    if x >= w - CLOSE.hit - REFRESH.hit then return "refresh" end

    for _, tab in ipairs(self.tabs or {}) do
      if x >= tab.x and x < (tab.x + tab.w) then return { tab = tab.id } end
    end
    return nil
  end

  for index, row in ipairs(self.rows) do
    local reach = (row.kind == "priority") and themes.rowGap or 4
    if (row.kind == "priority" or row.kind == "line")
       and y >= row.y and y < (row.y + row.h + reach) then
      return index
    end
  end
  return nil
end

-- --------------------------------------------------------------- positioning

--- Anchor is the pet's frame; the board sits beside it on whichever side has
--- room, clamped to stay on screen.
function Board:setAnchor(frame)
  if frame then self.anchor = frame end
  if self.canvas then self.canvas:topLeft(self:origin()) end
end

function Board:origin()
  local screen = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):frame()
  local pet = self.anchor
  local onLeft = (pet.x + pet.w / 2) > (screen.x + screen.w / 2)

  local x = onLeft and (pet.x - themes.boardW - themes.boardGap)
                    or (pet.x + pet.w + themes.boardGap)
  local y = pet.y + math.floor(pet.h / 2) - math.floor(self.height / 2)

  x = math.max(screen.x + 8, math.min(x, screen.x + screen.w - themes.boardW - 8))
  y = math.max(screen.y + 8, math.min(y, screen.y + screen.h - self.height - 8))
  return { x = x, y = y }
end

-- --------------------------------------------------------------------- show

function Board:isOpen()
  return self.canvas ~= nil
end

--- Draw `data`. Called both to open the board and to update it in place, so a
--- refresh doesn't flicker the panel away and back.
function Board:show(data)
  self.data = data or self.data
  self.hover = nil
  self:layout()

  local origin = self:origin()
  local frame = { x = origin.x, y = origin.y, w = themes.boardW, h = self.height }

  if self.canvas then
    self.canvas:frame(frame)
    self:render()
    return
  end

  self.canvas = hs.canvas.new(frame)
  self.canvas:level(hs.canvas.windowLevels.floating + 1)
  self.canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces
                     | hs.canvas.windowBehaviors.stationary)
  self.canvas:clickActivating(false)
  self:render()

  self.canvas:canvasMouseEvents(true, true, true, true)
  self.canvas:mouseCallback(function(_, event, _, cx, cy)
    if event == "mouseMove" or event == "mouseEnter" then
      local hit = self:hitAt(cx, cy)
      if hit ~= self.hover then
        self.hover = hit
        self:render()
      end

    elseif event == "mouseExit" then
      if self.hover then
        self.hover = nil
        self:render()
      end

    elseif event == "mouseUp" then
      local hit = self:hitAt(cx, cy)

      if hit == "close" then
        self:hide()
      elseif hit == "refresh" then
        if self.onRefresh then self.onRefresh() end
      elseif type(hit) == "table" and hit.tab then
        if self.onScope then self.onScope(hit.tab) end
      elseif type(hit) == "number" then
        local row = self.rows[hit]
        if row and row.item and self.onRow then self.onRow(row.item, row.kind) end
      end
    end
  end)

  self.canvas:show(FADE)
end

--- Swap in new data only if the board is already open — used by a background
--- refresh, which should never pop the panel up on its own.
function Board:update(data)
  self.data = data
  if self.canvas then self:show(data) end
end

function Board:hide()
  if not self.canvas then return end
  local canvas = self.canvas
  self.canvas = nil
  self.hover = nil
  canvas:hide(FADE)
  hs.timer.doAfter(FADE + 0.05, function() canvas:delete() end)
end

function Board:toggle(data)
  if self:isOpen() then self:hide() else self:show(data) end
end

function Board:delete()
  if self.canvas then self.canvas:delete(); self.canvas = nil end
end

return Board
