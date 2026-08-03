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

--- Run a write mode. The spec goes to a file because `open` gives the launched
--- app no stdin — the same constraint that already forces output to a file.
---
--- @param mode string  "add" | "move" | "delete"
--- @param spec table
--- @param callback function(event, err)
function Calendar.write(mode, spec, callback)
  if not Calendar.available() then
    callback(nil, "CostCalendar.app is not installed")
    return
  end

  local dir = os.getenv("HOME") .. "/.cost"
  hs.fs.mkdir(dir)

  local specPath = dir .. "/spec.json"
  local outPath = dir .. "/write.json"

  local file = io.open(specPath, "w")
  if not file then
    callback(nil, "couldn't write the request")
    return
  end
  file:write(hs.json.encode(spec))
  file:close()

  os.remove(outPath)

  local finished = false
  local task, timeout

  local function finish(event, err)
    if finished then return end
    finished = true
    if timeout then timeout:stop() end
    os.remove(specPath)
    callback(event, err)
  end

  task = hs.task.new("/usr/bin/open", function(exitCode)
    local handle = io.open(outPath, "r")
    if not handle then
      finish(nil, "the helper wrote nothing (exit " .. tostring(exitCode) .. ")")
      return
    end

    local raw = handle:read("*a")
    handle:close()

    local ok, data = pcall(hs.json.decode, raw)
    if not ok or type(data) ~= "table" then
      finish(nil, "couldn't read the helper's reply")
      return
    end

    if data.error then
      finish(nil, data.message or data.error)
      return
    end

    finish(data.event or {})
  end, { "-W", "-n", "-a", APP, "--args",
         "--" .. mode, "--spec", specPath, "--out", outPath })

  if not task then
    finish(nil, "couldn't launch the calendar helper")
    return
  end

  timeout = hs.timer.doAfter(TIMEOUT, function()
    if task then task:terminate() end
    finish(nil, "the calendar helper timed out")
  end)

  task:start()
end

--- @param callback function(events, err, meta)
---   events is a list, err a string, meta the helper's full reply — which also
---   carries the writable calendar names and the default one, needed so the
---   natural-language parser never invents a calendar that doesn't exist.
--- @param days number|nil  how many days from today; 1 (today) by default
function Calendar.fetch(callback, days)
  if not Calendar.available() then
    callback(nil, "CostCalendar.app is not installed — run install.sh")
    return
  end

  -- Cancel-and-replace rather than reject. Switching scope fires a fetch for a
  -- different window, and refusing it left the board labelled "next 7 days"
  -- while still showing only today — the label and the data disagreeing is
  -- worse than a slightly slower switch.
  if running then
    running:terminate()
    running = nil
  end

  hs.fs.mkdir(os.getenv("HOME") .. "/.cost")
  os.remove(OUT)   -- so a stale file can never be mistaken for a fresh answer

  local finished = false
  local timeout

  local function finish(events, err, meta)
    if finished then return end
    finished = true
    running = nil
    if timeout then timeout:stop() end
    callback(events, err, meta)
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

    finish(data.events or {}, nil, data)
  end, { "-W", "-n", "-a", APP, "--args", "--out", OUT,
         "--days", tostring(math.max(1, math.floor(days or 1))) })

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
