import SwiftUI

/// The day and week views.
///
/// They are the same grid with a different column count, so they share one
/// implementation: a fixed hour ruler down the left, an all-day band pinned
/// under the header, and absolutely positioned blocks over an hour grid.
struct TimeGridView: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var colors: EventColors

    let onOpen: (EventItem) -> Void
    let onEdit: (EventItem) -> Void
    let onAdd: (Date) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().foregroundStyle(Theme.rule)
            allDayBand
            Divider().foregroundStyle(Theme.rule)

            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        HourRuler()
                        ForEach(days, id: \.self) { day in
                            DayColumn(day: day, onOpen: onOpen, onEdit: onEdit, onAdd: onAdd)
                        }
                    }
                    .id("grid")
                }
                .onAppear {
                    // Open on the working day rather than at midnight.
                    proxy.scrollTo("hour-7", anchor: .top)
                }
            }
        }
        .card()
    }

    private var days: [Date] {
        let span = store.mode.interval(around: store.anchor, calendar: store.calendar)
        let count = store.mode == .day ? 1 : 7
        return (0..<count).compactMap {
            store.calendar.date(byAdding: .day, value: $0, to: span.start)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Theme.gutterWidth, height: 0)
            ForEach(days, id: \.self) { day in
                let isToday = store.calendar.isDateInToday(day)
                // One tight row — "SUN 30" — rather than a stacked label over a
                // big numeral, which ate the top of the grid.
                HStack(spacing: 5) {
                    Text(weekdayName(day).uppercased())
                        .font(Theme.eyebrow)
                        .foregroundStyle(isToday ? Theme.accent : Theme.graphite)
                    Text("\(store.calendar.component(.day, from: day))")
                        .font(Theme.time(12, weight: .semibold))
                        .foregroundStyle(isToday ? Theme.panel : Theme.ink)
                        .frame(width: 20, height: 19)
                        .background {
                            if isToday {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Theme.accent)
                            }
                        }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { store.focus(on: day, switchingTo: .day) }
            }
        }
        .frame(height: 30)
        .padding(.vertical, 5)
    }

    /// All-day events get their own band so they do not distort the hour grid.
    private var allDayBand: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("ALL-DAY")
                .font(Theme.eyebrow)
                .foregroundStyle(Theme.faint)
                .frame(width: Theme.gutterWidth, alignment: .trailing)
                .padding(.trailing, 6)
                .padding(.top, 4)

            ForEach(days, id: \.self) { day in
                VStack(spacing: 2) {
                    ForEach(store.allDayItems(on: day)) { item in
                        EventChip(item: item, compact: true, height: Theme.hourHeight / 2)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { onEdit(item) }
                            .onTapGesture { onOpen(item) }
                            .contextMenu { ColorMenu(item: item, onOpen: onOpen, onEdit: onEdit) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.horizontal, 3)
                .padding(.vertical, 5)
            }
        }
        // Entries are sized like a half-hour block, so the band holds about
        // three of them before it needs to scroll.
        .frame(minHeight: Theme.hourHeight / 2 + 10, maxHeight: Theme.hourHeight * 1.9)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func weekdayName(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = store.mode == .day ? "EEEE" : "EEE"
        return formatter.string(from: day)
    }
}

/// The 12 AM … 11 PM labels down the left edge.
struct HourRuler: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack {
                    Spacer()
                    Text(label(hour))
                        .font(Theme.time(9.5))
                        .foregroundStyle(Theme.faint)
                        .offset(y: -6)          // sit on the rule, not under it
                }
                .padding(.trailing, 6)
                .frame(height: Theme.hourHeight, alignment: .top)
                .id("hour-\(hour)")
            }
        }
        .frame(width: Theme.gutterWidth)
    }

    private func label(_ hour: Int) -> String {
        switch hour {
        case 0: return ""            // midnight needs no label at the very top
        case 12: return "12 PM"
        case let h where h < 12: return "\(h) AM"
        default: return "\(hour - 12) PM"
        }
    }
}

