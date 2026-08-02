# Security

cost reads your calendar and nothing else. It makes no network requests of its
own, and your day is never transmitted anywhere.

## Permissions

**Calendars**, once, granted to `CostCalendar.app`. That is the only macOS
permission involved.

Explicitly not used:

- **Accessibility.** Dragging the sprite polls the mouse with
  `hs.eventtap.checkMouseButtons()` instead of starting an event tap, and menus
  dismiss via a 0.001-alpha full-screen canvas rather than a global click
  monitor. An event tap would grant the ability to observe and inject every
  keystroke on the machine, for a cosmetic gain.
- **Full Disk Access.** Reading `Calendar.sqlitedb` directly would need it, and
  would also mean reimplementing recurrence-rule expansion. EventKit is used
  instead.
- **`hs.allowAppleScript(true)`.** It lets any process on your Mac run arbitrary
  Lua inside Hammerspoon via `osascript` — running code as you. The installer
  never enables it.

## The helper app

`CostCalendar.app` is ~150 lines of Swift that prints today's events as JSON and
exits. It is a separate bundle for reasons that are enforced by macOS, not
stylistic:

1. On macOS 14+, EventKit **terminates** a process that calls
   `requestFullAccessToEvents` without `NSCalendarsFullAccessUsageDescription`
   in its Info.plist. Hammerspoon ships no such key.
2. macOS attributes a permission request to the *responsible* process. A direct
   child of Hammerspoon is still attributed to Hammerspoon, so the helper is
   launched via `/usr/bin/open` — launchd owns the launch, and the prompt names
   CostCalendar.

It is signed ad-hoc, which ties the permission grant to that exact build. A
rebuild prompts again. Build once, at install, never from a refresh path.

Read it before you trust it: [`helper/CostCalendar/main.swift`](helper/CostCalendar/main.swift).

## What is sent to Claude

Only when AI ranking is switched on — it is off if the `claude` CLI is not
installed, and can be turned off from the pet's menu.

Sent: each event's title, start and end time, all-day flag, attendee **count**,
calendar name, location, and uid. Plus the current time.

Not sent: attendee names or addresses, event notes or descriptions, meeting
links, any other day, and anything at all from outside your calendar.

This goes to Anthropic through the `claude` CLI under your own account, subject
to its terms — the same path as anything else you run through Claude Code. If
that isn't acceptable for your calendar, turn AI ranking off and the
deterministic ranker runs entirely locally.

## What it reads and writes

| Path | Why |
|---|---|
| Your calendars, today only | read — via EventKit, in the helper |
| `~/.cost/calendar.json` | write — the helper's output, overwritten each refresh |
| `~/.cost/cache/YYYY-MM-DD.json` | write — today's ranking; pruned after 7 days |
| `~/.hammerspoon/cost/` | read — code, prompt, sprite |
| `hs.settings` key `cost.state` | read/write — position, theme, preferences |

Nothing else.

## Reporting

Open an issue at https://github.com/mattypark/costpriority/issues.
