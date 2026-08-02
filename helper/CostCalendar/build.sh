#!/bin/bash
# Builds CostCalendar.app — a tiny agent app whose only job is dumping today's
# calendar as JSON.
#
#   ./build.sh [output-dir]      # default: this directory
#
# It has to be a real bundle, not a bare binary: EventKit refuses to run in a
# process whose Info.plist has no NSCalendarsFullAccessUsageDescription, and a
# swiftc binary has no Info.plist at all.
#
# The ad-hoc signature keys macOS's permission grant to this exact build. Rebuild
# and you will be asked for calendar access again — so build once, at install,
# and never from a refresh path.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-$HERE}"
APP="$OUT_DIR/CostCalendar.app"
CONTENTS="$APP/Contents"

echo "==> Building $APP"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>CostCalendar</string>
  <key>CFBundleDisplayName</key>       <string>CostCalendar</string>
  <key>CFBundleIdentifier</key>        <string>com.matthewpark.cost.calendar</string>
  <key>CFBundleExecutable</key>        <string>CostCalendar</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>

  <!-- No Dock icon, no menu bar: it runs for a fraction of a second and quits. -->
  <key>LSUIElement</key>               <true/>

  <!-- The sentence macOS shows in the permission prompt. Without this key TCC
       terminates the process instead of prompting. -->
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Cost reads today's events so your pet can tell you what matters most today. Nothing leaves your Mac.</string>
</dict>
</plist>
PLIST

echo "    compiling"
swiftc -O \
  -target arm64-apple-macos14.0 \
  -o "$CONTENTS/MacOS/CostCalendar" \
  "$HERE/main.swift"

echo "    signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"

echo "    verifying"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

cat <<DONE

Built: $APP

Run it once from Terminal so the permission prompt is attributed to
CostCalendar rather than to Hammerspoon:

  open -W -n -a "$APP" --args --out /tmp/costcal.json
  cat /tmp/costcal.json

DONE