/// One day's column: hour rules, the now line, and the positioned blocks.
struct DayColumn: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var colors: EventColors
    @EnvironmentObject var intents: Intents

    let day: Date
    let onOpen: (EventItem) -> Void
    let onEdit: (EventItem) -> Void
    let onAdd: (Date) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                hourRules
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture(count: 2).onEnded { value in
                        beginDraft(atY: value.location.y)
                    })

                ForEach(EventLayout.position(store.timedItems(on: day))) { placed in
                    block(placed, width: geo.size.width)
                }

                if let draft = intents.draft,
                   !draft.isAllDay,
                   store.calendar.isDate(draft.start, inSameDayAs: day) {
                    draftBlock(draft, width: geo.size.width)
                }

                if store.calendar.isDateInToday(day) { nowLine }
            }
        }
        .frame(height: Theme.hourHeight * 24)
        .frame(maxWidth: .infinity)
        .background(store.calendar.isDateInWeekend(day) ? Theme.weekendWash : Color.clear)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 0.5) }
    }

    /// A double-click on empty grid means "new event here", so the time comes
    /// from where the click landed rather than the top of the day.
    private func beginDraft(atY y: CGFloat) {
        let rawMinutes = Double(y) / Double(Theme.hourHeight) * 60
        // Snap to the quarter hour, and keep the whole block inside the day.
        let snapped = min(max((rawMinutes / 15).rounded(.down) * 15, 0), 24 * 60 - 60)
        let start = store.calendar.startOfDay(for: day).addingTimeInterval(snapped * 60)
        withAnimation(.snappy(duration: 0.18)) {
            intents.draft = .hour(at: start)
        }
    }

    /// The provisional block: dashed, accent-tinted, and labelled with the span
    /// it will occupy, so the time is visible before anything is typed.
    private func draftBlock(_ draft: DraftEvent, width: CGFloat) -> some View {
        let startOfDay = store.calendar.startOfDay(for: draft.start)
        let minutes = draft.start.timeIntervalSince(startOfDay) / 60
        let height = max(draft.end.timeIntervalSince(draft.start) / 3600 * Theme.hourHeight, 20)

        return VStack(alignment: .leading, spacing: 1) {
            Text(draft.title.isEmpty ? "New Event" : draft.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            if height > 32 {
                Text(Self.range(draft))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(width: max(width - 6, 20), height: height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                .fill(Theme.accent.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        )
        .offset(x: 3, y: minutes / 60 * Theme.hourHeight)
        .allowsHitTesting(false)
    }

    private static func range(_ draft: DraftEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        let tail = DateFormatter()
        tail.dateFormat = "h:mm a"
        return "\(formatter.string(from: draft.start)) – \(tail.string(from: draft.end))"
    }

    private var hourRules: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { _ in
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 0.5)
                    .frame(height: Theme.hourHeight, alignment: .top)
            }
        }
    }

    private func block(_ placed: PositionedEvent, width: CGFloat) -> some View {
        let minutes = placed.item.minutesFromMidnight(in: store.calendar)
        let height = max(CGFloat(placed.item.durationMinutes) / 60 * Theme.hourHeight, 16)
        let inset: CGFloat = 3
        let usable = width - inset * 2
        let columnWidth = usable / CGFloat(placed.columnCount)

        return EventBlock(item: placed.item, height: height)
            .frame(width: max(columnWidth - 2, 12), height: height)
            .offset(x: inset + columnWidth * CGFloat(placed.column),
                    y: CGFloat(minutes) / 60 * Theme.hourHeight)
            .onTapGesture(count: 2) { onEdit(placed.item) }
            .onTapGesture { onOpen(placed.item) }
            .contextMenu { ColorMenu(item: placed.item, onOpen: onOpen, onEdit: onEdit) }
    }

    /// The red "now" line, redrawn every minute.
    private var nowLine: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let calendar = store.calendar
            let startOfDay = calendar.startOfDay(for: context.date)
            let minutes = context.date.timeIntervalSince(startOfDay) / 60

            ZStack(alignment: .leading) {
                Circle()
                    .fill(Theme.now)
                    .frame(width: 6, height: 6)
                    .offset(x: -3)
                Rectangle()
                    .fill(Theme.now)
                    .frame(height: 1)
            }
            .offset(y: CGFloat(minutes) / 60 * Theme.hourHeight)
        }
    }
}
