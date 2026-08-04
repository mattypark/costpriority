--- Ranking by `claude -p`, running headless on the user's own subscription.
---
--- Two things matter here more than the prompt.
---
--- **Cost.** A bare `claude -p` loads the user's CLAUDE.md, skills and plugins
--- into context — measured at ~83k tokens and $0.69 per call on this machine.
--- Passing `--setting-sources ""`, `--tools ""`, `--strict-mcp-config` and an
--- explicit `--system-prompt` strips all of it: the same question costs $0.005,
--- about 130x less. None of that context is any use for ranking a calendar.
---
--- **Never trusting the output.** The model is asked for strict JSON and mostly
--- obliges, but "mostly" is not a contract. Everything below assumes the reply
--- may be fenced, prefixed with prose, truncated, or shaped wrong, and falls
--- back to the deterministic ranker rather than showing a broken board.

local Brain = {}

local CLAUDE = os.getenv("HOME") .. "/.local/bin/claude"
local PROMPT_FILE = hs.configdir .. "/cost/prompt.md"
local PRIORITIES_PROMPT = hs.configdir .. "/cost/prompt-priorities.md"
local INTENT_PROMPT = hs.configdir .. "/cost/prompt-intent.md"
local NUDGE_PROMPT = hs.configdir .. "/cost/prompt-nudge.md"
-- Generous, because it covers the CLI's cold start as well as the request.
local TIMEOUT = 90
local MAX_EVENTS = 40      -- a pathological calendar shouldn't blow up the prompt

local DEFAULT_MODEL = "claude-haiku-4-5-20251001"
local SYSTEM = "You rank calendar events by importance. You reply with one JSON object and nothing else."

local RANKS = { "P0", "P1", "P2", "P3" }
local RANK_ORDER = { P0 = 1, P1 = 2, P2 = 3, P3 = 4 }

local running

-- ------------------------------------------------------------------ locating

--- `claude` may be anywhere; hs.task needs an absolute path, and Hammerspoon's
--- PATH is not the shell's.
local CANDIDATES = {
  CLAUDE,
  "/opt/homebrew/bin/claude",
  "/usr/local/bin/claude",
  os.getenv("HOME") .. "/.claude/local/claude",
}

function Brain.executable()
  for _, path in ipairs(CANDIDATES) do
    if hs.fs.attributes(path, "mode") == "file" then return path end
  end
  return nil
end

function Brain.available()
  return Brain.executable() ~= nil
end

-- -------------------------------------------------------------------- prompt

--- Everything after the first `---` on its own line. Lets the file carry notes
--- about itself without those notes reaching the model.
local function loadPrompt(path)
  local file = io.open(path or PROMPT_FILE, "r")
  if not file then return nil end

  local raw = file:read("*a")
  file:close()

  local body = raw:match("\n%-%-%-\n(.*)$")
  return body or raw
end

--- What the model actually sees. `now` is explicit so it can reason about what
--- has already finished without guessing at the current time.
local function payload(events)
  local trimmed = {}
  for index, event in ipairs(events) do
    if index > MAX_EVENTS then break end
    trimmed[#trimmed + 1] = {
      uid = event.uid,
      title = event.title,
      start = event.start,
      endTime = event.endTime,
      allDay = event.allDay and true or false,
      attendees = event.attendees or 0,
      calendar = event.calendar,
      location = event.location,
    }
  end

  return hs.json.encode({
    now = os.time(),
    now_local = os.date("%Y-%m-%d %H:%M"),
    weekday = os.date("%A"),
    events = trimmed,
  })
end

-- --------------------------------------------------------------------- parse

--- The outermost balanced {...}, so leading prose or a trailing sign-off can't
--- break the decode. Brace counting rather than a pattern, because Lua patterns
--- cannot match nested structures.
local function outermostObject(text)
  local start = text:find("{")
  if not start then return nil end

  local depth, inString, escaped = 0, false, false

  for i = start, #text do
    local char = text:sub(i, i)

    if inString then
      if escaped then escaped = false
      elseif char == "\\" then escaped = true
      elseif char == '"' then inString = false
      end
    elseif char == '"' then inString = true
    elseif char == "{" then depth = depth + 1
    elseif char == "}" then
      depth = depth - 1
      if depth == 0 then return text:sub(start, i) end
    end
  end

  return nil
end

--- Unwrap `--output-format json`, then dig the object out of the model's text.
--- Falls through to treating stdout as raw JSON, since CLI output shapes move
--- between versions and this should not break on an upgrade.
local function extract(stdout)
  local ok, wrapper = pcall(hs.json.decode, stdout)

  local text = stdout
  if ok and type(wrapper) == "table" then
    if wrapper.is_error then
      return nil, tostring(wrapper.result or "claude reported an error")
    end
    text = wrapper.result or stdout
  end

  if type(text) ~= "string" then return nil, "unexpected reply shape" end

  local body = outermostObject(text)
  if not body then return nil, "no JSON object in the reply" end

  local decoded, result = pcall(hs.json.decode, body)
  if not decoded or type(result) ~= "table" then
    return nil, "the reply was not valid JSON"
  end

  return result
