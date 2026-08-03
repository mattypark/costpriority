--- A speech bubble beside the pet.
---
--- Replaces hs.alert, which draws a black lozenge in the centre of the screen —
--- wrong in every way for this: it isn't attached to the pet, it covers whatever
--- you were reading, and it fades out on a timer whether or not you were done
--- with it.
---
--- This one sits diagonally off the pet's head, on whichever side has room, and
--- stays until dismissed. When it needs an answer the buttons live in a second
--- bubble below the first, so the question and the answer are visually separate.

local themes = require("cost.themes")

local Bubble = {}
Bubble.__index = Bubble

local W = 340
local PAD = 14
local GAP = 12          -- pet ↔ bubble
local STACK_GAP = 8     -- message ↔ actions
local TAIL = 9
local RADIUS = 13
local FADE = 0.12
local CLOSE = { size = 13, hit = 24 }
local ACTION_H = 30

function Bubble.new()
  return setmetatable({ anchor = { x = 0, y = 0, w = 0, h = 0 } }, Bubble)
end

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

function Bubble:setAnchor(frame)
  if frame then self.anchor = frame end
  if self.canvas then self:place() end
end

--- Above the pet and off to the side that has room, so it reads as coming from
--- the pet rather than sitting on top of it.
function Bubble:place()
  local screen = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):frame()
  local pet = self.anchor

  local onLeft = (pet.x + pet.w / 2) > (screen.x + screen.w / 2)
  local x = onLeft and (pet.x - W + pet.w * 0.25) or (pet.x + pet.w * 0.75)
  local y = pet.y - self.height - GAP

  -- No room above: sit below instead and flip the tail.
  self.below = false
  if y < screen.y + 8 then
    y = pet.y + pet.h + GAP
    self.below = true
  end

  x = math.max(screen.x + 8, math.min(x, screen.x + screen.w - W - 8))
  y = math.max(screen.y + 8, math.min(y, screen.y + screen.h - self.height - 8))

  self.onLeft = onLeft
  if self.canvas then self.canvas:frame({ x = x, y = y, w = W, h = self.height }) end
end

function Bubble:layout()
  -- The ✕ only overlaps the first line, so only the title has to make room for
  -- it. Measuring the body at the full width and drawing it at the same width is
  -- what stops the last line being clipped.
  local innerW = W - PAD * 2
  self.innerW = innerW

  local size = themes.bodySize + 0.5
  local wrapped, count = wrap(self.text or "", size, innerW)
  self.wrapped = wrapped
  self.messageH = count * lineHeight(size) + 4

  local h = PAD * 2 + self.messageH
  if self.title and self.title ~= "" then h = h + 18 end
  if self.actions and #self.actions > 0 then
    h = h + STACK_GAP + ACTION_H + 6
  end

  self.height = h + TAIL
end

