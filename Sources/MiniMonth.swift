import SwiftUI

/// A compact month grid, used both in the sidebar and twelve-up in the year
/// view. Density is shown by tinting the day rather than by drawing chips —
/// at this size a dot is all that fits.
struct MiniMonth: View {
    @EnvironmentObject var store: EventStore

    let month: Date
    var titleStyle: TitleStyle = .full
    var dayDiameter: CGFloat = 22
    var onSelectDay: (Date) -> Void
    var onSelectMonth: ((Date) -> Void)? = nil

    enum TitleStyle { case full, short, none }

    var body: some View {
        VStack(spacing: 4) {
            if titleStyle != .none {
                Text(titleText)
                    .font(.system(size: titleStyle == .full ? 13 : 14,
                                  weight: .semibold, design: .serif))
                    .foregroundStyle(isCurrentMonth ? Theme.accent : Theme.ink)
                    .frame(maxWidth: .infinity, alignment: titleStyle == .full ? .leading : .center)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelectMonth?(month) }
            }

            HStack(spacing: 0) {
                ForEach(Array(weekdayInitials.enumerated()), id: \.offset) { _, initial in
                    Text(initial)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                        .frame(width: dayDiameter)
                }
            }

            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in
                        let day = days[row * 7 + column]
                        dayCell(day)
                            .frame(width: dayDiameter, height: dayDiameter)
                    }
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let calendar = store.calendar
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let isToday = calendar.isDateInToday(day)
        let isSelected = calendar.isDate(day, inSameDayAs: store.selectedDay)
        let busy = inMonth && store.hasEvents(on: day)

        return ZStack {
            if isToday {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.accent)
            } else if isSelected {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1)
            } else if busy {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.accent.opacity(0.14))
            }

            Text("\(calendar.component(.day, from: day))")
                .font(Theme.time(dayDiameter < 20 ? 9 : 10.5,
                                 weight: isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Theme.panel : (inMonth ? Theme.ink : Theme.faint))
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelectDay(calendar.startOfDay(for: day)) }
    }

    private var isCurrentMonth: Bool {
        store.calendar.isDate(month, equalTo: Date(), toGranularity: .month)
    }

    private var titleText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = titleStyle == .full ? "LLLL yyyy" : "LLLL"
        return formatter.string(from: month)
    }

    private var weekdayInitials: [String] {
        let symbols = store.calendar.veryShortWeekdaySymbols
        let shift = store.calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    private var days: [Date] {
        let first = ViewMode.gridStart(for: month, calendar: store.calendar)
        return (0..<42).compactMap { store.calendar.date(byAdding: .day, value: $0, to: first) }
    }
}

/// Twelve mini months. Clicking a month name zooms to it; clicking a day opens
/// that day.
struct YearView: View {
    @EnvironmentObject var store: EventStore

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 260), spacing: 24)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 26) {
                ForEach(months, id: \.self) { month in
                    MiniMonth(month: month,
                              titleStyle: .short,
                              dayDiameter: 26,
                              onSelectDay: { day in store.focus(on: day, switchingTo: .day) },
                              onSelectMonth: { month in store.focus(on: month, switchingTo: .month) })
                }
            }
            .padding(24)
        }
        .card()
    }

    private var months: [Date] {
        guard let start = store.calendar.dateInterval(of: .year, for: store.anchor)?.start
        else { return [] }
        return (0..<12).compactMap { store.calendar.date(byAdding: .month, value: $0, to: start) }
    }
}