end

-- ------------------------------------------------------------------ validate

local function clean(value, limit)
  if type(value) ~= "string" then return nil end
  local text = value:gsub("%c", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil end
  if #text > limit then text = text:sub(1, limit - 1) .. "…" end
  return text
end

--- Over-long fields are truncated rather than rejected: an over-eager model
--- shouldn't cost the whole run. Only structural problems fall back.
function Brain.validate(raw)
  if type(raw) ~= "table" then return nil, "not an object" end
  if type(raw.priorities) ~= "table" then return nil, "no priorities array" end

  local seen, priorities = {}, {}

  for _, item in ipairs(raw.priorities) do
    if type(item) == "table" then
      local rank = type(item.rank) == "string" and item.rank:upper() or nil
      local title = clean(item.title, 60)

      -- A duplicate or unknown rank means the model misread the contract; drop
      -- that row rather than rendering two P0s.
      if rank and RANK_ORDER[rank] and not seen[rank] and title then
        seen[rank] = true
        priorities[#priorities + 1] = {
          rank = rank,
          title = title,
          why = clean(item.why, 100),
          when = clean(item.when, 12),
          ref = type(item.ref) == "string" and item.ref or nil,
          source = "calendar",
        }
      end
    end
  end

  -- An empty list is a legitimate answer, not a failure: on a day where
  -- everything has already happened there is nothing left to rank, and the
  -- prompt explicitly asks for empty arrays rather than padding. Only treat it
  -- as malformed when the model offered priorities and every one was unusable.
  if #priorities == 0 and #raw.priorities > 0 then
    return nil, "priorities were all malformed"
  end

  table.sort(priorities, function(a, b) return RANK_ORDER[a.rank] < RANK_ORDER[b.rank] end)

  -- Ranks must be contiguous from P0 — a board reading P0, P2, P3 looks like a
  -- bug even when the ordering is right.
  for index, item in ipairs(priorities) do
    item.rank = RANKS[index]
  end

  local rest = {}
  if type(raw.rest) == "table" then
    for _, item in ipairs(raw.rest) do
      if #rest >= 8 then break end
      if type(item) == "table" then
        local title = clean(item.title, 70)
        if title then
          rest[#rest + 1] = { title = title, why = clean(item.why, 40), source = "calendar" }
        end
      end
    end
  end

  return { priorities = priorities, rest = rest }
end

--- Validate a priority-list ranking into { [id] = "P0", ... }.
---
--- Unknown ids are dropped rather than trusted: the model occasionally invents
--- one, and applying a rank to an item that doesn't exist would silently lose
--- the ranking for the item that does.
function Brain.validateRanking(raw)
  if type(raw) ~= "table" then return nil, "not an object" end

  local list = raw.ranking
  if type(list) ~= "table" then return nil, "no ranking array" end

  local ranking, why, seen = {}, {}, {}

  for _, entry in ipairs(list) do
    if type(entry) == "table" and type(entry.id) == "string" then
      local rank = type(entry.rank) == "string" and entry.rank:upper() or nil
      if rank and RANK_ORDER[rank] and not seen[rank] and not ranking[entry.id] then
        seen[rank] = true
        ranking[entry.id] = rank
        why[entry.id] = clean(entry.why, 80)
      end
    end
  end

  return { ranking = ranking, why = why }
end

-- ----------------------------------------------------------------------- run

--- The shared path: run claude with a prompt and a JSON payload, hand the raw
--- decoded object to `shape` for validation.
---
--- @param prompt string          the user prompt
--- @param input string           JSON for stdin
--- @param opts table             { model = "..." }
--- @param shape function(raw)    returns (value, err)
--- @param callback function(value, err)
local function run(prompt, input, opts, shape, callback)
  local executable = Brain.executable()
  if not executable then
    callback(nil, "claude CLI not found")
    return
  end

  if running then
    callback(nil, "already thinking")
    return
  end

  local finished = false
  local timeout

  local function finish(ranked, err)
    if finished then return end
    finished = true
    running = nil
    if timeout then timeout:stop() end
    callback(ranked, err)
  end

  local model = (opts.model and opts.model ~= "" and opts.model) or DEFAULT_MODEL

  running = hs.task.new(executable, function(exitCode, stdout, stderr)
    if exitCode ~= 0 then
      local detail = clean(stderr, 120) or ("exit " .. tostring(exitCode))
      finish(nil, detail)
      return
    end

    local raw, err = extract(stdout or "")
    if not raw then
      finish(nil, err)
      return
    end

    local value, invalid = shape(raw)
    if not value then
      finish(nil, invalid)
      return
    end

    finish(value)
  end, {
    "-p",
    "--output-format", "json",
    "--model", model,
    -- Strips CLAUDE.md, skills, plugins, tools and MCP from the context. This
    -- is the difference between $0.005 and $0.69 a call.
    "--setting-sources", "",
    "--tools", "",
    "--strict-mcp-config",
    "--system-prompt", SYSTEM,
    prompt,
  })

  if not running then
    finish(nil, "could not start claude")
    return
  end

  timeout = hs.timer.doAfter(TIMEOUT, function()
    if running then running:terminate() end
    finish(nil, "claude timed out after " .. TIMEOUT .. "s")
  end)

  running:start()

  -- The payload goes on stdin, never in argv: argv has a length limit and
  -- quoting a JSON blob through it is a needless hazard.
  --
  -- closeInput() is not optional. `claude -p` reads stdin until EOF, so leaving
  -- the pipe open makes it wait for input that will never arrive — it hangs
  -- until the timeout above fires, every single time, and the board silently
  -- falls back to the offline ranker.
  running:setInput(input)
  running:closeInput()
end

-- ------------------------------------------------------------- public calls

--- Rank today's calendar events.
function Brain.rank(events, opts, callback)
  opts = opts or {}

  local prompt = loadPrompt(PROMPT_FILE)
  if not prompt then return callback(nil, "prompt.md is missing") end
  if not events or #events == 0 then return callback(nil, "nothing to rank") end

  run(prompt, payload(events), opts, Brain.validate, callback)
end

--- Turn one line of English into a structured action.
---
--- The raw object comes back unvalidated on purpose: intent.lua owns that, and
--- it needs the event list to check uids against, which Brain has no business
--- knowing about.
function Brain.parseIntent(text, events, calendars, defaultCalendar, opts, callback)
  opts = opts or {}

  local prompt = loadPrompt(INTENT_PROMPT)
  if not prompt then return callback(nil, "prompt-intent.md is missing") end

  local Intent = require("cost.intent")
  local input = Intent.payload(text, events, calendars, defaultCalendar)

  run(prompt, input, opts, function(raw) return raw end, callback)
end

--- One short line to show just before an event starts.
---
--- Deliberately small and cheap: it runs unattended, several times a day, so it
--- gets the least context that can still produce a useful sentence.
function Brain.nudge(event, events, items, opts, callback)
  opts = opts or {}

  local prompt = loadPrompt(NUDGE_PROMPT)
  if not prompt then return callback(nil, "prompt-nudge.md is missing") end
  if not event then return callback(nil, "no event") end

  local rest = {}
  for _, other in ipairs(events or {}) do
    if other.uid ~= event.uid and other.start and other.start >= os.time()
       and #rest < 6 then
      rest[#rest + 1] = { title = other.title, start = other.start }
    end
  end

  local priorities = {}
  for _, item in ipairs(items or {}) do
    if not item.done and #priorities < 8 then
      priorities[#priorities + 1] = item.text
    end
  end

  local input = hs.json.encode({
    now = os.time(),
    now_local = os.date("%Y-%m-%d %H:%M"),
    event = {
      title = event.title,
      start = event.start,
      endTime = event.endTime,
      attendees = event.attendees or 0,
      calendar = event.calendar,
      location = event.location,
      notes = event.notes,
    },
    later_today = rest,
    priorities = priorities,
  })

  run(prompt, input, opts, function(raw)
    if type(raw) ~= "table" then return nil, "not an object" end
    local line = clean(raw.line, 90)
    if not line then return nil, "no line" end
    return { line = line }
  end, callback)
end

--- Rank the user's own list, with the calendar as context.
--- @return table  { [itemId] = "P0", ... }
function Brain.rankPriorities(items, events, scope, opts, callback)
  opts = opts or {}

  local prompt = loadPrompt(PRIORITIES_PROMPT)
  if not prompt then return callback(nil, "prompt-priorities.md is missing") end

  local open = {}
  for _, item in ipairs(items or {}) do
    if not item.done then
      open[#open + 1] = {
        id = item.id,
        text = item.text,
        pinned = item.pinned,
        added = item.created and os.date("%Y-%m-%d", item.created) or nil,
      }
    end
  end

  if #open == 0 then return callback(nil, "nothing to rank") end

  local context = {}
  for index, event in ipairs(events or {}) do
    if index > 25 then break end
    context[#context + 1] = {
      title = event.title,
      start = event.start,
      endTime = event.endTime,
      allDay = event.allDay and true or false,
    }
  end

  local input = hs.json.encode({
    now = os.time(),
    now_local = os.date("%Y-%m-%d %H:%M"),
    weekday = os.date("%A"),
    scope = scope,
    items = open,
    calendar = context,
  })

  run(prompt, input, opts, Brain.validateRanking, callback)
end

return Brain