function Bubble:render()
  if not self.canvas then return end

  local p = themes.palette()
  local canvas = self.canvas
  local bodyH = self.height - TAIL
  local top = self.below and TAIL or 0

  canvas:replaceElements({
    type = "rectangle",
    action = "strokeAndFill",
    roundedRectRadii = { xRadius = RADIUS, yRadius = RADIUS },
    fillColor = p.card,
    strokeColor = p.stroke,
    strokeWidth = 1,
    frame = { x = 0, y = top, w = W, h = bodyH },
  })

  -- The tail: a triangle pointing back at the pet. Above the pet it hangs off
  -- the bottom edge; below the pet it rises from the top.
  local tipX = self.onLeft and (W - 34) or 34
  local baseY = self.below and TAIL or bodyH
  local tipY  = self.below and 0 or (bodyH + TAIL)

  canvas:appendElements({
    type = "segments",
    action = "fill",
    fillColor = p.card,
    closed = true,
    coordinates = {
      { x = tipX - TAIL, y = baseY },
      { x = tipX + TAIL, y = baseY },
      { x = tipX,        y = tipY },
    },
  })

  local y = top + PAD

  if self.title and self.title ~= "" then
    canvas:appendElements({
      type = "text",
      text = styled(string.upper(self.title), themes.smallSize, p.dim),
      frame = { x = PAD, y = y - 2, w = W - PAD * 2 - 20, h = 16 },
    })
    y = y + 18
  end

  canvas:appendElements({
    type = "text",
    text = styled(self.wrapped or "", themes.bodySize + 0.5, p.text, "left", true),
    frame = { x = PAD, y = y, w = self.innerW, h = self.messageH },
  })

  canvas:appendElements({
    type = "text",
    text = styled("✕", CLOSE.size,
                  self.hover == "close" and p.accent or p.dim, "center"),
    frame = { x = W - PAD - 8, y = top + PAD - 3, w = 14, h = 18 },
  })

  if self.actions and #self.actions > 0 then
    local ay = top + bodyH - PAD - ACTION_H
    local width = math.floor((W - PAD * 2 - 8 * (#self.actions - 1)) / #self.actions)

    self.actionRects = {}
    for index, action in ipairs(self.actions) do
      local ax = PAD + (index - 1) * (width + 8)
      local hovered = (self.hover == index)
      local primary = (index == 1)

      canvas:appendElements({
        type = "rectangle",
        action = "strokeAndFill",
        roundedRectRadii = { xRadius = 8, yRadius = 8 },
        fillColor = primary and p.accent
                    or (hovered and p.hover or { white = 0, alpha = 0 }),
        strokeColor = primary and p.accent or p.stroke,
        strokeWidth = 1,
        frame = { x = ax, y = ay, w = width, h = ACTION_H },
      })

      canvas:appendElements({
        type = "text",
        text = styled(action.title, themes.bodySize,
                      primary and p.card or (hovered and p.accent or p.text),
                      "center"),
        frame = { x = ax, y = ay + 7, w = width, h = 20 },
      })

      self.actionRects[index] = { x = ax, y = ay, w = width, h = ACTION_H }
    end
  end
end

function Bubble:hitAt(x, y)
  local top = self.below and TAIL or 0
  if x >= W - CLOSE.hit and y <= top + CLOSE.hit then return "close" end

  for index, rect in ipairs(self.actionRects or {}) do
    if x >= rect.x and x <= rect.x + rect.w
       and y >= rect.y and y <= rect.y + rect.h then
      return index
    end
  end
  return nil
end

--- Show a message.
--- @param text string
--- @param opts table|nil {title=..., actions={{title=,fn=}}, onClose=fn}
function Bubble:say(text, opts)
  opts = opts or {}

  self.text = text or ""
  self.title = opts.title
  self.actions = opts.actions
  self.onClose = opts.onClose
  self.hover = nil
  self.actionRects = {}
  self:layout()

  if not self.canvas then
    self.canvas = hs.canvas.new({ x = 0, y = 0, w = W, h = self.height })
    self.canvas:level(hs.canvas.windowLevels.floating + 1)
    self.canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces
                       | hs.canvas.windowBehaviors.stationary)
    self.canvas:clickActivating(false)

    self.canvas:canvasMouseEvents(true, true, true, true)
    self.canvas:mouseCallback(function(_, event, _, cx, cy)
      if event == "mouseMove" or event == "mouseEnter" then
        local hit = self:hitAt(cx, cy)
        if hit ~= self.hover then
          self.hover = hit
          self:render()
        end

      elseif event == "mouseExit" then
        if self.hover then self.hover = nil; self:render() end

      elseif event == "mouseUp" then
        local hit = self:hitAt(cx, cy)
        if hit == "close" then
          local onClose = self.onClose
          self:hide()
          if onClose then onClose() end
        elseif type(hit) == "number" then
          local action = self.actions and self.actions[hit]
          self:hide()
          if action and action.fn then action.fn() end
        end
      end
    end)

    self:place()
    self:render()
    self.canvas:show(FADE)
  else
    self:place()
    self:render()
  end
end

function Bubble:isOpen()
  return self.canvas ~= nil
end

function Bubble:hide()
  if not self.canvas then return end
  local canvas = self.canvas
  self.canvas = nil
  self.actionRects = {}
  self.onClose = nil
  canvas:hide(FADE)
  hs.timer.doAfter(FADE + 0.05, function() canvas:delete() end)
end

function Bubble:delete()
  if self.canvas then self.canvas:delete(); self.canvas = nil end
end

return Bubble
