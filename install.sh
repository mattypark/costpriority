#!/bin/bash
# cost installer.
#
#   ./install.sh              build the calendar helper and install everything
#   ./install.sh --no-helper  skip the Swift build (no calendar, sample data only)
#
# Copies the pet into ~/.hammerspoon, builds CostCalendar.app, and asks macOS for
# calendar access once — from this terminal, so the prompt names CostCalendar
# rather than Hammerspoon.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HS_DIR="$HOME/.hammerspoon"
BUILD_HELPER=1

for arg in "$@"; do
  case "$arg" in
    --no-helper) BUILD_HELPER=0 ;;
    *) echo "unknown option: $arg"; exit 1 ;;
  esac
done

echo "==> Checking Hammerspoon"
if [ ! -d "/Applications/Hammerspoon.app" ]; then
  echo "    not found — installing via Homebrew"
  brew install --cask hammerspoon
else
  echo "    already installed"
fi

echo "==> Installing the pet into $HS_DIR"
mkdir -p "$HS_DIR/cost/assets" "$HS_DIR/cost/sources"
cp "$REPO"/hammerspoon/cost/*.lua          "$HS_DIR/cost/"
cp "$REPO"/hammerspoon/cost/sources/*.lua  "$HS_DIR/cost/sources/"
cp "$REPO"/hammerspoon/cost/pet.json       "$HS_DIR/cost/"
cp "$REPO"/hammerspoon/cost/prompt.md      "$HS_DIR/cost/"
cp "$REPO"/hammerspoon/cost/assets/README.txt "$HS_DIR/cost/assets/"

# Never clobber a sprite you chose yourself.
if [ ! -f "$HS_DIR/cost/assets/pet.png" ]; then
  cp "$REPO/hammerspoon/cost/assets/pet.png" "$HS_DIR/cost/assets/"
else
  echo "    keeping your existing assets/pet.png"
fi

if [ "$BUILD_HELPER" = "1" ]; then
  echo "==> Building the calendar helper"
  if ! command -v swiftc >/dev/null 2>&1; then
    echo "    swiftc not found — install the Xcode command line tools:"
    echo "        xcode-select --install"
    echo "    then re-run this script. Continuing without the helper for now."
  else
    "$REPO/helper/CostCalendar/build.sh" "$REPO/helper/CostCalendar" >/dev/null
    rm -rf "$HS_DIR/cost/CostCalendar.app"
    cp -R "$REPO/helper/CostCalendar/CostCalendar.app" "$HS_DIR/cost/"
    echo "    installed CostCalendar.app"

    # Ask for calendar access from here, not from Hammerspoon. macOS attributes
    # the request to the responsible process; launching via `open` makes the
    # helper responsible for itself, so the prompt names CostCalendar.
    echo "==> Asking macOS for calendar access"
    echo "    (approve the prompt for \"CostCalendar\" if one appears)"
    open -W -n -a "$HS_DIR/cost/CostCalendar.app" --args --out /tmp/costcal-install.json || true

    if [ -f /tmp/costcal-install.json ] \
       && ! grep -q '"error"' /tmp/costcal-install.json; then
      COUNT=$(sed -n 's/.*"count" *: *\([0-9]*\).*/\1/p' /tmp/costcal-install.json | head -1)
      echo "    calendar access granted — ${COUNT:-0} events on today's calendar"
    else
      echo "    couldn't read the calendar yet. The pet still works on sample"
      echo "    data; grant access in System Settings > Privacy & Security >"
      echo "    Calendars, or check that an account is added under Internet"
      echo "    Accounts with Calendars ticked."
    fi
    rm -f /tmp/costcal-install.json
  fi
fi

echo "==> Wiring init.lua"
if [ ! -f "$HS_DIR/init.lua" ]; then
  cat > "$HS_DIR/init.lua" <<'LUA'
-- Hammerspoon config.

cost = require("cost")

-- Reload when any .lua in here changes. Filtered to .lua on purpose: a sprite
-- dropped into cost/assets/ lives under this same directory, and reloading on
-- that would loop.
configWatcher = hs.pathwatcher.new(hs.configdir, function(paths)
  for _, path in ipairs(paths) do
    if path:sub(-4) == ".lua" then
      hs.reload()
      return
    end
  end
end):start()

hs.urlevent.bind("reload", function() hs.reload() end)
LUA
  echo "    wrote a new init.lua"

elif grep -q '"cost"' "$HS_DIR/init.lua"; then
  echo "    already wired"

else
  cp "$HS_DIR/init.lua" "$HS_DIR/init.lua.bak.$(date +%s)"
  {
    echo ""
    echo "-- cost"
    # Prefer the pet bus if organizepet is installed, so a failure here can't
    # take down the rest of the config.
    if grep -q 'require("petbus")' "$HS_DIR/init.lua"; then
      echo 'cost = pets.load("cost")'
    else
      echo 'cost = require("cost")'
    fi
  } >> "$HS_DIR/init.lua"
  echo "    appended to your existing init.lua (backup alongside it)"
fi

echo "==> Launching Hammerspoon"
open -a Hammerspoon

cat <<'DONE'

Installed.

  • Reload Hammerspoon once (hammer icon in the menu bar -> Reload Config).
  • The pet appears on the right edge — drag him anywhere.
  • Click him for today's board: P0, P1, P2, P3, then everything else.
  • ⌃⌥⌘I hides or shows him. Click for the menu: themes, size, sprite.
  • Swap in your own drawing: click him -> "Choose sprite…".

Only one macOS permission is used: Calendars, for CostCalendar.app.
Nothing here talks to the network — your day never leaves this Mac.
DONE
