--- The things you actually said matter, kept in three independent lists.
---
--- Daily, weekly and monthly are separate lists rather than one list filtered by
--- tag: a monthly goal and today's errands are different kinds of thing, and
--- mixing them makes both harder to read.
---
--- Items live until they are done or deleted. No expiry and no carry-over
--- bookkeeping — an unfinished item is simply still there, which is the honest
--- representation and needs no rules.
---
--- Ranks come from Claude, but a pinned rank always wins and survives re-ranking.

local Priorities = {}

local FILE = os.getenv("HOME") .. "/.cost/priorities.json"

Priorities.scopes = { "daily", "weekly", "monthly" }
Priorities.label = { daily = "Daily", weekly = "Weekly", monthly = "Monthly" }

local RANKS = { "P0", "P1", "P2", "P3" }
Priorities.ranks = RANKS

local function empty()
  return { daily = {}, weekly = {}, monthly = {} }
end

-- ------------------------------------------------------------------ storage

function Priorities.load()
  local file = io.open(FILE, "r")
  if not file then return empty() end

  local raw = file:read("*a")
  file:close()

  local ok, data = pcall(hs.json.decode, raw)
  if not ok or type(data) ~= "table" then return empty() end

  -- Tolerate a partial or hand-edited file rather than discarding the lot.
  local out = empty()
  for _, scope in ipairs(Priorities.scopes) do
    if type(data[scope]) == "table" then out[scope] = data[scope] end
  end
  return out
end

function Priorities.save(lists)
  hs.fs.mkdir(os.getenv("HOME") .. "/.cost")

  local file = io.open(FILE, "w")
  if not file then return false end

  file:write(hs.json.encode(lists))
  file:close()
  return true
end

Priorities.file = FILE

-- -------------------------------------------------------------------- items

--- Ids only have to be unique within this file, and time alone collides when two
--- items are added in the same second.
local counter = 0
local function newId()
  counter = counter + 1
  return string.format("%d-%d", os.time(), counter)
end

function Priorities.add(lists, scope, text)
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil end

  local list = lists[scope]
  if not list then return nil end

  local item = {
    id = newId(),
    text = text,
    done = false,
    created = os.time(),
  }
  list[#list + 1] = item
  return item
end

function Priorities.find(lists, id)
  for _, scope in ipairs(Priorities.scopes) do
    for index, item in ipairs(lists[scope] or {}) do
      if item.id == id then return item, scope, index end
    end
  end
  return nil
end

function Priorities.remove(lists, id)
  local _, scope, index = Priorities.find(lists, id)
  if not scope then return false end
  table.remove(lists[scope], index)
  return true
end

function Priorities.toggleDone(lists, id)
  local item = Priorities.find(lists, id)
  if not item then return false end
  item.done = not item.done
  item.completedAt = item.done and os.time() or nil
  return true
end

--- Pinning is a manual override of Claude's ordering. Pinning the rank an item
--- already holds clears it, so the same gesture toggles.
function Priorities.pin(lists, id, rank)
  local item = Priorities.find(lists, id)
  if not item then return false end

  if item.pinned == rank then
    item.pinned = nil
  else
    item.pinned = rank
  end
  return true
end

function Priorities.clearDone(lists, scope)
  local list = lists[scope]
  if not list then return 0 end

  local kept, removed = {}, 0
  for _, item in ipairs(list) do
    if item.done then removed = removed + 1 else kept[#kept + 1] = item end
  end
  lists[scope] = kept
  return removed
end

-- ------------------------------------------------------------------ ranking

--- Apply a ranking, as `{ [id] = "P0", ... }`. Pins are honoured first and take
--- their slot regardless of what the ranking said; whatever is left fills the
--- remaining slots in the order given.
function Priorities.applyRanking(lists, scope, ranking)
  local list = lists[scope] or {}

  for _, item in ipairs(list) do
    item.rank = nil
  end

  local taken = {}

  for _, item in ipairs(list) do
    if item.pinned and not item.done and not taken[item.pinned] then
      item.rank = item.pinned
      taken[item.pinned] = true
    end
  end

  -- Preserve the order the ranking supplied for everything unpinned.
  local ordered = {}
  for _, item in ipairs(list) do
    if not item.done and not item.rank and ranking[item.id] then
      ordered[#ordered + 1] = { item = item, rank = ranking[item.id] }
    end
  end
  table.sort(ordered, function(a, b) return a.rank < b.rank end)

  for _, entry in ipairs(ordered) do
    for _, rank in ipairs(RANKS) do
      if not taken[rank] then
        entry.item.rank = rank
        taken[rank] = true
        break
      end
    end
  end

  lists.rankedAt = lists.rankedAt or {}
  lists.rankedAt[scope] = os.time()
end

--- Split a scope into what the board draws: ranked, then the rest, then done.
function Priorities.view(lists, scope)
  local list = lists[scope] or {}
  local ranked, rest, done = {}, {}, {}

  for _, item in ipairs(list) do
    if item.done then
      done[#done + 1] = item
    elseif item.rank then
      ranked[#ranked + 1] = item
    else
      rest[#rest + 1] = item
    end
  end

  local order = {}
  for index, rank in ipairs(RANKS) do order[rank] = index end
  table.sort(ranked, function(a, b) return (order[a.rank] or 9) < (order[b.rank] or 9) end)

  return ranked, rest, done
end

function Priorities.count(lists, scope)
  local open = 0
  for _, item in ipairs(lists[scope] or {}) do
    if not item.done then open = open + 1 end
  end
  return open
end

return Priorities
