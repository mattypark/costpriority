// CostCalendar — dumps today's calendar events as JSON, and nothing else.
//
// Why this is a separate .app bundle rather than code inside the pet:
//
//   1. EventKit on macOS 14+ requires NSCalendarsFullAccessUsageDescription in
//      the calling process's Info.plist. TCC terminates a process that asks for
//      calendar access without one. Hammerspoon does not ship that key, so the
//      request can never come from inside Hammerspoon.
//   2. A bare swiftc binary has no Info.plist at all, so it has the same problem
//      — hence a real bundle with a real identifier.
//   3. TCC attributes a request to the *responsible* process, which for a child
//      of Hammerspoon is Hammerspoon. Launching through `open` hands the launch
//      to launchd instead, so this becomes its own responsible process and the
//      prompt names CostCalendar.
//
// Because `open` gives the caller no stdout, output goes to a file named by
// --out rather than to standard output.
//
// Modes:
//
//   CostCalendar --out FILE [--day 2026-08-02]        list today's events
//   CostCalendar --out FILE --add                     create; spec as JSON on stdin
//   CostCalendar --out FILE --move                    reschedule; spec as JSON on stdin
//   CostCalendar --out FILE --delete                  remove; spec as JSON on stdin
//
// Write modes need no extra permission: requestFullAccessToEvents already covers
// reading and writing, so the one grant made at install serves all four.
//
// Specs, on stdin:
//   add    { "title", "start", "end", "allDay", "calendar", "notes", "location" }
//   move   { "uid", "start", "end" }
//   delete { "uid" }
//
// Times are epoch seconds. Every mode writes a JSON result to --out, including
// the affected event's uid, so the caller can report exactly what changed.

import EventKit
import Foundation

// ------------------------------------------------------------------ arguments

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func flag(_ name: String) -> Bool {
    CommandLine.arguments.contains(name)
}

let outputPath = argument("--out") ?? "/tmp/costcal.json"

enum Mode { case list, add, move, delete }

let mode: Mode = flag("--add") ? .add
               : flag("--move") ? .move
               : flag("--delete") ? .delete
               : .list

// ------------------------------------------------------------------- output

func write(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]))
        ?? Data("{\"error\":\"encode failed\"}".utf8)
    try? data.write(to: URL(fileURLWithPath: outputPath))
}

/// Always leaves a readable file behind. The pet distinguishes "no events" from
/// "couldn't ask" by the error key, and shows the user something useful either
/// way instead of an empty board with no explanation.
func fail(_ code: String, _ message: String) -> Never {
    write(["error": code, "message": message, "events": []])
    FileHandle.standardError.write(Data("\(code): \(message)\n".utf8))
    exit(2)
}

// --------------------------------------------------------------- day boundary

let calendar = Calendar.current
var dayStart = calendar.startOfDay(for: Date())

if let day = argument("--day") {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone.current
    guard let parsed = formatter.date(from: day) else {
        fail("bad-day", "could not parse --day \(day), expected yyyy-MM-dd")
    }
    dayStart = calendar.startOfDay(for: parsed)
}

guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
    fail("bad-range", "could not compute the end of the day")
}

// ------------------------------------------------------------------- access

let store = EKEventStore()
let gate = DispatchSemaphore(value: 0)
var granted = false
var accessError: Error?

// requestAccess(to:) is deprecated on macOS 14+; full access is what reading
// event details actually needs (write-only access returns titles as nil).
store.requestFullAccessToEvents { ok, error in
    granted = ok
    accessError = error
    gate.signal()
}

// A command-line-shaped process would exit before the completion handler ever
// ran. Blocking here is the single most common thing missing from helpers of
// this shape.
//
// The window is generous because it has to cover a human reading a permission
// dialog, not just an API call. That dialog reappears after every rebuild: the
// ad-hoc signature gives each build a different cdhash, and TCC keys the grant
// to it. Normal runs answer instantly from the existing grant.
if gate.wait(timeout: .now() + 120) == .timedOut {
    fail("timeout", "no answer from the calendar permission prompt after 120s")
}

if !granted {
    fail("denied",
         accessError?.localizedDescription
         ?? "calendar access was refused — System Settings > Privacy & Security > Calendars")
}

// --------------------------------------------------------------------- write

/// The spec for a write.
///
/// Read from the file named by --spec, not from stdin: this runs under `open`,
/// which gives the launched app no stdin at all — the same reason output goes to
/// a file rather than being printed. Stdin is still accepted as a fallback so the
/// helper stays testable directly from a terminal.
func readSpec() -> [String: Any] {
    var data: Data

    if let specPath = argument("--spec") {
        guard let contents = FileManager.default.contents(atPath: specPath) else {
            fail("bad-spec", "could not read the spec file at \(specPath)")
        }
        data = contents
    } else {
        data = FileHandle.standardInput.readDataToEndOfFile()
    }

    guard let object = try? JSONSerialization.jsonObject(with: data),
          let spec = object as? [String: Any] else {
        fail("bad-spec", "the event spec was not valid JSON")
    }
    return spec
}

