import Foundation
import SwiftUI

/// The four zoom levels, in the order they appear in the segmented control.
enum ViewMode: String, CaseIterable, Identifiable {
    case day, week, month, year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        }
    }

    /// ⌘1 … ⌘4, matching the order of the cases.
    var shortcut: KeyEquivalent {
        switch self {
        case .day: return "1"
        case .week: return "2"
        case .month: return "3"
        case .year: return "4"
        }
    }

    /// The calendar unit one press of ‹ or › moves by.
    var stepUnit: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }

    /// The span actually drawn for an anchor date.
    ///
    /// Month deliberately returns the whole six-week grid rather than the
    /// calendar month, so the leading and trailing days are populated too.
    func interval(around anchor: Date, calendar: Calendar) -> DateInterval {
        switch self {
        case .day:
            let start = calendar.startOfDay(for: anchor)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            return DateInterval(start: start, end: end)
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start
                ?? calendar.startOfDay(for: anchor)
            let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
            return DateInterval(start: start, end: end)
        case .month:
            let first = ViewMode.gridStart(for: anchor, calendar: calendar)
            let end = calendar.date(byAdding: .day, value: 42, to: first) ?? first
            return DateInterval(start: first, end: end)
        case .year:
            let start = calendar.dateInterval(of: .year, for: anchor)?.start ?? anchor
            let end = calendar.date(byAdding: .year, value: 1, to: start) ?? start
            return DateInterval(start: start, end: end)
        }
    }

    /// The Sunday (or locale equivalent) that a month grid opens on.
    static func gridStart(for anchor: Date, calendar: Calendar) -> Date {
        guard let monthStart = calendar.dateInterval(of: .month, for: anchor)?.start
        else { return calendar.startOfDay(for: anchor) }
        let weekday = calendar.component(.weekday, from: monthStart)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -leading, to: monthStart) ?? monthStart
    }

    /// What the header reads for a given anchor.
    func heading(for anchor: Date, calendar: Calendar) -> String {
        switch self {
        case .day:
            return Self.formatted(anchor, "EEEE, MMMM d, yyyy")
        case .week:
            let span = interval(around: anchor, calendar: calendar)
            let last = calendar.date(byAdding: .day, value: -1, to: span.end) ?? span.end
            // "March 3 – 9, 2026" when the week sits inside one month, and
            // "Mar 30 – Apr 5, 2026" when it straddles two.
            if calendar.isDate(span.start, equalTo: last, toGranularity: .month) {
                return "\(Self.formatted(span.start, "MMMM d")) – \(Self.formatted(last, "d, yyyy"))"
            }
            return "\(Self.formatted(span.start, "MMM d")) – \(Self.formatted(last, "MMM d, yyyy"))"
        case .month:
            return Self.formatted(anchor, "LLLL yyyy")
        case .year:
            return Self.formatted(anchor, "yyyy")
        }
    }

    private static func formatted(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
