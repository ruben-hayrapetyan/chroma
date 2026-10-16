import EventKit
import Foundation

/// Repeat rules in the text form Google keeps them in —
/// `RRULE:FREQ=WEEKLY;BYDAY=MO,WE;UNTIL=20261219T045900Z` — and back.
///
/// The app's own model of a repeat stays EventKit's `EKRecurrenceRule`. It's a
/// plain value that needs no calendar access, so the editor and Ask Claude
/// build the same thing whichever source the event is going to.
enum RRule {
    private static let weekdays: [(code: String, day: EKWeekday)] = [
        ("SU", .sunday), ("MO", .monday), ("TU", .tuesday), ("WE", .wednesday),
        ("TH", .thursday), ("FR", .friday), ("SA", .saturday),
    ]

    private static let frequencies: [(code: String, frequency: EKRecurrenceFrequency)] = [
        ("DAILY", .daily), ("WEEKLY", .weekly), ("MONTHLY", .monthly), ("YEARLY", .yearly),
    ]

    // MARK: - Writing

    static func line(_ rule: EKRecurrenceRule, allDay: Bool) -> String {
        let frequency = frequencies.first { $0.frequency == rule.frequency }?.code ?? "WEEKLY"
        var parts = ["FREQ=\(frequency)"]
        if rule.interval > 1 { parts.append("INTERVAL=\(rule.interval)") }
        if let days = rule.daysOfTheWeek, !days.isEmpty {
            let codes = days.compactMap { day -> String? in
                guard let code = weekdays.first(where: { $0.day == day.dayOfTheWeek })?.code else { return nil }
                return (day.weekNumber == 0 ? "" : "\(day.weekNumber)") + code
            }
            parts.append("BYDAY=" + codes.joined(separator: ","))
        }
        for (key, values) in [("BYMONTHDAY", rule.daysOfTheMonth), ("BYMONTH", rule.monthsOfTheYear),
                              ("BYWEEKNO", rule.weeksOfTheYear), ("BYYEARDAY", rule.daysOfTheYear),
                              ("BYSETPOS", rule.setPositions)] {
            if let values, !values.isEmpty {
                parts.append("\(key)=" + values.map { "\($0.intValue)" }.joined(separator: ","))
            }
        }
        if let end = rule.recurrenceEnd {
            if let date = end.endDate {
                parts.append("UNTIL=" + until(date, allDay: allDay))
            } else if end.occurrenceCount > 0 {
                parts.append("COUNT=\(end.occurrenceCount)")
            }
        }
        return "RRULE:" + parts.joined(separator: ";")
    }

    /// An all-day series ends on a date; a timed one at an instant, in UTC.
    static func until(_ date: Date, allDay: Bool) -> String {
        allDay ? dateOnly.string(from: date) : utcStamp.string(from: date)
    }

    // MARK: - Reading

    /// The first RRULE among a series' lines, as EventKit would hold it. Nil
    /// for anything this can't read, like FREQ=HOURLY.
    static func rule(_ line: String) -> EKRecurrenceRule? {
        guard let fields = fields(of: line),
              let frequency = frequencies.first(where: { $0.code == fields["FREQ"] })?.frequency
        else { return nil }

        let days = fields["BYDAY"]?.split(separator: ",").compactMap { token -> EKRecurrenceDayOfWeek? in
            let text = String(token).trimmingCharacters(in: .whitespaces).uppercased()
            guard text.count >= 2,
                  let day = weekdays.first(where: { $0.code == String(text.suffix(2)) })?.day
            else { return nil }
            let number = Int(text.dropLast(2)) ?? 0
            return EKRecurrenceDayOfWeek(dayOfTheWeek: day, weekNumber: number)
        }
        func numbers(_ key: String) -> [NSNumber]? {
            let values = fields[key]?.split(separator: ",").compactMap { Int($0) }.map(NSNumber.init(value:))
            return (values?.isEmpty ?? true) ? nil : values
        }

        var end: EKRecurrenceEnd?
        if let text = fields["UNTIL"], let date = untilDate(text) {
            end = EKRecurrenceEnd(end: date)
        } else if let count = fields["COUNT"].flatMap(Int.init), count > 0 {
            end = EKRecurrenceEnd(occurrenceCount: count)
        }

        return EKRecurrenceRule(recurrenceWith: frequency,
                                interval: max(fields["INTERVAL"].flatMap(Int.init) ?? 1, 1),
                                daysOfTheWeek: (days?.isEmpty ?? true) ? nil : days,
                                daysOfTheMonth: numbers("BYMONTHDAY"),
                                monthsOfTheYear: numbers("BYMONTH"),
                                weeksOfTheYear: numbers("BYWEEKNO"),
                                daysOfTheYear: numbers("BYYEARDAY"),
                                setPositions: numbers("BYSETPOS"),
                                end: end)
    }

    /// Every rule in a series' lines, or nil when there are none to read.
    static func rules(_ lines: [String]?) -> [EKRecurrenceRule]? {
        let parsed = (lines ?? []).compactMap(rule)
        return parsed.isEmpty ? nil : parsed
    }

    // MARK: - Splitting a series

    /// The series' lines cut short so its last occurrence is the one before
    /// `occurrence`. A count gives way to the end date, which says the same
    /// thing more exactly.
    static func ending(_ lines: [String], before occurrence: Date, allDay: Bool,
                       calendar: Calendar) -> [String] {
        let last = allDay
            ? calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: occurrence)) ?? occurrence
            : occurrence.addingTimeInterval(-1)
        return lines.map { line in
            guard let parts = parts(of: line) else { return line }
            let kept = parts.filter { !$0.uppercased().hasPrefix("UNTIL=") && !$0.uppercased().hasPrefix("COUNT=") }
            return "RRULE:" + (kept + ["UNTIL=" + until(last, allDay: allDay)]).joined(separator: ";")
        }
    }

    /// The COUNT on the series' rule, if it ends after a number of times.
    static func count(in lines: [String]) -> Int? {
        lines.lazy.compactMap { fields(of: $0)?["COUNT"].flatMap(Int.init) }.first
    }

    static func setting(count: Int, in lines: [String]) -> [String] {
        lines.map { line in
            guard let parts = parts(of: line) else { return line }
            let kept = parts.filter { !$0.uppercased().hasPrefix("COUNT=") }
            return "RRULE:" + (kept + ["COUNT=\(max(count, 1))"]).joined(separator: ";")
        }
    }

    // MARK: - Pieces

    private static func parts(of line: String) -> [String]? {
        guard line.uppercased().hasPrefix("RRULE:") else { return nil }
        return line.dropFirst(6).split(separator: ";").map(String.init)
    }

    private static func fields(of line: String) -> [String: String]? {
        parts(of: line).map { parts in
            Dictionary(parts.compactMap { part -> (String, String)? in
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                return pair.count == 2 ? (pair[0].uppercased(), pair[1]) : nil
            }, uniquingKeysWith: { first, _ in first })
        }
    }

    private static func untilDate(_ text: String) -> Date? {
        if text.hasSuffix("Z") { return utcStamp.date(from: text) }
        if text.contains("T") { return localStamp.date(from: text) }
        return dateOnly.date(from: text)
    }

    private static func formatter(_ format: String, utc: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = utc ? TimeZone(identifier: "UTC") : .autoupdatingCurrent
        formatter.dateFormat = format
        return formatter
    }

    private static let utcStamp = formatter("yyyyMMdd'T'HHmmss'Z'", utc: true)
    private static let localStamp = formatter("yyyyMMdd'T'HHmmss", utc: false)
    private static let dateOnly = formatter("yyyyMMdd", utc: false)
}
