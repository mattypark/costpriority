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
//   CostCalendar --out /tmp/costcal.json [--day 2026-08-02]

import EventKit
import Foundation

// ------------------------------------------------------------------ arguments

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

let outputPath = argument("--out") ?? "/tmp/costcal.json"

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
if gate.wait(timeout: .now() + 30) == .timedOut {
    fail("timeout", "no answer from the calendar permission prompt after 30s")
}

if !granted {
    fail("denied",
         accessError?.localizedDescription
         ?? "calendar access was refused — System Settings > Privacy & Security > Calendars")
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

write([
    "day": formatter.string(from: dayStart),
    "generated": Int(Date().timeIntervalSince1970),
    "count": payload.count,
    "events": payload,
])

exit(0)
