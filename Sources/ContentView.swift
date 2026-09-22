import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var colors: EventColors
    @EnvironmentObject var intents: Intents

    @State private var askingClaude = false

    /// Whether the inspector is in edit mode. Double-clicking an event opens it
    /// straight in this state.
    @State private var editingSelection = false
    @State private var categoryReport: String?
    @State private var didSeedCategories = false

    /// The inspected event, held by id rather than by value. Reloads replace
    /// every `EventItem`, so an id survives an edit arriving from Calendar.app
    /// and quietly clears itself if the event is deleted elsewhere.
    @State private var selectedID: String?

    private var selectedItem: EventItem? {
        guard let selectedID else { return nil }
        if let exact = store.items.first(where: { $0.id == selectedID }) { return exact }
        // The id encodes the occurrence's start time, so saving a new time
        // changes it. Fall back to the series so the pane survives its own edit.
        let series = String(selectedID.prefix { $0 != "@" })
        return store.items.first { $0.seriesID == series }
    }

    var body: some View {
        // Split across three properties on purpose: chained far enough in one
        // expression, SwiftUI's type-checker gives up and reports nothing
        // useful. Each layer is small enough to infer on its own.
        shell
            .sheet(isPresented: $askingClaude) {
                ClaudePanel()
                    .environmentObject(store)
                    .environmentObject(colors)
            }
            .alert("Categories assigned", isPresented: .constant(categoryReport != nil)) {
                Button("Done") { categoryReport = nil }
            } message: {
                Text(categoryReport ?? "")
            }
    }

    private var shell: some View {
        stage
            .frame(minWidth: 820, minHeight: 560)
            .background(Theme.paper)
            .onChange(of: intents.newEventRequested) { _, requested in
                guard requested else { return }
                intents.newEventRequested = false
                // ⌥Space while the Claude popup is up closes it and does nothing
                // else — reaching for the other hotkey reads as "not this one",
                // and a draft appearing behind the closing sheet would be a surprise.
                if askingClaude {
                    askingClaude = false
                    return
                }
                beginDraft(on: store.selectedDay)
            }
            .onChange(of: intents.claudeRequested) { _, requested in
                guard requested else { return }
                intents.claudeRequested = false
                askingClaude = true
            }
            .onChange(of: intents.categorizeRequested) { _, requested in
                guard requested else { return }
                intents.categorizeRequested = false
                categorizeEverything()
            }
            .onChange(of: store.revision) { _, _ in
                categorizeNewArrivals()
            }
            // Access is granted asynchronously, and on an already-authorised
            // launch the first reload can land before this view is listening —
            // so the seeding pass has to be reachable from the access change
            // too, or a launch silently skips it.
            .onChange(of: store.access) { _, _ in
                categorizeNewArrivals()
            }
            .task {
                categorizeNewArrivals()
            }
    }

    /// The menu command. Asked for explicitly, so it overwrites choices made by
    /// hand as well.
    private func categorizeEverything() {
        categoryReport = Categories.apply(store.allKnownItems(), colors: colors,
                                          overwritingManual: true).summary
    }

    /// Runs on every reload, over the whole calendar rather than the visible
    /// span.
    ///
    /// It used to categorise only what was on screen, which meant an event
    /// arriving outside the current view stayed uncoloured until something else
    /// happened to trigger a full pass — a silent gap that bit twice. Anything
    /// already coloured is skipped, so the repeated work is just the fetch.
    private func categorizeNewArrivals() {
        guard store.access == .granted else { return }
        didSeedCategories = true
        Categories.apply(store.allKnownItems(), colors: colors)
    }

    @ViewBuilder
    private var stage: some View {
        switch store.access {
        case .pending:
            notice("Waiting for calendar access",
                   detail: "macOS should be asking permission right about now.",
                   symbol: "hourglass")
        case .denied(let reason):
            notice("No calendar access", detail: reason, symbol: "lock.fill")
        case .granted where store.targetCalendar == nil:
            notice("Can't find the calendar",
                   detail: "No calendar named \"\(targetCalendarTitle)\" exists in your account. If you renamed it, either rename it back or change targetCalendarTitle in EventStore.swift.",
                   symbol: "questionmark.folder")
        case .granted:
            main
        }
    }

    private var main: some View {
        GeometryReader { geo in
            // Wide, the inspector takes its own column. Narrow, it floats over
            // the grid instead — at these widths a third column would leave the
            // calendar itself too thin to read, which is the whole point of it.
            let overlays = geo.size.width < 1020

            HStack(spacing: 0) {
                Sidebar(onNewEvent: { beginDraft(on: store.selectedDay) },
                        onAskClaude: { askingClaude = true },
                        onOpen: select,
                        onEdit: edit)
                    .frame(width: Theme.sidebarWidth)
                    .background(Theme.recessed)

                Divider().foregroundStyle(Theme.rule)

                VStack(spacing: 0) {
                    toolbar
                    content
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                }

                if !overlays, hasPane {
                    Divider().foregroundStyle(Theme.rule)
                    rightPane
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay(alignment: .trailing) {
                if overlays, hasPane {
                    rightPane
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius,
                                                    style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                                .strokeBorder(Theme.rule, lineWidth: 0.5)
                        )
                        .shadow(color: Theme.lift, radius: Theme.liftRadius, x: -3, y: 2)
                        .padding(.vertical, 10)
                        .padding(.trailing, 10)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    private var hasPane: Bool {
        intents.draft != nil || selectedItem != nil
    }

    @ViewBuilder
    private var rightPane: some View {
        if intents.draft != nil {
            NewEventPane(draft: $intents.draft, onClose: closeDraft)
        } else if let item = selectedItem {
            DetailPane(item: item,
                       isEditing: $editingSelection,
                       onClose: { withAnimation(.snappy(duration: 0.2)) {
                           selectedID = nil
                           editingSelection = false
                       } })
        }
    }

    /// Clicking an event reveals it in the inspector; editing is a step further,
    /// behind the pane's Edit button.
    private func select(_ item: EventItem) {
        withAnimation(.snappy(duration: 0.2)) {
            intents.draft = nil
            selectedID = item.id
            editingSelection = false
        }
    }

    /// Double-clicking an event goes straight to editing it.
    private func edit(_ item: EventItem) {
        withAnimation(.snappy(duration: 0.2)) {
            intents.draft = nil
            selectedID = item.id
            editingSelection = true
        }
    }

    /// Start a draft on a day with no particular time in mind — the sidebar
    /// button, ⌘N, and the month grid's + all land here.
    private func beginDraft(on day: Date) {
        withAnimation(.snappy(duration: 0.2)) {
            selectedID = nil
            intents.draft = .hour(at: DraftEvent.defaultStart(on: day, calendar: store.calendar))
        }
    }

    private func closeDraft() {
        withAnimation(.snappy(duration: 0.2)) { intents.draft = nil }
    }

    @ViewBuilder
    private var content: some View {
        let add: (Date) -> Void = beginDraft

        switch store.mode {
        case .day, .week:
            TimeGridView(onOpen: select, onEdit: edit, onAdd: add)
        case .month:
            MonthView(onOpen: select, onEdit: edit, onAdd: add)
        case .year:
            YearView()
        }
    }

    /// The toolbar sits inside the middle column, so its width is the window
    /// minus the sidebar and, when open, the inspector. Rather than let the
    /// controls compress into each other, they shed detail in stages: the
    /// heading gives up its fixed width, Today drops to an icon, and the mode
    /// picker collapses from a segmented pill into a pull-down.
    private var toolbar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let pinsHeading = width >= 630
            let showsSegmented = width >= 470
            let showsTodayLabel = width >= 390

            HStack(spacing: 10) {
                heading(pinned: pinsHeading)

                HStack(spacing: 4) {
                    GlyphButton(systemName: "chevron.left", help: "Previous") { store.step(-1) }
                    GlyphButton(systemName: "chevron.right", help: "Next") { store.step(1) }
                }

                todayButton(labelled: showsTodayLabel)

                supportHoursButton

                Spacer(minLength: 8)

                if showsSegmented {
                    ModePicker(selection: Binding(get: { store.mode },
                                                  set: { store.mode = $0 }))
                } else {
                    modeMenu
                }
            }
            .padding(.horizontal, 18)
            .frame(height: geo.size.height)
        }
        .frame(height: 58)
    }

    /// Shows or hides the TA, GTA and advising drop-in sessions. In the toolbar
    /// rather than only in the View menu because it is the one setting worth
    /// flipping several times a day, depending on whether you are looking for
    /// help or looking at your week.
    private var supportHoursButton: some View {
        GlyphButton(
            systemName: store.showSupportingOfficeHours
                ? "person.2.fill" : "person.2.slash.fill",
            help: store.showSupportingOfficeHours
                ? "Hide TA & advising hours (⇧⌘O)"
                : "Show TA & advising hours (⇧⌘O)"
        ) {
            store.showSupportingOfficeHours.toggle()
        }
    }

    private func heading(pinned: Bool) -> some View {
        // Pinned, the label reserves the width of the longest string any mode
        // produces so the chevrons never move. Cramped, it yields that space
        // instead of pushing the controls off the edge.
        Text(store.heading)
            .font(Theme.display)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.2), value: store.heading)
            .frame(width: pinned ? 334 : nil,
                   alignment: .leading)
            .layoutPriority(pinned ? 0 : 1)
    }

    private func todayButton(labelled: Bool) -> some View {
        Button { store.goToToday() } label: {
            Group {
                if labelled {
                    Text("Today").font(.system(size: 12, weight: .medium))
                } else {
                    Image(systemName: "smallcircle.filled.circle")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, labelled ? 11 : 7)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.rule, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Today")
    }

    /// The segmented control's stand-in when the toolbar is narrow.
    private var modeMenu: some View {
        Menu {
            ForEach(ViewMode.allCases) { mode in
                Button {
                    withAnimation(.snappy(duration: 0.22)) { store.mode = mode }
                } label: {
                    if store.mode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(store.mode.title)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Theme.panel)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.accent)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func notice(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.faint)
            Text(title).font(Theme.paneTitle).foregroundStyle(Theme.ink)
            Text(detail)
                .font(Theme.ui(12))
                .foregroundStyle(Theme.graphite)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// Search, quick actions, mini month, and the selected day's agenda.
struct Sidebar: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var colors: EventColors
    @EnvironmentObject var intents: Intents

    let onNewEvent: () -> Void
    let onAskClaude: () -> Void
    let onOpen: (EventItem) -> Void
    let onEdit: (EventItem) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The wordmark, set in the serif that carries the rest of the app.
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("Chroma")
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.ink)
                Text(calendarDisplayName.uppercased())
                    .font(Theme.eyebrow)
                    .foregroundStyle(Theme.faint)
                Spacer()
            }
            .padding(.top, 16)

            searchField

            // While searching, results take over the sidebar: the mini month and
            // the day's agenda are about a date, and a search is not.
            if isSearching {
                results
            } else {
                VStack(spacing: 7) {
                    actionButton("New Event", symbol: "plus", prominent: true, action: onNewEvent)
                    actionButton("Ask Claude", symbol: "sparkles", prominent: false, action: onAskClaude)
                }

                MiniMonth(month: store.anchor,
                          titleStyle: .full,
                          dayDiameter: 26,
                          onSelectDay: { store.focus(on: $0) },
                          onSelectMonth: { store.focus(on: $0, switchingTo: .month) })

                Divider().foregroundStyle(Theme.rule)

                agenda
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .onChange(of: intents.searchRequested) { _, requested in
            guard requested else { return }
            intents.searchRequested = false
            searchFocused = true
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.graphite)
            TextField("Search events", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.panel.opacity(searchFocused ? 1 : 0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(searchFocused ? Theme.accent : Theme.rule,
                              lineWidth: searchFocused ? 1 : 0.5)
        )
    }

    private var results: some View {
        let hits = store.search(query)
        return VStack(alignment: .leading, spacing: 8) {
            Text(hits.isEmpty ? "NO MATCHES"
                              : "\(hits.count) RESULT\(hits.count == 1 ? "" : "S")")
                .font(Theme.eyebrow)
                .foregroundStyle(Theme.graphite)

            if hits.isEmpty {
                Text("Nothing on this calendar matches \u{201C}\(query)\u{201D}.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(hits) { item in
                            SearchResultRow(item: item)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    store.focus(on: item.start)
                                    onEdit(item)
                                }
                                .onTapGesture {
                                    // Take the view to the match, then select it.
                                    store.focus(on: item.start)
                                    onOpen(item)
                                }
                                .contextMenu { ColorMenu(item: item, onOpen: onOpen, onEdit: onEdit) }
                        }
                    }
                }
            }
        }
    }

    private func actionButton(_ title: String, symbol: String,
                              prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .foregroundStyle(prominent ? Theme.panel : Theme.ink)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? Theme.accent : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(prominent ? Color.clear : Theme.rule, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var agenda: some View {
        let items = store.items(on: store.selectedDay)
        return VStack(alignment: .leading, spacing: 8) {
            Text(agendaTitle.uppercased())
                .font(Theme.eyebrow)
                .foregroundStyle(Theme.graphite)

            if items.isEmpty {
                Text("Nothing scheduled. Double-click any hour to add something.")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(items) { item in
                            AgendaRow(item: item)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { onEdit(item) }
                                .onTapGesture { onOpen(item) }
                                .contextMenu { ColorMenu(item: item, onOpen: onOpen, onEdit: onEdit) }
                        }
                    }
                }
            }
        }
    }

    private var agendaTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: store.selectedDay)
    }
}

