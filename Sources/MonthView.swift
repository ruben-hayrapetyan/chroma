import SwiftUI

/// Six weeks of day cells. Always six rows, so the grid does not jump as months
/// of different lengths come and go.
struct MonthView: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var colors: EventColors

    let onOpen: (EventItem) -> Void
    let onEdit: (EventItem) -> Void
    let onAdd: (Date) -> Void

    var body: some View {
        VStack(spacing: 0) {
            WeekdayHeader()
            Divider().foregroundStyle(Theme.rule)

            GeometryReader { geo in
                let days = gridDays
                let rowHeight = geo.size.height / 6
                let columnWidth = geo.size.width / 7

                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { column in
                                let day = days[row * 7 + column]
                                MonthDayCell(day: day,
                                             rowHeight: rowHeight,
                                             onOpen: onOpen,
                                             onEdit: onEdit,
                                             onAdd: onAdd)
                                    .frame(width: columnWidth, height: rowHeight)
                            }
                        }
                    }
                }
            }
        }
        .card()
    }

    private var gridDays: [Date] {
        let first = ViewMode.gridStart(for: store.anchor, calendar: store.calendar)
        return (0..<42).compactMap { store.calendar.date(byAdding: .day, value: $0, to: first) }
    }
}

struct MonthDayCell: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var colors: EventColors

    let day: Date
    let rowHeight: CGFloat
    let onOpen: (EventItem) -> Void
    let onEdit: (EventItem) -> Void
    let onAdd: (Date) -> Void

    @State private var hovering = false

    var body: some View {
        let calendar = store.calendar
        let items = store.items(on: day)
        let isToday = calendar.isDateInToday(day)
        let isSelected = calendar.isDate(day, inSameDayAs: store.selectedDay)
        let inMonth = calendar.isDate(day, equalTo: store.anchor, toGranularity: .month)
        let isWeekend = calendar.isDateInWeekend(day)

        // Header, chips and the "+n more" line have to fit inside the row.
        let visible = max(Int((rowHeight - 32) / 19), 0)

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("\(calendar.component(.day, from: day))")
                    .font(Theme.time(12, weight: isToday ? .bold : .medium))
                    .foregroundStyle(isToday ? Theme.panel : (inMonth ? Theme.ink : Theme.faint))
                    .frame(width: 21, height: 19)
                    .background {
                        if isToday {
                            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.accent)
                        } else if isSelected {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1)
                        }
                    }
                Spacer(minLength: 0)
                if hovering {
                    Button { onAdd(calendar.startOfDay(for: day)) } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.graphite)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 1)

            ForEach(items.prefix(visible)) { item in
                EventChip(item: item, compact: rowHeight < 90)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onEdit(item) }
                    .onTapGesture { onOpen(item) }
                    .contextMenu { ColorMenu(item: item, onOpen: onOpen, onEdit: onEdit) }
            }

            if items.count > visible {
                Text("\(items.count - visible) more")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    .onTapGesture { store.focus(on: day, switchingTo: .day) }
            }

            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cellBackground(inMonth: inMonth, isWeekend: isWeekend, isSelected: isSelected))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
        .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 0.5) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.selectedDay = calendar.startOfDay(for: day) }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            store.focus(on: day, switchingTo: .day)
        })
        .contextMenu {
            Button("New Event Here") { onAdd(calendar.startOfDay(for: day)) }
            Button("Open This Day") { store.focus(on: day, switchingTo: .day) }
        }
    }

    @ViewBuilder
    private func cellBackground(inMonth: Bool, isWeekend: Bool, isSelected: Bool) -> some View {
        ZStack {
            if !inMonth {
                Theme.outsideMonth
            } else if isWeekend {
                Theme.weekendWash
            }
            if isSelected {
                Theme.accent.opacity(0.06)
            }
        }
    }
}

/// The Sun–Sat strip above a month grid.
struct WeekdayHeader: View {
    @EnvironmentObject var store: EventStore

    var body: some View {
        HStack(spacing: 0) {
            ForEach(symbols, id: \.self) { symbol in
                Text(symbol.uppercased())
                    .font(Theme.eyebrow)
                    .foregroundStyle(Theme.graphite)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
    }

    private var symbols: [String] {
        let all = store.calendar.shortWeekdaySymbols
        let shift = store.calendar.firstWeekday - 1
        return Array(all[shift...] + all[..<shift])
    }
}

/// Right-click menu shared by every event view.
struct ColorMenu: View {
    @EnvironmentObject var colors: EventColors
    let item: EventItem
    let onOpen: (EventItem) -> Void
    let onEdit: (EventItem) -> Void

    var body: some View {
        Button("Show Details") { onOpen(item) }
        Button("Edit…") { onEdit(item) }
        Divider()
        ForEach(EventColor.palette) { swatch in
            Button(swatch.name) { colors.set(swatch, for: item.seriesID) }
        }
        Divider()
        Button("Use Calendar Colour") { colors.set(nil, for: item.seriesID) }
    }
}
