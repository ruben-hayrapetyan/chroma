import EventKit
import Foundation

/// One change Claude wants made to the calendar.
///
/// Claude no longer touches the calendar itself. It reads a snapshot handed to
/// it in the prompt and replies with operations; Chroma applies them through
/// EventKit, which it already has permission for. That removes AppleScript from
/// the loop entirely — which is what used to launch Calendar.app and leave it
/// sitting in the Dock — and it means the session needs no tools at all.
struct ClaudeOperation: Decodable {
    let op: String                 // create | update | delete
    var ref: Int?                  // the #n of an event in the snapshot
    var title: String?
    var start: String?             // "2026-09-08T17:00", or "2026-09-08" if all-day
    var end: String?
    var allDay: Bool?
    var location: String?
    var notes: String?
    var category: String?          // a slug from Categories.all
    var recurrence: ClaudeRecurrence?
    /// Specific dates of a repeating event — "2026-09-02" — when the change
    /// should hit those occurrences rather than the whole series.
    var occurrences: [String]?
}

/// "Weekly until December 19" and friends.
///
/// Structured rather than an RRULE string, because EventKit has no public way to
/// parse one — `EKRecurrenceRule` has to be built up from parts.
struct ClaudeRecurrence: Decodable {
    let freq: String               // daily | weekly | monthly | yearly
    var interval: Int?             // every n periods, default 1
    var until: String?             // "2026-12-19", inclusive
    var count: Int?                // or a fixed number of occurrences
    var byDay: [String]?           // ["MO","WE","FR"] — weekly only

    private static let weekdays: [String: EKWeekday] = [
        "SU": .sunday, "MO": .monday, "TU": .tuesday, "WE": .wednesday,
        "TH": .thursday, "FR": .friday, "SA": .saturday,
    ]

    /// Nil if the frequency is unreadable — better to create a single event than
    /// to invent a repeat nobody asked for.
    func rule(parsingDate: (String?) -> Date?) -> EKRecurrenceRule? {
        let frequency: EKRecurrenceFrequency
        switch freq.lowercased() {
        case "daily": frequency = .daily
        case "weekly": frequency = .weekly
        case "monthly": frequency = .monthly
        case "yearly", "annually": frequency = .yearly
        default: return nil
        }

        let days = byDay?.compactMap { Self.weekdays[$0.uppercased().prefix(2).description] }
            .map { EKRecurrenceDayOfWeek($0) }

        var end: EKRecurrenceEnd?
        if let until = parsingDate(until) {
            // "until Dec 19" means through the end of the 19th, not 00:00.
            let inclusive = Calendar.current.date(bySettingHour: 23, minute: 59, second: 0,
                                                  of: until) ?? until
            end = EKRecurrenceEnd(end: inclusive)
        } else if let count, count > 0 {
            end = EKRecurrenceEnd(occurrenceCount: count)
        }

        return EKRecurrenceRule(recurrenceWith: frequency,
                                interval: max(interval ?? 1, 1),
                                daysOfTheWeek: (days?.isEmpty ?? true) ? nil : days,
                                daysOfTheMonth: nil, monthsOfTheYear: nil,
                                weeksOfTheYear: nil, daysOfTheYear: nil,
                                setPositions: nil, end: end)
    }
}

struct ClaudePlan: Decodable {
    let operations: [ClaudeOperation]
}

