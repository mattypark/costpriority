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
-- Clicking the pet opens the board, so the menu needs its own way in.
local MENU = { size = 16, hit = 26, inset = 64 }

function Board.new(opts)
  opts = opts or {}
  return setmetatable({
    anchor = { x = 0, y = 0, w = 0, h = 0 },
    data = nil,
    onRefresh = opts.onRefresh,
    onRow = opts.onRow,
    onScope = opts.onScope,   -- clicking a Daily/Weekly/Monthly tab
    onMenu = opts.onMenu,     -- the ⋯ button
    tabs = {},
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

--- Wrap to a pixel width.
---
--- hs.drawing.getTextDrawingSize takes a *style* as its second argument, not a
--- size — there is no width to constrain against, so it always reports a single
--- line and every wrapped block was being clipped to one. Menlo is monospace, so
--- the honest fix is to wrap ourselves: the advance width is a fixed fraction of
--- the point size, which makes the character count per line exact.
local function wrap(text, size, width)
  local perLine = math.max(8, math.floor(width / (size * 0.6)))
  local lines = {}

  for paragraph in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    if paragraph == "" then
      lines[#lines + 1] = ""
    else
      local line = ""
      for word in paragraph:gmatch("%S+") do
        if line == "" then
          line = word
        elseif #line + 1 + #word <= perLine then
          line = line .. " " .. word
        else
          lines[#lines + 1] = line
          line = word
        end

        -- A single word longer than the line has to be broken, or it would
        -- overflow the bubble instead of wrapping.
        while #line > perLine do
          lines[#lines + 1] = line:sub(1, perLine)
          line = line:sub(perLine + 1)
        end
      end
      if line ~= "" then lines[#lines + 1] = line end
    end
  end

  if #lines == 0 then lines[1] = "" end
  return table.concat(lines, "\n"), #lines
end

local function lineHeight(size)
  return math.ceil(size * 1.42)
end

--- Height only, for rows that draw their own text.
local function textHeight(text, size, width)
  local _, count = wrap(text, size, width)
  return count * lineHeight(size) + 2
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

  -- The calendar is drawn as blocks rather than a list, because that is what a
  -- calendar looks like and the shape carries information a bullet cannot: how
  -- long something is, which calendar it came from, whether it has passed. It
  -- is shown whatever state it is in — a board that says nothing about the day
  -- is worse than one that says the day is over.
  local calendar = data.calendar or {}
  y = y + 2
  rows[#rows + 1] = { kind = "rule", y = y, h = 1 }
  y = y + 11
  rows[#rows + 1] = {
    kind = "sectionHeader", title = data.calendarTitle or "TODAY'S CALENDAR",
    y = y, h = 14,
  }
  y = y + 20

  if #calendar == 0 then
    rows[#rows + 1] = {
      kind = "empty", text = data.calendarEmpty or "Nothing scheduled.", y = y,
      h = textHeight(data.calendarEmpty or "Nothing scheduled.", themes.bodySize, innerW),
    }
    y = y + rows[#rows].h

  else
    for _, item in ipairs(calendar) do
      local titleH = textHeight(item.title or "", themes.bodySize, innerW - 22)
      -- Every block gets a time line under the title, so height is title plus
      -- one line plus padding — never shorter than a comfortable tap target.
      local h = math.max(38, titleH + 14 + 10)
      rows[#rows + 1] = { kind = "block", item = item, y = y, h = h, titleH = titleH }
      y = y + h + 5
    end
    y = y - 5
  end

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
      -- Menlo's advance is 0.6em, so the text width is exact. The pill is that
      -- plus equal padding either side; deriving the pill from the text (rather
      -- than the text from a guessed pill) is what keeps it centred on labels
      -- of different lengths.
      local textW = math.ceil(#label * themes.smallSize * 0.6)
      local width = textW + 16

      if active then
        canvas:appendElements({
          type = "rectangle",
          action = "fill",
          roundedRectRadii = { xRadius = 6, yRadius = 6 },
          fillColor = palette.hover,
          frame = { x = x - 8, y = pad - 5, w = width, h = 21 },
        })
      end

      canvas:appendElements({
        type = "text",
        text = styled(label, themes.smallSize,
                      active and palette.accent or palette.dim),
        frame = { x = x, y = pad - 2, w = textW + 2, h = 16 },
      })

      self.tabs[#self.tabs + 1] = { id = scope.id, x = x - 8, w = width }
      x = x + width
    end

    -- Settings lives with the scope tabs rather than only behind ⋯, because
    -- that is where it was looked for.
    local label = "Settings"
    local textW = math.ceil(#label * themes.smallSize * 0.6)
    local width = textW + 16

    if self.hover == "menu" then
      canvas:appendElements({
        type = "rectangle",
        action = "fill",
        roundedRectRadii = { xRadius = 6, yRadius = 6 },
        fillColor = palette.hover,
        frame = { x = x - 8, y = pad - 5, w = width, h = 21 },
      })
    end
    canvas:appendElements({
      type = "text",
      text = styled(label, themes.smallSize,
                    self.hover == "menu" and palette.accent or palette.dim),
      frame = { x = x, y = pad - 2, w = textW + 2, h = 16 },
    })
    self.settingsTab = { x = x - 8, w = width }

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

    elseif row.kind == "block" then
      local item = row.item
      local hovered = (self.hover == index)

      -- The calendar's own colour, dimmed for anything already finished so the
      -- day reads at a glance: bright is ahead of you, faded is behind.
      local base = item.color
        and { red = item.color[1], green = item.color[2], blue = item.color[3], alpha = 1 }
        or palette.accent
      local past = (item.state == "done")
      -- Some calendars are grey. A weak tint on grey is indistinguishable from
      -- the card, so blocks carry a visible border as well as a fill.
      local fillA = past and 0.14 or 0.30
      local barA = past and 0.40 or 1.0

      canvas:appendElements({
        type = "rectangle",
        action = "fill",
        roundedRectRadii = { xRadius = 7, yRadius = 7 },
        fillColor = { red = base.red, green = base.green, blue = base.blue,
                      alpha = hovered and (fillA + 0.12) or fillA },
        frame = { x = pad, y = row.y, w = innerW, h = row.h },
      })

      canvas:appendElements({
        type = "rectangle",
        action = "stroke",
        roundedRectRadii = { xRadius = 7, yRadius = 7 },
        strokeColor = { red = base.red, green = base.green, blue = base.blue,
                        alpha = past and 0.30 or 0.55 },
        strokeWidth = 1,
        frame = { x = pad, y = row.y, w = innerW, h = row.h },
      })

      -- A solid spine down the left edge, the way calendars mark an event's
      -- source colour.
      canvas:appendElements({
        type = "rectangle",
        action = "fill",
        roundedRectRadii = { xRadius = 2, yRadius = 2 },
        fillColor = { red = base.red, green = base.green, blue = base.blue, alpha = barA },
        frame = { x = pad + 4, y = row.y + 5, w = 3, h = row.h - 10 },
      })

      canvas:appendElements({
        type = "text",
        text = styled(item.title or "", themes.bodySize,
                      past and palette.dim or palette.text, "left", true),
        frame = { x = pad + 14, y = row.y + 5, w = innerW - 22, h = row.titleH },
      })

      canvas:appendElements({
        type = "text",
        text = styled(item.when or "", themes.smallSize, palette.dim),
        frame = { x = pad + 14, y = row.y + 5 + row.titleH, w = innerW - 22, h = 14 },
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
  -- Generous, because the tabs are small text and a near miss reads as the
  -- board being unresponsive rather than as a miss.
  local headerBottom = themes.boardPad + 26

  if y <= headerBottom then
    if x >= w - CLOSE.hit then return "close" end
    if x >= w - CLOSE.hit - REFRESH.hit then return "refresh" end

    for _, tab in ipairs(self.tabs or {}) do
      if x >= tab.x and x < (tab.x + tab.w) then return { tab = tab.id } end
    end

    local settings = self.settingsTab
    if settings and x >= settings.x and x < (settings.x + settings.w) then
      return "menu"
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
      elseif hit == "menu" then
        if self.onMenu then self.onMenu() end
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
