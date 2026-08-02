--- Today's ranking, on disk.
---
--- Exists so opening the pet in the morning is instant and free: a reload, a
--- reboot, or a second click reads the same answer back rather than paying for
--- another ranking. One file per day, so yesterday's plan can never be shown as
--- today's — the filename is the expiry.

local Cache = {}

local DIR = os.getenv("HOME") .. "/.cost/cache"
local KEEP_DAYS = 7

local function path(day)
  return DIR .. "/" .. (day or os.date("%Y-%m-%d")) .. ".json"
end

function Cache.read(day)
  local file = io.open(path(day), "r")
  if not file then return nil end

  local raw = file:read("*a")
  file:close()

  local ok, data = pcall(hs.json.decode, raw)
  if not ok or type(data) ~= "table" then return nil end
  return data
end

function Cache.write(data, day)
  hs.fs.mkdir(os.getenv("HOME") .. "/.cost")
  hs.fs.mkdir(DIR)

  local file = io.open(path(day), "w")
  if not file then return false end

  file:write(hs.json.encode(data))
  file:close()
  return true
end

--- Drop anything older than a week. A briefing has no value the day after, and
--- an unbounded cache directory is the kind of thing nobody notices for a year.
function Cache.prune()
  local cutoff = os.date("%Y-%m-%d", os.time() - KEEP_DAYS * 86400)

  local ok, iter, dirObject = pcall(hs.fs.dir, DIR)
  if not ok then return end

  for entry in iter, dirObject do
    local day = entry:match("^(%d%d%d%d%-%d%d%-%d%d)%.json$")
    if day and day < cutoff then
      os.remove(DIR .. "/" .. entry)
    end
  end
end

return Cache
