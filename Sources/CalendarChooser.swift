import EventKit
import SwiftUI

/// One calendar as the picker shows it: its name, its colour, and what is on
/// it over the next month.
///
/// The contents are the point. A Google calendar is titled by an email
/// address, and an empty "Calendar" sitting beside it looks just as plausible —
/// what tells them apart is that one of them has your week on it.
struct ChooserCalendar: Identifiable {
    let id: String
    let title: String
    let color: Color
    let upcomingCount: Int
    let next: [ChooserEvent]
}

struct ChooserEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let isAllDay: Bool
}

struct ChooserSection: Identifiable {
    let id: String
    let account: String
    let calendars: [ChooserCalendar]
}

/// Stands in for the calendar until there is one to show: on first launch,
/// and if the chosen calendar disappears from this Mac.
struct CalendarChooser: View {
    @EnvironmentObject var store: EventStore
    @State private var sections: [ChooserSection] = []
    @State private var selection: String?

    var body: some View {
        CalendarChooserLayout(sections: sections,
                              selection: $selection,
                              missing: store.mainCalendar,
                              onChoose: choose,
                              onAddAccount: SystemSettings.openInternetAccounts)
            .onAppear(perform: refresh)
            // An account added in System Settings arrives as a store change.
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)
                .receive(on: DispatchQueue.main)) { _ in refresh() }
    }

    /// Fetched here rather than in the layout's body, which re-runs on every
    /// hover.
    private func refresh() {
        sections = store.calendarGroups(writableOnly: true).map { group in
            ChooserSection(id: group.id, account: group.account, calendars: group.calendars.map { calendar in
                let upcoming = store.upcoming(on: calendar)
                return ChooserCalendar(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    color: Color(cgColor: calendar.cgColor),
                    upcomingCount: upcoming.count,
                    next: upcoming.prefix(3).map {
                        ChooserEvent(id: $0.id, title: $0.title, start: $0.start, isAllDay: $0.isAllDay)
                    })
            })
        }
        // Start on the calendar macOS creates in by default — usually the right
        // answer, and never a surprise.
        let ids = sections.flatMap(\.calendars).map(\.id)
        if selection == nil || !ids.contains(selection!) {
            let preferred = store.systemDefaultCalendar?.calendarIdentifier
            selection = preferred.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        }
    }

    private func choose(_ id: String) {
        let calendars = store.calendarGroups(writableOnly: true).flatMap(\.calendars)
        if let chosen = calendars.first(where: { $0.calendarIdentifier == id }) {
            store.useAsMain(chosen)
        }
    }
}

/// The picker itself, apart from EventKit so it can be drawn from any data.
///
/// Set like the rest of the app: a serif heading, account names as eyebrows,
/// counts and times in monospace. Calendars wear their colour as a swatch;
/// the selected one opens to show its next few events as the chips they'll
/// be in the grid — a preview of the calendar you are about to get.
struct CalendarChooserLayout: View {
    let sections: [ChooserSection]
    @Binding var selection: String?
    /// The calendar that was in use, when it has disappeared. Nil on first launch.
    let missing: CalendarRef?
    let onChoose: (String) -> Void
    let onAddAccount: () -> Void