/// A search hit: the same shape as an agenda row, but dated, since a result can
/// be from any year.
struct SearchResultRow: View {
    @EnvironmentObject var colors: EventColors
    let item: EventItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(colors.color(for: item.seriesID))
                .frame(width: Theme.spine)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Theme.ui(12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(dateLabel)
                        .font(Theme.time(9.5))
                        .foregroundStyle(Theme.graphite)
                    if item.isRecurring {
                        Image(systemName: "repeat")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.faint)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var dateLabel: String {
        let formatter = DateFormatter()
        // Only spell the year out when it is not the current one.
        let sameYear = Calendar.current.isDate(item.start, equalTo: Date(), toGranularity: .year)
        formatter.dateFormat = item.isAllDay
            ? (sameYear ? "EEE, MMM d" : "MMM d, yyyy")
            : (sameYear ? "EEE, MMM d · h:mm a" : "MMM d, yyyy · h:mm a")
        return formatter.string(from: item.start)
    }
}

struct AgendaRow: View {
    @EnvironmentObject var colors: EventColors
    let item: EventItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(colors.color(for: item.seriesID))
                .frame(width: Theme.spine)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Theme.ui(12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Text(timeLabel)
                    .font(Theme.time(9.5))
                    .foregroundStyle(Theme.graphite)
                if !item.location.isEmpty {
                    Text(item.location)
                        .font(Theme.ui(10))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var timeLabel: String {
        if item.isAllDay { return "All day" }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "\(formatter.string(from: item.start)) – \(formatter.string(from: item.end))"
    }
}
