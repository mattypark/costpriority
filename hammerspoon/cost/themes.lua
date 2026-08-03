--- Look-and-feel for the priority board. Eight palettes, all data — adding a
--- ninth means adding a row to `palettes`, nothing else.
---
--- The structural difference from a plain two-tone theme is `p0`..`p3`: a board
--- whose whole job is ranking needs rank to be legible at a glance, not just
--- decorative. Every palette earns its four rank colours separately rather than
--- tinting one hue, so P0 always reads hottest.

local Themes = {}

local function rgb(r, g, b, a)
  return { red = r, green = g, blue = b, alpha = a or 1 }
end

-- Order the menu lists them in.
Themes.order = {
  "cost", "kaws", "claude", "midnight", "mono", "ember", "forest", "plum",
  "sand", "matrix",
}

local palettes = {
  -- The pet is a green ghost on cream; the default theme should look like him
  -- rather than like Claude.
  cost = {
    label = "Cost", dark = false,
    card   = rgb(0.98, 0.97, 0.94, 0.99),
    stroke = rgb(0.36, 0.52, 0.38, 0.30),
    text   = rgb(0.11, 0.15, 0.12),
    dim    = rgb(0.42, 0.48, 0.43),
    accent = rgb(0.35, 0.56, 0.38),
    hover  = rgb(0.35, 0.56, 0.38, 0.13),
    rule   = rgb(0.16, 0.24, 0.18, 0.13),
    p0 = rgb(0.72, 0.30, 0.18), p1 = rgb(0.35, 0.56, 0.38),
    p2 = rgb(0.44, 0.55, 0.48), p3 = rgb(0.52, 0.56, 0.53),
  },

  -- Bone white, heavy black, one loud accent — the palette the name suggests.
  kaws = {
    label = "Kaws", dark = false,
    card   = rgb(0.96, 0.95, 0.92, 0.99),
    stroke = rgb(0.06, 0.06, 0.06, 0.55),
    text   = rgb(0.05, 0.05, 0.05),
    dim    = rgb(0.40, 0.40, 0.40),
    accent = rgb(0.85, 0.24, 0.16),
    hover  = rgb(0.06, 0.06, 0.06, 0.08),
    rule   = rgb(0.06, 0.06, 0.06, 0.22),
    p0 = rgb(0.85, 0.24, 0.16), p1 = rgb(0.06, 0.06, 0.06),
    p2 = rgb(0.42, 0.42, 0.42), p3 = rgb(0.62, 0.62, 0.62),
  },

  claude = {
    label = "Claude", dark = false,
    card   = rgb(0.99, 0.97, 0.94, 0.99),
    stroke = rgb(0.80, 0.36, 0.20, 0.30),
    text   = rgb(0.13, 0.11, 0.10),
    dim    = rgb(0.45, 0.41, 0.38),
    accent = rgb(0.82, 0.31, 0.16),
    hover  = rgb(0.82, 0.31, 0.16, 0.13),
    rule   = rgb(0.20, 0.14, 0.10, 0.11),
    p0 = rgb(0.80, 0.20, 0.11), p1 = rgb(0.86, 0.45, 0.13),
    p2 = rgb(0.62, 0.48, 0.20), p3 = rgb(0.48, 0.44, 0.40),
  },

  midnight = {
    label = "Midnight", dark = true,
    card   = rgb(0.043, 0.063, 0.110, 0.98),
    stroke = rgb(0.31, 0.55, 0.95, 0.30),
    text   = rgb(0.93, 0.95, 0.99),
    dim    = rgb(0.55, 0.61, 0.72),
    accent = rgb(0.35, 0.62, 1.00),
    hover  = rgb(0.35, 0.62, 1.00, 0.16),
    rule   = rgb(1, 1, 1, 0.09),
    p0 = rgb(0.42, 0.72, 1.00), p1 = rgb(0.36, 0.85, 0.88),
    p2 = rgb(0.52, 0.60, 0.85), p3 = rgb(0.48, 0.53, 0.63),
  },

  mono = {
    label = "Black & white", dark = false,
    card   = rgb(1, 1, 1, 0.99),
    stroke = rgb(0, 0, 0, 0.42),
    text   = rgb(0.04, 0.04, 0.04),
    dim    = rgb(0.42, 0.42, 0.42),
    accent = rgb(0.04, 0.04, 0.04),
    hover  = rgb(0, 0, 0, 0.09),
    rule   = rgb(0, 0, 0, 0.16),
    p0 = rgb(0.02, 0.02, 0.02), p1 = rgb(0.28, 0.28, 0.28),
    p2 = rgb(0.50, 0.50, 0.50), p3 = rgb(0.68, 0.68, 0.68),
  },

  ember = {
    label = "Orange & black", dark = true,
    card   = rgb(0.035, 0.031, 0.028, 0.98),
    stroke = rgb(1.00, 0.45, 0.05, 0.34),
    text   = rgb(0.98, 0.95, 0.90),
    dim    = rgb(0.60, 0.55, 0.48),
    accent = rgb(1.00, 0.50, 0.06),
    hover  = rgb(1.00, 0.50, 0.06, 0.16),
    rule   = rgb(1, 0.7, 0.4, 0.11),
    p0 = rgb(1.00, 0.36, 0.04), p1 = rgb(1.00, 0.60, 0.10),
    p2 = rgb(0.90, 0.76, 0.30), p3 = rgb(0.58, 0.52, 0.44),
  },

  forest = {
    label = "Nature", dark = true,
    card   = rgb(0.043, 0.086, 0.067, 0.98),
    stroke = rgb(0.30, 0.72, 0.45, 0.30),
    text   = rgb(0.92, 0.97, 0.93),
    dim    = rgb(0.55, 0.68, 0.58),
    accent = rgb(0.34, 0.80, 0.50),
    hover  = rgb(0.34, 0.80, 0.50, 0.15),
    rule   = rgb(0.7, 1, 0.8, 0.10),
    p0 = rgb(0.98, 0.78, 0.30), p1 = rgb(0.42, 0.85, 0.55),
    p2 = rgb(0.40, 0.70, 0.62), p3 = rgb(0.48, 0.58, 0.51),
  },

  plum = {
    label = "Plum", dark = true,
    card   = rgb(0.078, 0.047, 0.098, 0.98),
    stroke = rgb(0.70, 0.42, 0.95, 0.30),
    text   = rgb(0.96, 0.93, 0.98),
    dim    = rgb(0.64, 0.57, 0.72),
    accent = rgb(0.76, 0.48, 1.00),
    hover  = rgb(0.76, 0.48, 1.00, 0.16),
    rule   = rgb(1, 0.9, 1, 0.10),
    p0 = rgb(1.00, 0.44, 0.66), p1 = rgb(0.80, 0.52, 1.00),
    p2 = rgb(0.60, 0.56, 0.92), p3 = rgb(0.55, 0.50, 0.62),
  },

  sand = {
    label = "Sand", dark = false,
    card   = rgb(0.96, 0.93, 0.87, 0.99),
    stroke = rgb(0.42, 0.34, 0.24, 0.28),
    text   = rgb(0.16, 0.13, 0.10),
    dim    = rgb(0.47, 0.42, 0.35),
    accent = rgb(0.40, 0.32, 0.22),
    hover  = rgb(0.40, 0.32, 0.22, 0.11),
    rule   = rgb(0.30, 0.24, 0.16, 0.14),
    p0 = rgb(0.68, 0.24, 0.16), p1 = rgb(0.62, 0.42, 0.14),
    p2 = rgb(0.44, 0.44, 0.26), p3 = rgb(0.50, 0.46, 0.40),
  },

  matrix = {
    label = "Matrix", dark = true,
    card   = rgb(0.008, 0.031, 0.016, 0.98),
    stroke = rgb(0.15, 0.90, 0.35, 0.30),
    text   = rgb(0.80, 1.00, 0.85),
    dim    = rgb(0.38, 0.66, 0.46),
    accent = rgb(0.20, 1.00, 0.42),
    hover  = rgb(0.20, 1.00, 0.42, 0.14),
    rule   = rgb(0.3, 1, 0.5, 0.14),
    p0 = rgb(0.65, 1.00, 0.30), p1 = rgb(0.25, 1.00, 0.45),
    p2 = rgb(0.20, 0.80, 0.55), p3 = rgb(0.30, 0.56, 0.38),
  },
}

