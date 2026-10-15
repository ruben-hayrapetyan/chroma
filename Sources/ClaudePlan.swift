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

    private enum CodingKeys: String, CodingKey {
        case op, ref, title, start, end, allDay, location, notes, category, recurrence, occurrences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        op = try container.decode(String.self, forKey: .op)
        // Now and then the number comes back as text, "12" or "#12".
        if let number = try? container.decodeIfPresent(Int.self, forKey: .ref) {
            ref = number
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .ref) {
            ref = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
        }
        title = try container.decodeIfPresent(String.self, forKey: .title)
        start = try container.decodeIfPresent(String.self, forKey: .start)
        end = try container.decodeIfPresent(String.self, forKey: .end)
        allDay = try container.decodeIfPresent(Bool.self, forKey: .allDay)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        recurrence = try container.decodeIfPresent(ClaudeRecurrence.self, forKey: .recurrence)
        occurrences = try container.decodeIfPresent([String].self, forKey: .occurrences)
    }
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
    struct Reply {
        var plan: ClaudePlan?
        var prose: String
        /// Why nothing will be applied, when there was no plan or it couldn't
        /// be read. Said out loud, because Claude's sentence may still claim
        /// the change was made.
        var problem: String?
    }

    /// Pull the plan out of Claude's reply and hand back the prose separately,
    /// so the panel shows the sentence and not the JSON behind it.
    ///
    /// All or nothing: a plan with one unreadable entry is not applied at all.
    /// A move can arrive as a delete and a create, and applying the half that
    /// parsed would lose the event.
    static func extract(from text: String) -> Reply {
        let fence = #"```(?:json)?\s*(\{[\s\S]*?\})\s*```"#
        guard let regex = try? NSRegularExpression(pattern: fence) else {
            return Reply(plan: nil, prose: text, problem: nil)
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard let last = matches.last,
              let bodyRange = Range(last.range(at: 1), in: text)
        else {
            return Reply(plan: nil, prose: text,
                         problem: "Claude's reply had no plan in it, so nothing was changed.")
        }

        let json = String(text[bodyRange])
        let plan = try? JSONDecoder().decode(ClaudePlan.self, from: Data(json.utf8))

        var prose = text
        for match in matches.reversed() {
            if let whole = Range(match.range, in: prose) { prose.removeSubrange(whole) }
        }
        return Reply(plan: plan, prose: prose.trimmingCharacters(in: .whitespacesAndNewlines),
                     problem: plan == nil
                         ? "Chroma couldn't read Claude's plan, so nothing was changed. Try asking again."
                         : nil)
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
                report.append(delete(operation, snapshot: snapshot, store: store, colors: colors))
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
        // An all-day end is its last day, so a one-day event ends on the day
        // it starts. A day later would make it two.
        let end = date(operation.end) ?? (allDay ? start : start.addingTimeInterval(3600))

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
        guard let shown = resolve(operation.ref, in: snapshot) else {
            return "Couldn't find the event to change."
        }
        guard isOnMain(shown, store: store) else { return leftAlone(shown) }

        // Named dates edit those occurrences and nothing else. If none of them
        // turns up, the answer is to stop, not to change the whole series.
        if let days = operation.occurrences?.compactMap(date), !days.isEmpty {
            var changed: [Date] = []
            var problems: [String] = []
            // One at a time, looked up fresh: saving one occurrence leaves
            // the series' other fetched occurrences out of date.
            for day in days {
                guard let occurrence = store.occurrence(ofSeries: shown.seriesID, on: day) else {
                    problems.append("not on \(shortDay(day))")
                    continue
                }
                do {
                    try save(operation, to: occurrence, movedFrom: days[0], span: .thisEvent,
                             store: store, colors: colors)
                    changed.append(day)
                } catch {
                    problems.append("\(shortDay(day)): \(error.localizedDescription)")
                }
            }
            let title = operation.title ?? shown.title
            guard !changed.isEmpty else {
                return "Left \(shown.title) alone — \(problems.joined(separator: "; "))."
            }
            let tail = problems.isEmpty ? "" : " (\(problems.joined(separator: "; ")))"
            return "Changed \(title) on \(changed.map(shortDay).joined(separator: ", "))\(tail)."
        }

        // The whole series, from the occurrence the snapshot showed onwards.
        // Read again first: Claude worked from a copy that's a minute or so
        // old, and anything it didn't mention should keep its current value,
        // not the one in that copy.
        guard let current = refreshed(shown, store: store) else {
            return "Couldn't change \(shown.title) — it was removed in the meantime."
        }
        do {
            let (start, allDay) = try save(operation, to: current, movedFrom: shown.start, span: nil,
                                           store: store, colors: colors)
            return "Changed \(operation.title ?? current.title) — now \(when(start, allDay))."
        } catch {
            return "Couldn't change \(current.title): \(error.localizedDescription)"
        }
    }

    /// Applies one update to one event. `movedFrom` is the date Claude wrote
    /// the new times against; an occurrence on another date moves by the same
    /// number of days, to the same time of day.
    @discardableResult
    private static func save(_ operation: ClaudeOperation, to item: EventItem, movedFrom base: Date,
                             span: EKSpan?, store: EventStore,
                             colors: EventColors) throws -> (start: Date, allDay: Bool) {
        let calendar = store.calendar
        let allDay = operation.allDay ?? item.isAllDay
        let start = date(operation.start).map { moved(item.start, from: base, to: $0, calendar: calendar) }
            ?? item.start
        let end = date(operation.end).map { moved(item.start, from: base, to: $0, calendar: calendar) }
            ?? (operation.start != nil
                ? start.addingTimeInterval(item.end.timeIntervalSince(item.start))
                : item.end)

        let savedID = try store.update(item,
                                       title: operation.title ?? item.title,
                                       start: start, end: max(end, start), isAllDay: allDay,
                                       location: operation.location ?? item.location,
                                       notes: operation.notes ?? item.notes,
                                       recurrence: operation.recurrence?.rule(parsingDate: date)
                                           .map(RecurrenceEdit.set) ?? .unchanged,
                                       span: span)
        colors.carry(from: item.seriesID, to: savedID)
        if let category = category(operation.category) {
            colors.set(EventColor.named(category.pigmentID), for: savedID ?? item.seriesID)
        }
        return (start, allDay)
    }

    private static func delete(_ operation: ClaudeOperation, snapshot: [EventItem],
                               store: EventStore, colors: EventColors) -> String {
        guard let item = resolve(operation.ref, in: snapshot) else {
            return "Couldn't find the event to remove."
        }
        guard isOnMain(item, store: store) else { return leftAlone(item) }

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

        guard let current = refreshed(item, store: store) else {
            return "\(item.title) was already gone."
        }
        do {
            // A series goes from the occurrence shown onwards; earlier ones
            // stay, as a record of what happened.
            try store.delete(current)
            if !store.seriesExists(current.seriesID) { colors.set(nil, for: current.seriesID) }
            return current.isRecurring
                ? "Removed \(current.title) from \(shortDay(current.start)) on."
                : "Removed \(current.title)."
        } catch {
            return "Couldn't remove \(current.title): \(error.localizedDescription)"
        }
    }

    /// The event as the calendar has it now, or nil if it has since been
    /// deleted. Falls back to looking the occurrence up again, for when an
    /// earlier step of the same plan left the fetched copy unusable.
    private static func refreshed(_ item: EventItem, store: EventStore) -> EventItem? {
        if item.ekEvent.refresh() {
            return EventItem(item.ekEvent, calendarColorID: item.calendarColorID)
        }
        return store.occurrence(ofSeries: item.seriesID, on: item.start)
    }

    /// `date` moved the way `base` moved to `target`: the same number of days
    /// along, at `target`'s time of day.
    private static func moved(_ date: Date, from base: Date, to target: Date,
                              calendar: Calendar) -> Date {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: base),
                                           to: calendar.startOfDay(for: target)).day ?? 0
        let time = calendar.dateComponents([.hour, .minute], from: target)
        let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: date)) ?? date
        return calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0,
                             second: 0, of: day) ?? day
    }

    /// Claude changes the main calendar and nothing else. Other calendars are
    /// in the snapshot so it can see what a day holds — and some are shared,
    /// where a wrong guess would delete someone else's booking.
    private static func isOnMain(_ item: EventItem, store: EventStore) -> Bool {
        item.calendarID == store.targetCalendar?.calendarIdentifier
    }

    private static func leftAlone(_ item: EventItem) -> String {
        "Left \(item.title) alone — it's on \u{201C}\(item.calendarTitle)\u{201D}, which Claude can't change."
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
