# cost

A desktop pet that tells you what actually matters today.

Click him and a board appears: your top four priorities ranked **P0** to **P3**,
then everything else that's on the day. The events come from your Mac's own
Calendar — including any Google or iCloud account you've added to it — and never
leave the machine.

<!-- screenshot -->

- **P0–P3 plus the rest**, so it's a decision rather than a list
- **Reads your real calendar** through EventKit. No API keys, no OAuth, no server
- **Eight themes** — Claude, Midnight, Black & white, Orange & black, Nature,
  Plum, Sand, Matrix
- **Your own sprite** — drop in any PNG, or pick one from the pet's menu
- **Drag him anywhere**; he remembers where you put him
- **Works with [organizepet](https://github.com/mattypark/organizepet)**, so he
  can be hidden along with every other pet at once

## Install

```bash
git clone https://github.com/mattypark/costpriority.git
cd costpriority
./install.sh
```

The installer builds a small helper app, asks macOS for calendar access once,
and wires the pet into Hammerspoon. Reload Hammerspoon afterwards and he appears
on the right-hand edge of your screen.

**First, make sure your calendar is actually on your Mac**: System Settings →
General → Internet Accounts → Add Account → Google, and tick **Calendars**. Open
Calendar.app and confirm your events are there. Nothing here can see a calendar
your Mac can't.

## How it reads your calendar

Not directly — through `CostCalendar.app`, a ~150-line Swift helper that prints
today's events as JSON. That indirection is not incidental:

1. On macOS 14+, EventKit requires `NSCalendarsFullAccessUsageDescription` in the
   Info.plist of the process asking. Without it macOS **terminates** the process
   rather than showing a prompt.
2. Hammerspoon ships no such key, so the request can never come from inside
   Hammerspoon — and a bare `swiftc` binary has no Info.plist at all. Hence a
   real `.app` bundle with a real identifier.
3. macOS attributes a permission request to the *responsible* process, which for
   a direct child of Hammerspoon would still be Hammerspoon. Launching through
   `/usr/bin/open` hands the launch to launchd, so the helper becomes responsible
   for itself and the prompt correctly names **CostCalendar**.

`open` gives the caller no stdout, which is why the helper writes to a file named
by `--out` and the pet reads it back.

Reading `Calendar.sqlitedb` directly would need Full Disk Access for Hammerspoon
*and* a reimplementation of recurrence-rule expansion. It isn't used.

### The helper on its own

```bash
open -W -n -a ~/.hammerspoon/cost/CostCalendar.app --args --out /tmp/costcal.json
cat /tmp/costcal.json
```

Takes an optional `--day 2026-08-02`. Always writes a readable file, including on
refusal, so the pet can explain what went wrong instead of showing an empty board.

## Ranking

Two paths, and the board always says which one produced what you're looking at.

**Deterministic** (default, instant, works offline). Anything that already
finished is partitioned out before ranking — putting this morning's shower above
this afternoon's deadline is the fastest way for a briefing to look broken — and
what's left is scored on how soon it starts, how many people are in it, and
whether the title reads consequential (`interview`, `deadline`, `exam`, `flight`)
or skippable (`optional`, `tentative`, `hold`). Ties break on start time then
title, so the same day always ranks the same way.

**`claude -p`** *(coming)* — the same events handed to Claude Code running
headless on your existing subscription, for ranking that understands what the
events mean. Falls back to the deterministic ranker whenever it's missing, slow,
or returns something that isn't the agreed shape.

## Your own sprite

Click the pet → **Choose sprite…**, pick any PNG, done. Or drop one at
`~/.hammerspoon/cost/assets/pet.png`.

Transparent backgrounds work best. Width comes from **Pet size** in the menu;
height follows your image's own proportions. A file named `pet-<theme>.png` is
used whenever that theme is active — `pet-matrix.png`, and so on.

## Permissions

Calendars, once, for `CostCalendar.app`. That's all.

No Accessibility: dragging polls the mouse rather than using an event tap, and
the menu dismisses via a near-invisible canvas shield. No Full Disk Access. No
network access of any kind — nothing about your day is ever transmitted.

The helper's ad-hoc code signature means the permission grant is tied to that
exact build, so rebuilding it prompts again. Build once, at install.

## Licence

MIT