Themes.id = "cost"

function Themes.palette()
  return palettes[Themes.id] or palettes.cost
end

function Themes.get(id)
  return palettes[id]
end

function Themes.set(id)
  if palettes[id] then Themes.id = id end
  return Themes.id
end

function Themes.label(id)
  local palette = palettes[id or Themes.id]
  return palette and palette.label or "Cost"
end

--- Colour for a rank label. Unknown ranks fall back to the "everything else"
--- tone rather than erroring, since the ranks come from an LLM.
function Themes.rank(rankLabel)
  local palette = Themes.palette()
  return palette[string.lower(tostring(rankLabel or ""))] or palette.dim
end

-- ------------------------------------------------------------------ geometry

-- Sprite. Width is user-adjustable; height follows the PNG's aspect ratio.
Themes.petWidth  = 96
Themes.petWidths = { 72, 96, 128, 160 }

-- Board
Themes.boardW    = 380
Themes.boardPad  = 16
Themes.boardGap  = 14    -- pet ↔ board
Themes.rowGap    = 10
Themes.radius    = 14

-- Menu
Themes.menuWidth = 272
Themes.menuRow   = 30
Themes.menuPad   = 8

-- Type. Monospace, so ranks and times line up in a column.
Themes.fontName  = "Menlo"
Themes.rankSize  = 12
Themes.titleSize = 13
Themes.bodySize  = 11
Themes.smallSize = 10.5

return Themes