func describe(_ event: EKEvent) -> [String: Any] {
    var out: [String: Any] = [
        "uid": event.eventIdentifier ?? "",
        "title": event.title ?? "",
        "allDay": event.isAllDay,
        "calendar": event.calendar?.title ?? "",
    ]
    if !event.isAllDay {
        out["start"] = Int(event.startDate.timeIntervalSince1970)
        out["endTime"] = Int(event.endDate.timeIntervalSince1970)
    }
    return out
}

/// Recurring events arrive with a `/RID=` suffix on the identifier. Look the
/// bare identifier up too, so a single occurrence can still be found.
func findEvent(_ uid: String) -> EKEvent? {
    if let direct = store.event(withIdentifier: uid) { return direct }

    if let slash = uid.range(of: "/RID=") {
        let base = String(uid[uid.startIndex..<slash.lowerBound])
        if let event = store.event(withIdentifier: base) { return event }
    }
    return nil
}

if mode != .list {
    let spec = readSpec()

    switch mode {
    case .add:
        guard let title = spec["title"] as? String, !title.isEmpty else {
            fail("bad-spec", "add needs a title")
        }
        guard let startEpoch = spec["start"] as? Double else {
            fail("bad-spec", "add needs a start time")
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.isAllDay = (spec["allDay"] as? Bool) ?? false
        event.startDate = Date(timeIntervalSince1970: startEpoch)
        // Default to an hour, which is what people mean when they don't say.
        event.endDate = Date(timeIntervalSince1970: (spec["end"] as? Double) ?? (startEpoch + 3600))

        if let notes = spec["notes"] as? String, !notes.isEmpty { event.notes = notes }
        if let location = spec["location"] as? String, !location.isEmpty { event.location = location }

        // Named calendar if it exists and can be written to, otherwise the
        // default. Writing to a read-only subscribed calendar throws.
        var target = store.defaultCalendarForNewEvents
        if let wanted = spec["calendar"] as? String, !wanted.isEmpty {
            let match = store.calendars(for: .event).first {
                $0.title.compare(wanted, options: .caseInsensitive) == .orderedSame
                    && $0.allowsContentModifications
            }
            if let match { target = match }
        }
        guard let calendar = target, calendar.allowsContentModifications else {
            fail("no-calendar", "no writable calendar available")
        }
        event.calendar = calendar

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            fail("save-failed", error.localizedDescription)
        }
        write(["action": "add", "event": describe(event)])

    case .move:
        guard let uid = spec["uid"] as? String, let event = findEvent(uid) else {
            fail("not-found", "no event with that identifier")
        }
        guard let startEpoch = spec["start"] as? Double else {
            fail("bad-spec", "move needs a start time")
        }

        // Preserve the original duration unless a new end is given — "push my
        // 3pm to 5" means move it, not shorten it.
        let duration = event.endDate.timeIntervalSince(event.startDate)
        event.startDate = Date(timeIntervalSince1970: startEpoch)
        event.endDate = Date(timeIntervalSince1970: (spec["end"] as? Double) ?? (startEpoch + duration))

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            fail("save-failed", error.localizedDescription)
        }
        write(["action": "move", "event": describe(event)])

    case .delete:
        guard let uid = spec["uid"] as? String, let event = findEvent(uid) else {
            fail("not-found", "no event with that identifier")
        }
        let snapshot = describe(event)

        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            fail("remove-failed", error.localizedDescription)
        }
        write(["action": "delete", "event": snapshot])

    case .list:
        break
    }

    exit(0)
}

// -------------------------------------------------------------------- events

let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
let events = store.events(matching: predicate)

var payload: [[String: Any]] = []

for event in events {
    // Did *you* say no? A declined invite is still on the calendar, and ranking
    // it would be actively wrong.
    let declined = event.attendees?.contains {
        $0.isCurrentUser && $0.participantStatus == .declined
    } ?? false

    var item: [String: Any] = [
        "uid": event.eventIdentifier ?? UUID().uuidString,
        "title": event.title ?? "Untitled",
        "allDay": event.isAllDay,
        "attendees": event.attendees?.count ?? 0,
        "calendar": event.calendar?.title ?? "",
        "declined": declined || event.status == .canceled,
    ]

    // All-day events carry meaningless clock times; the pet renders them as
    // "all day" and the ranker treats a nil start differently, so send nothing.
    if !event.isAllDay {
        item["start"] = Int(event.startDate.timeIntervalSince1970)
        item["endTime"] = Int(event.endDate.timeIntervalSince1970)
    }

    if let location = event.location, !location.isEmpty {
        item["location"] = location
    }
    if let notes = event.notes, !notes.isEmpty {
        item["notes"] = String(notes.prefix(400))
    }

    payload.append(item)
}

let formatter = DateFormatter()
formatter.dateFormat = "yyyy-MM-dd"

// Which calendars can actually be written to, and which one a new event lands in
// by default. The natural-language parser needs this to honour "put it on my
// work calendar" without guessing at names that may not exist.
let writable = store.calendars(for: .event)
    .filter(\.allowsContentModifications)
    .map(\.title)

write([
    "day": formatter.string(from: dayStart),
    "generated": Int(Date().timeIntervalSince1970),
    "count": payload.count,
    "events": payload,
    "calendars": writable,
    "defaultCalendar": store.defaultCalendarForNewEvents?.title ?? "",
])

exit(0)