enum PlanParser {
    /// Pull the plan out of Claude's reply and hand back the prose separately,
    /// so the panel shows the sentence and not the JSON behind it.
    static func extract(from text: String) -> (plan: ClaudePlan?, prose: String) {
        let fence = #"```(?:json)?\s*(\{[\s\S]*?\})\s*```"#
        guard let regex = try? NSRegularExpression(pattern: fence) else { return (nil, text) }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard let last = matches.last,
              let bodyRange = Range(last.range(at: 1), in: text)
        else { return (nil, text) }

        let json = String(text[bodyRange])
        let plan = try? JSONDecoder().decode(ClaudePlan.self, from: Data(json.utf8))

        var prose = text
        for match in matches.reversed() {
            if let whole = Range(match.range, in: prose) { prose.removeSubrange(whole) }
        }
        return (plan, prose.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Turns a plan into actual calendar changes.
@MainActor
enum PlanApplier {
    /// `snapshot` is the same list, in the same order, that the prompt showed —
    /// so a `ref` of 3 means the same event on both sides.
    static func apply(_ plan: ClaudePlan, snapshot: [EventItem],
                      store: EventStore, colors: EventColors) -> [String] {
        var report: [String] = []

        for operation in plan.operations {
            switch operation.op.lowercased() {
            case "create":
                report.append(create(operation, store: store, colors: colors))
            case "update":
                report.append(update(operation, snapshot: snapshot, store: store, colors: colors))
            case "delete":
                report.append(delete(operation, snapshot: snapshot, store: store))
            default:
                report.append("Ignored an unknown operation \"\(operation.op)\".")
            }
        }
        return report
    }

    private static func create(_ operation: ClaudeOperation,
                               store: EventStore, colors: EventColors) -> String {
        guard let title = operation.title, !title.isEmpty else {
            return "Skipped a new event with no title."
        }
        guard let start = date(operation.start) else {
            return "Skipped \"\(title)\": couldn't read its start time."
        }
        let allDay = operation.allDay ?? false
        let end = date(operation.end) ?? start.addingTimeInterval(allDay ? 86_400 : 3600)

        let rule = operation.recurrence?.rule(parsingDate: date)
        do {
            let seriesID = try store.create(title: title, start: start, end: end,
                                            isAllDay: allDay,
                                            location: operation.location ?? "",
                                            notes: operation.notes ?? "",
                                            recurrence: rule)
            if let seriesID, let category = category(operation.category) {
                colors.set(EventColor.named(category.pigmentID), for: seriesID)
                return "Added \(title) — \(when(start, allDay))\(repeats(rule)), \(category.name.lowercased())."
            }
            return "Added \(title) — \(when(start, allDay))\(repeats(rule))."
        } catch {
            return "Couldn't add \(title): \(error.localizedDescription)"
        }
    }

    private static func update(_ operation: ClaudeOperation, snapshot: [EventItem],
                               store: EventStore, colors: EventColors) -> String {
        guard let series = resolve(operation.ref, in: snapshot) else {
            return "Couldn't find the event to change."
        }
        // A single named date edits that occurrence only.
        let single = operation.occurrences?.compactMap(date).first
            .flatMap { store.occurrence(ofSeries: series.seriesID, on: $0) }
        let item = single ?? series
        let span: EKSpan? = single != nil ? .thisEvent : nil
        let allDay = operation.allDay ?? item.isAllDay
        let start = date(operation.start) ?? item.start
        let end = date(operation.end) ?? (operation.start != nil
            ? start.addingTimeInterval(item.end.timeIntervalSince(item.start))
            : item.end)

        do {
            try store.update(item,
                             title: operation.title ?? item.title,
                             start: start, end: end, isAllDay: allDay,
                             location: operation.location ?? item.location,
                             notes: operation.notes ?? item.notes,
                             recurrence: operation.recurrence?.rule(parsingDate: date)
                                 .map(RecurrenceEdit.set) ?? .unchanged,
                             span: span)
            if let category = category(operation.category) {
                colors.set(EventColor.named(category.pigmentID), for: item.seriesID)
            }
            return "Changed \(operation.title ?? item.title) — now \(when(start, allDay))."
        } catch {
            return "Couldn't change \(item.title): \(error.localizedDescription)"
        }
    }

    private static func delete(_ operation: ClaudeOperation, snapshot: [EventItem],
                               store: EventStore) -> String {
        guard let item = resolve(operation.ref, in: snapshot) else {
            return "Couldn't find the event to remove."
        }

        // Named dates mean single occurrences; resolved one at a time, because
        // each removal invalidates the rest of the series' fetched objects.
        if let dates = operation.occurrences?.compactMap(date), !dates.isEmpty {
            var removed: [Date] = []
            var missed = 0
            for day in dates {
                guard let occurrence = store.occurrence(ofSeries: item.seriesID, on: day) else {
                    missed += 1
                    continue
                }
                do {
                    try store.delete(occurrence, span: .thisEvent)
                    removed.append(day)
                } catch {
                    missed += 1
                }
            }
            guard !removed.isEmpty else {
                return "Couldn't remove any occurrence of \(item.title)."
            }
            let list = removed.map(shortDay).joined(separator: ", ")
            let tail = missed > 0 ? " (\(missed) not found)" : ""
            return "Removed \(item.title) on \(list)\(tail)."
        }

        do {
            try store.delete(item)
            return item.isRecurring
                ? "Removed the whole \(item.title) series."
                : "Removed \(item.title)."
        } catch {
            return "Couldn't remove \(item.title): \(error.localizedDescription)"
        }
    }

    private static func resolve(_ ref: Int?, in snapshot: [EventItem]) -> EventItem? {
        guard let ref, ref >= 1, ref <= snapshot.count else { return nil }
        return snapshot[ref - 1]
    }

    private static func category(_ slug: String?) -> EventCategory? {
        guard let slug = slug?.lowercased() else { return nil }
        return Categories.all.first { $0.slug == slug }
    }

    /// Accepts "2026-09-08T17:00" and the all-day "2026-09-08". Local time, and
    /// a fixed locale so parsing never drifts with the user's region settings.
    private static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let parsed = formatter.date(from: text) { return parsed }
        }
        return nil
    }

    /// " weekly until 19 Dec" — the tail of the confirmation line.
    private static func repeats(_ rule: EKRecurrenceRule?) -> String {
        guard let rule else { return "" }
        let frequency: String
        switch rule.frequency {
        case .daily: frequency = "daily"
        case .weekly: frequency = "weekly"
        case .monthly: frequency = "monthly"
        case .yearly: frequency = "yearly"
        @unknown default: frequency = "repeating"
        }
        var text = ", \(frequency)"
        if let end = rule.recurrenceEnd {
            if let until = end.endDate {
                let formatter = DateFormatter()
                formatter.dateFormat = "d MMM"
                text += " until \(formatter.string(from: until))"
            } else if end.occurrenceCount > 0 {
                text += " ×\(end.occurrenceCount)"
            }
        }
        return text
    }

    private static func shortDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    private static func when(_ date: Date, _ allDay: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = allDay ? "EEE d MMM" : "EEE d MMM, h:mm a"
        return formatter.string(from: date)
    }
}