    @FocusState private var listFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var calendars: [ChooserCalendar] { sections.flatMap(\.calendars) }
    private var selected: ChooserCalendar? { calendars.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(heading)
                .font(Theme.display)
                .foregroundStyle(Theme.ink)
            Text(detail)
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.graphite)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            if sections.isEmpty {
                Button("Open Internet Accounts", action: onAddAccount)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 20)
            } else {
                list.padding(.top, 20)
                footer.padding(.top, 14)
            }
        }
        .frame(width: 452)
        // Optically centred: a hair above the middle reads as centred, the true
        // middle reads as sagging.
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
    }

    private var heading: String {
        if sections.isEmpty { return "Add a calendar account" }
        return missing == nil ? "Choose your main calendar" : "Choose a new main calendar"
    }

    private var detail: String {
        if sections.isEmpty {
            return "Chroma shows the calendars this Mac syncs, and none of them can take new events yet. Add an iCloud, Google, Exchange or CalDAV account in System Settings — it appears here as soon as it syncs."
        }
        if let missing {
            let account = missing.account.isEmpty ? "" : " on \(missing.account)"
            return "\u{201C}\(missing.title)\u{201D}\(account) isn't on this Mac any more. Choose another, or add its account back in System Settings."
        }
        return "New events go here, and it's the only calendar Claude can change. You can show others alongside it later, from Settings."
    }

    // MARK: - List

    private var list: some View {
        // Hugs its rows, and scrolls once there are more than fit comfortably
        // above the button.
        Group {
            if calendars.count > 8 {
                ScrollViewReader { proxy in
                    ScrollView { rows }
                        .frame(height: 400)
                        .onChange(of: selection) { _, id in
                            guard let id else { return }
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { proxy.scrollTo(id) }
                        }
                }
            } else {
                rows
            }
        }
        .card()
        .focusable()
        .focused($listFocused)
        // The selection ring is the focus indicator; the system ring around
        // the whole card would just restate it.
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onAppear { listFocused = true }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(height: 1)
                        .padding(.vertical, 6)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(section.account.uppercased())
                        .font(Theme.eyebrow)
                        .foregroundStyle(Theme.graphite)
                        .lineLimit(1)
                    Spacer()
                    // A column heading, once, for the counts down the right.
                    if index == 0 {
                        Text("NEXT 30 DAYS")
                            .font(Theme.eyebrow)
                            .foregroundStyle(Theme.faint)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 3)

                ForEach(section.calendars) { calendar in
                    ChooserRow(calendar: calendar, isSelected: calendar.id == selection)
                        .id(calendar.id)
                        .onTapGesture { select(calendar.id) }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { onChoose(calendar.id) })
                }
            }
        }
        .padding(8)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: onAddAccount) {
                Text("Open Internet Accounts")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.graphite)
                    .underline(color: Theme.rule)
            }
            .buttonStyle(.plain)
            .help("Add an iCloud, Google, Exchange or CalDAV account in System Settings")

            Spacer(minLength: 12)

            Button {
                if let selection { onChoose(selection) }
            } label: {
                Text(selected.map { "Use \u{201C}\($0.title)\u{201D}" } ?? "Use This Calendar")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(selected == nil)
        }
    }

    private func select(_ id: String) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { selection = id }
        listFocused = true
    }

    private func move(_ step: Int) {
        let ids = calendars.map(\.id)
        guard !ids.isEmpty else { return }
        let current = selection.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
        select(ids[min(max(current + step, 0), ids.count - 1)])
    }
}

/// A calendar in the picker. Its colour is a swatch, not a spine: the spine
/// is how the app draws an event, and it's kept for the events in the preview.
private struct ChooserRow: View {
    let calendar: ChooserCalendar
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(calendar.color)
                    .frame(width: 11, height: 11)
                Text(calendar.title)
                    .font(Theme.ui(13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Text(calendar.upcomingCount == 0 ? "—" : "\(calendar.upcomingCount)")
                    .font(Theme.time(11))
                    .foregroundStyle(calendar.upcomingCount == 0 ? Theme.faint : Theme.graphite)
            }
            .frame(height: 32)

            if isSelected {
                preview
                    .padding(.leading, 20)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Theme.wash : hovering ? Theme.outsideMonth : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.ink.opacity(isSelected ? 0.55 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 3) {
            if calendar.next.isEmpty {
                Text("Nothing in the next 30 days.")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.faint)
            } else {
                ForEach(Array(calendar.next.enumerated()), id: \.element.id) { index, event in
                    // The date only where it changes, the way a timetable
                    // lists a day once and its sessions under it.
                    let sameDay = index > 0 && Calendar.current.isDate(
                        calendar.next[index - 1].start, inSameDayAs: event.start)
                    chip(event, showsDay: !sameDay)
                }
                let more = calendar.upcomingCount - calendar.next.count
                if more > 0 {
                    Text("and \(more) more")
                        .font(Theme.time(9.5))
                        .foregroundStyle(Theme.faint)
                        .padding(.leading, 9)
                        .padding(.top, 1)
                }
            }
        }
    }

    /// The month grid's chip, with the date spelled out: pale pigment, solid
    /// spine, monospaced time.
    private func chip(_ event: ChooserEvent, showsDay: Bool) -> some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(calendar.color)
                .frame(width: Theme.spine)
            Text(showsDay ? Self.day.string(from: event.start) : "")
                .font(Theme.time(9.5))
                .foregroundStyle(Theme.graphite)
                .frame(width: 74, alignment: .leading)
            Text(event.isAllDay ? "all day" : Self.clock.string(from: event.start))
                .font(Theme.time(9.5))
                .foregroundStyle(Theme.graphite)
                .frame(width: 52, alignment: .leading)
            Text(event.title)
                .font(Theme.ui(11, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 20)
        .background(calendar.color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous))
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter
    }()

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}
