--- The input bar: type at the pet, or dictate at it.
---
--- This is an hs.webview rather than the hs.canvas everything else uses, and the
--- reason is specific: a canvas cannot receive typed text. Capturing keystrokes
--- into one would need hs.eventtap, which needs Accessibility permission, which
--- this project deliberately does without.
---
--- A webview containing a real <input> sidesteps that entirely — and being a
--- real text field, it is also what macOS dictation types into. So the same
--- element gets both typing and voice for free, with no permission at all.
---
--- hs.webview:allowTextEntry(true) is what makes the borderless window able to
--- take key input. Without it the bar appears and silently swallows everything.

local themes = require("cost.themes")

local Input = {}

local W = 460
local H = 92
local GAP = 14        -- pet ↔ bar

local webview, controller, hotkeyEsc
local onSubmit, previousApp

-- ---------------------------------------------------------------------- html

--- Hammerspoon colours are {red,green,blue,alpha} in 0–1; CSS wants 0–255.
local function css(color)
  if not color then return "transparent" end
  return string.format("rgba(%d,%d,%d,%s)",
    math.floor((color.red or 0) * 255 + 0.5),
    math.floor((color.green or 0) * 255 + 0.5),
    math.floor((color.blue or 0) * 255 + 0.5),
    tostring(color.alpha or 1))
end

local function document(placeholder, prefill)
  local p = themes.palette()

  -- The bar is styled from the same palette as the board, so switching theme
  -- changes both. Everything is inline: a webview cannot reach the filesystem
  -- for stylesheets without extra plumbing, and there is nothing to gain.
  return ([[
<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
  * { margin:0; padding:0; box-sizing:border-box; }
  html, body {
    height:100%%; background:transparent;
    font-family:%s, ui-monospace, monospace;
    -webkit-user-select:none; overflow:hidden;
  }
  .bar {
    height:100%%; display:flex; flex-direction:column; justify-content:center;
    gap:6px; padding:16px 18px;
    background:%s; border:1px solid %s; border-radius:14px;
  }
  .hint { font-size:10.5px; color:%s; letter-spacing:.02em; }
  input {
    width:100%%; border:0; outline:0; background:transparent;
    font-family:inherit; font-size:15px; color:%s;
    -webkit-user-select:text;
  }
  input::placeholder { color:%s; }
  .row { display:flex; align-items:center; gap:10px; }
  .caret { color:%s; font-size:15px; }
</style></head>
<body>
  <div class="bar">
    <div class="hint">%s</div>
    <div class="row">
      <span class="caret">&rsaquo;</span>
      <input id="q" autofocus placeholder="%s" value="%s" autocomplete="off"
             autocorrect="off" spellcheck="false">
    </div>
  </div>
<script>
  const box = document.getElementById('q');

  function send(action, text) {
    // The only channel out of the webview. Lua receives {action, text}.
    window.webkit.messageHandlers.cost.postMessage({ action: action, text: text });
  }

  box.addEventListener('keydown', function (e) {
    if (e.key === 'Enter')  { e.preventDefault(); send('submit', box.value); }
    if (e.key === 'Escape') { e.preventDefault(); send('cancel', ''); }
  });

  // Focus has to be taken after the window is actually on screen, and once more
  // on the next frame — a webview that has just appeared will drop the first
  // focus() call, and the bar then silently ignores typing.
  function grab() { box.focus(); box.setSelectionRange(box.value.length, box.value.length); }
  window.addEventListener('load', grab);
  requestAnimationFrame(grab);
  setTimeout(grab, 60);
</script>
</body></html>
]]):format(
    themes.fontName,
    css(p.card), css(p.stroke),
    css(p.dim),
    css(p.text),
    css(p.dim),
    css(p.accent),
    placeholder.hint or "",
    placeholder.text or "",
    (prefill or ""):gsub('"', "&quot;")
  )
end

-- -------------------------------------------------------------------- window

local function positionFor(anchor)
  local screen = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):frame()

  local x, y
  if anchor and anchor.w then
    local onLeft = (anchor.x + anchor.w / 2) > (screen.x + screen.w / 2)
    x = onLeft and (anchor.x - W - GAP) or (anchor.x + anchor.w + GAP)
    y = anchor.y + math.floor(anchor.h / 2) - math.floor(H / 2)
  else
    x = screen.x + math.floor((screen.w - W) / 2)
    y = screen.y + math.floor(screen.h * 0.3)
  end

  x = math.max(screen.x + 8, math.min(x, screen.x + screen.w - W - 8))
  y = math.max(screen.y + 8, math.min(y, screen.y + screen.h - H - 8))
  return { x = x, y = y, w = W, h = H }
end

function Input.isOpen()
  return webview ~= nil
end

function Input.hide()
  if hotkeyEsc then hotkeyEsc:delete(); hotkeyEsc = nil end

  if webview then
    local view = webview
    webview = nil
    view:delete()
  end
  controller = nil
  onSubmit = nil

  -- Give focus back to whatever you were using. Without this the bar leaves you
  -- focused on nothing, and the next keystroke goes nowhere.
  if previousApp then
    previousApp:activate()
    previousApp = nil
  end
end

--- Open the bar.
--- @param opts table {anchor=frame, hint=string, placeholder=string, prefill=string}
--- @param callback function(text)  called with the submitted text, or not at all
function Input.show(opts, callback)
  opts = opts or {}
  Input.hide()

  onSubmit = callback
  previousApp = hs.application.frontmostApplication()

  controller = hs.webview.usercontent.new("cost")
  controller:setCallback(function(message)
    local body = message and message.body
    if type(body) ~= "table" then return end

    if body.action == "submit" then
      local text = tostring(body.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
      local handler = onSubmit
      Input.hide()
      if handler and text ~= "" then handler(text) end

    elseif body.action == "cancel" then
      Input.hide()
    end
  end)

  webview = hs.webview.new(positionFor(opts.anchor), {}, controller)
  webview:windowStyle({ "borderless", "nonactivating" })
  webview:level(hs.canvas.windowLevels.floating + 3)
  webview:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces
                 | hs.canvas.windowBehaviors.stationary)
  webview:transparent(true)
  webview:shadow(true)

  -- Without this the window can never become key, and every keystroke is lost.
  webview:allowTextEntry(true)

  webview:html(document({
    hint = opts.hint or "",
    text = opts.placeholder or "",
  }, opts.prefill))

  webview:show()

  -- Focus the window itself, then let the page's own script focus the field.
  local window = webview:hswindow()
  if window then window:focus() end

  -- Escape is bound here as well as in the page: if focus never reached the
  -- webview, the in-page handler cannot fire and the bar would be unclosable.
  hotkeyEsc = hs.hotkey.bind({}, "escape", function() Input.hide() end)
end

--- Redraw with the current palette. Called when the theme changes while open.
function Input.restyle(opts)
  if not webview then return end
  webview:html(document({
    hint = (opts or {}).hint or "",
    text = (opts or {}).placeholder or "",
  }, ""))
end

return Input
