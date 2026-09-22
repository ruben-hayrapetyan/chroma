import EventKit
import SwiftUI

/// How an edit should treat an event's repeat rule.
///
/// Three cases rather than an optional, because "leave it alone" and "remove the
/// repeat" are different instructions and an optional can only say one of them.
enum RecurrenceEdit {
    case unchanged
    case clear
    case set(EKRecurrenceRule)
}

/// The repeat rule as the panes edit it.
struct RecurrenceDraft: Equatable {
    enum Frequency: String, CaseIterable, Identifiable {
        case never, daily, weekly, monthly, yearly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .never: return "Never"
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            case .monthly: return "Monthly"
            case .yearly: return "Yearly"
            }
        }
    }

    enum Ending: String, CaseIterable, Identifiable {
        case never, onDate, afterCount
        var id: String { rawValue }
        var label: String {
            switch self {
            case .never: return "Never"
            case .onDate: return "On date"
            case .afterCount: return "After"
            }
        }
    }

    var frequency: Frequency = .never
    var interval = 1
    /// 1 = Sunday … 7 = Saturday, matching EKWeekday's raw values.
    var weekdays: Set<Int> = []
    var ending: Ending = .never
    var untilDate = Calendar.current.date(byAdding: .month, value: 3, to: Date()) ?? Date()
    var count = 10

    var repeats: Bool { frequency != .never }

    /// Nil when the event does not repeat.
    var rule: EKRecurrenceRule? {
        let frequencies: [Frequency: EKRecurrenceFrequency] = [
            .daily: .daily, .weekly: .weekly, .monthly: .monthly, .yearly: .yearly,
        ]
        guard let ekFrequency = frequencies[frequency] else { return nil }

        let days = weekdays.sorted().compactMap(EKWeekday.init(rawValue:))
            .map { EKRecurrenceDayOfWeek($0) }

        var end: EKRecurrenceEnd?
        switch ending {
        case .never:
            end = nil
        case .onDate:
            // "Until the 19th" means through the end of that day.
            let inclusive = Calendar.current.date(bySettingHour: 23, minute: 59, second: 0,
                                                  of: untilDate) ?? untilDate
            end = EKRecurrenceEnd(end: inclusive)
        case .afterCount:
            end = EKRecurrenceEnd(occurrenceCount: max(count, 1))
        }

        return EKRecurrenceRule(recurrenceWith: ekFrequency,
                                interval: max(interval, 1),
                                daysOfTheWeek: (frequency == .weekly && !days.isEmpty) ? days : nil,
                                daysOfTheMonth: nil, monthsOfTheYear: nil,
                                weeksOfTheYear: nil, daysOfTheYear: nil,
                                setPositions: nil, end: end)
    }

    var edit: RecurrenceEdit { rule.map(RecurrenceEdit.set) ?? .clear }

    /// Read an existing event's rule back into something editable.
    static func from(_ rule: EKRecurrenceRule?) -> RecurrenceDraft {
        var draft = RecurrenceDraft()
        guard let rule else { return draft }

        switch rule.frequency {
        case .daily: draft.frequency = .daily
        case .weekly: draft.frequency = .weekly
        case .monthly: draft.frequency = .monthly
        case .yearly: draft.frequency = .yearly
        @unknown default: draft.frequency = .weekly
        }
        draft.interval = max(rule.interval, 1)
        draft.weekdays = Set((rule.daysOfTheWeek ?? []).map { $0.dayOfTheWeek.rawValue })

        if let end = rule.recurrenceEnd {
            if let until = end.endDate {
                draft.ending = .onDate
                draft.untilDate = until
            } else if end.occurrenceCount > 0 {
                draft.ending = .afterCount
                draft.count = end.occurrenceCount
            }
        }
        return draft
    }

    /// "Weekly on Mon, Wed until 19 Dec" — shown when the editor is collapsed.
    var summary: String {
        guard repeats else { return "Never" }
        var text = interval > 1 ? "Every \(interval) \(unitPlural)" : frequency.label

        if frequency == .weekly, !weekdays.isEmpty {
            let names = Calendar.current.shortWeekdaySymbols
            let picked = weekdays.sorted().compactMap { index -> String? in
                guard index >= 1, index <= names.count else { return nil }
                return names[index - 1]
            }
            text += " on " + picked.joined(separator: ", ")
        }
        switch ending {
        case .never: break
        case .onDate:
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM yyyy"
            text += " until \(formatter.string(from: untilDate))"
        case .afterCount:
            text += ", \(count) times"
        }
        return text
    }

    private var unitPlural: String {
        switch frequency {
        case .never: return ""
        case .daily: return "days"
        case .weekly: return "weeks"
        case .monthly: return "months"
        case .yearly: return "years"
        }
    }
}

/// The repeat controls, shared by the create and edit panes.
struct RecurrenceEditor: View {
    @Binding var draft: RecurrenceDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("REPEAT", systemImage: "repeat")
                .font(Theme.eyebrow)
                .foregroundStyle(Theme.graphite)

            Picker("", selection: $draft.frequency) {
                ForEach(RecurrenceDraft.Frequency.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            .font(Theme.ui(12))

            if draft.repeats {
                HStack(spacing: 6) {
                    Text("Every").font(Theme.ui(12)).foregroundStyle(Theme.graphite)
                    Stepper(value: $draft.interval, in: 1...30) {
                        Text("\(draft.interval)").font(Theme.time(12))
                    }
                    .labelsHidden()
                    Text(draft.interval == 1 ? singular : plural)
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.graphite)
                }

                if draft.frequency == .weekly { weekdayRow }

                HStack(spacing: 6) {
                    Text("Ends").font(Theme.ui(12)).foregroundStyle(Theme.graphite)
                    Picker("", selection: $draft.ending) {
                        ForEach(RecurrenceDraft.Ending.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                switch draft.ending {
                case .never:
                    EmptyView()
                case .onDate:
                    DatePicker("", selection: $draft.untilDate, displayedComponents: [.date])
                        .labelsHidden()
                        .font(Theme.ui(12))
                case .afterCount:
                    HStack(spacing: 6) {
                        Stepper(value: $draft.count, in: 1...365) {
                            Text("\(draft.count)").font(Theme.time(12))
                        }
                        .labelsHidden()
                        Text("times").font(Theme.ui(12)).foregroundStyle(Theme.graphite)
                    }
                }
            }
        }
    }

    /// Sun–Sat toggles. Leaving them all off means "on the event's own weekday",
    /// which is what EventKit does with no day list.
    private var weekdayRow: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return HStack(spacing: 3) {
            ForEach(1...7, id: \.self) { day in
                let on = draft.weekdays.contains(day)
                Text(symbols[day - 1])
                    .font(Theme.ui(10, weight: .semibold))
                    .foregroundStyle(on ? Theme.panel : Theme.ink)
                    .frame(width: 24, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(on ? Theme.accent : Theme.wash)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if on { draft.weekdays.remove(day) } else { draft.weekdays.insert(day) }
                    }
            }
        }
    }

    private var singular: String {
        ["daily": "day", "weekly": "week", "monthly": "month", "yearly": "year"][draft.frequency.rawValue] ?? ""
    }
    private var plural: String { singular + "s" }
}
