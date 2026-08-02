--- Today's events, via the CostCalendar helper app.
---
--- The helper is launched with `open` rather than executed directly, and that is
--- load-bearing: macOS attributes a permission request to the *responsible*
--- process, which for a direct child of Hammerspoon would be Hammerspoon — and
--- Hammerspoon ships no calendar usage string, so the request would be killed
--- rather than prompted. Going through `open` hands the launch to launchd, which
--- makes the helper responsible for itself.
---
--- `open` gives us no stdout in return, which is why the helper writes to a file
--- and we read it back.

local Calendar = {}

local APP = hs.configdir .. "/cost/CostCalendar.app"
local OUT = os.getenv("HOME") .. "/.cost/calendar.json"
local TIMEOUT = 25   -- seconds; the first run includes the permission prompt

local running     -- the in-flight hs.task, so two refreshes can't race

local function readOutput()
  local file = io.open(OUT, "r")
  if not file then return nil, "the helper wrote nothing" end

  local raw = file:read("*a")
  file:close()

  local ok, decoded = pcall(hs.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return nil, "the helper's output could not be read"
  end
  return decoded
end

function Calendar.available()
  return hs.fs.attributes(APP, "mode") == "directory"
end

--- @param callback function(events, err)  events is a list; err is a string
function Calendar.fetch(callback)
  if not Calendar.available() then
    callback(nil, "CostCalendar.app is not installed — run install.sh")
    return
  end

  if running then
    callback(nil, "already checking the calendar")
    return
  end

  hs.fs.mkdir(os.getenv("HOME") .. "/.cost")
  os.remove(OUT)   -- so a stale file can never be mistaken for a fresh answer

  local finished = false
  local timeout

  local function finish(events, err)
    if finished then return end
    finished = true
    running = nil
    if timeout then timeout:stop() end
    callback(events, err)
  end

  running = hs.task.new("/usr/bin/open", function(exitCode)
    local data, err = readOutput()

    if not data then
      finish(nil, err or ("the helper exited with " .. tostring(exitCode)))
      return
    end

    -- The helper always writes a readable file, including on refusal, so its
    -- own error message is better than anything inferred from an exit code.
    if data.error then
      finish(nil, data.message or data.error)
      return
    end

    finish(data.events or {})
  end, { "-W", "-n", "-a", APP, "--args", "--out", OUT })

  if not running then
    finish(nil, "could not launch the calendar helper")
    return
  end

  timeout = hs.timer.doAfter(TIMEOUT, function()
    if running then running:terminate() end
    finish(nil, "the calendar helper timed out")
  end)

  running:start()
end

return Calendar
