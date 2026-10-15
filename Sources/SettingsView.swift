import AppKit
import EventKit
import SwiftUI

/// Chroma › Settings: which calendar is home, which others are drawn beside
/// it, and where the category rules live.
struct SettingsView: View {
    var body: some View {
        TabView {
            CalendarSettings()
                .tabItem { Label("Calendars", systemImage: "calendar") }
            CategorySettings()
                .tabItem { Label("Categories", systemImage: "paintpalette") }
        }
        .frame(width: 520, height: 560)
    }
}

enum SystemSettings {
    /// Where calendar accounts are added. Chroma never signs in to anything
    /// itself — it shows what macOS already syncs.
    static func openInternetAccounts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Calendars

struct CalendarSettings: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var colors: EventColors

    var body: some View {
        let mainID = store.targetCalendar?.calendarIdentifier
        let others = store.calendarGroups().compactMap { group -> CalendarGroup? in
            let rest = group.calendars.filter { $0.calendarIdentifier != mainID }
            return rest.isEmpty ? nil : CalendarGroup(id: group.id, account: group.account, calendars: rest)
        }
        let missing = store.extraCalendars.filter { store.resolve($0.ref) == nil }

        Form {
            Section {
                Picker("Main calendar", selection: mainSelection) {
                    if mainID == nil { Text("None").tag("") }
                    ForEach(store.calendarGroups(writableOnly: true)) { group in
                        Section(group.account) {
                            ForEach(group.calendars, id: \.calendarIdentifier) { calendar in
                                Text(calendar.title).tag(calendar.calendarIdentifier)
                            }
                        }
                    }
                }
            } footer: {
                Text("New events go here, and it's the only calendar Claude can change.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Tick a calendar to draw it alongside the main one. Switch each on and off from the stack button in the toolbar or the View menu — or give it a toolbar button of its own. Give one a colour to paint every event on it, ahead of the category rules.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Other calendars")
            }

            ForEach(others) { group in
                Section(group.account) {
                    ForEach(group.calendars, id: \.calendarIdentifier) { calendar in
                        row(calendar)
                    }
                }
            }

            if !missing.isEmpty {
                Section("Not on this Mac") {
                    ForEach(missing) { extra in
                        HStack {
                            Text(extra.ref.title)
                            Text(extra.ref.account).foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove") { store.disconnect(extra.id) }
                        }
                    }
                }
            }

            Section {
                Button("Open Internet Accounts…", action: SystemSettings.openInternetAccounts)
            } footer: {
                Text("Don't see a calendar? Add its account — iCloud, Google, Exchange, or any CalDAV server — in System Settings, and it appears here.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var mainSelection: Binding<String> {
        Binding(
            get: { store.targetCalendar?.calendarIdentifier ?? "" },
            set: { id in
                let calendars = store.calendarGroups(writableOnly: true).flatMap(\.calendars)
                if let chosen = calendars.first(where: { $0.calendarIdentifier == id }) {
                    store.useAsMain(chosen)
                }
            }
        )
    }

    private func row(_ calendar: EKCalendar) -> some View {
        let extra = store.extraCalendars.first { $0.id == calendar.calendarIdentifier }
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { extra != nil },
                set: { $0 ? store.connect(calendar) : store.disconnect(calendar.calendarIdentifier) }
            )) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color(cgColor: calendar.cgColor))
                        .frame(width: 8, height: 8)
                    Text(calendar.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !calendar.allowsContentModifications {
                        Text("Read-only")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)

            Spacer()

            if let extra {
                // Library Rooms always has its own button, so the switch
                // would do nothing for it.
                if !Personal.isLibrary(calendar.title) {
                    Toggle("Toolbar button", isOn: Binding(
                        get: { extra.inToolbar },
                        set: { store.setInToolbar(extra.id, $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .help("Give \(calendar.title) its own show/hide button in the toolbar")
                }

                Picker("Colour", selection: Binding(
                    get: { extra.colorID ?? "" },
                    set: { setColor(extra, $0.isEmpty ? nil : $0) }
                )) {
                    Text("Category colours").tag("")
                    Divider()
                    ForEach(EventColor.palette) { pigment in
                        Text(pigment.name).tag(pigment.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    /// A calendar-wide colour is applied to everything on the calendar at once,
    /// shown or not, rather than waiting for the categoriser to come across it.
    private func setColor(_ extra: ExtraCalendar, _ colorID: String?) {
        store.setColor(extra.id, colorID)
        guard let updated = store.extraCalendars.first(where: { $0.id == extra.id }) else { return }
        Categories.recolor(store.allItems(on: updated), colors: colors)
    }
}

// MARK: - Categories

struct CategorySettings: View {
    @ObservedObject private var rules = RuleBook.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("File") {
                    Text(displayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Open", action: openFile)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([rules.fileURL])
                    }
                    Spacer()
                    Button("Reload") { rules.reload() }
                }
            } header: {
                Text("Rules")
            } footer: {
                status
            }

            Section("How they work") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Each event takes the first category whose pattern matches its title. Patterns are regular expressions, matched ignoring case — and in JSON a backslash is written twice, so a word boundary is \\\\b.")
                    Text("Colours: \(EventColor.catalogue).")
                    Text("An optional \"filter\" — a label, a pattern, and categories it never hides — puts matching events behind the eye button in the toolbar.")
                    Text("Edits apply when you switch back to Chroma. New rules colour events that have no colour yet; Organize › Assign Categories to Everything recolours the rest.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { rules.reloadIfChanged() }
    }

    @ViewBuilder
    private var status: some View {
        if let problem = rules.problem {
            VStack(alignment: .leading, spacing: 3) {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Still using the last rules that loaded.")
                    .foregroundStyle(.secondary)
            }
        } else {
            let count = rules.rules.categories.count
            let filter = rules.rules.filter.map { " · hides \u{201C}\($0.label)\u{201D} behind the eye button" } ?? ""
            Text("\(count) rule\(count == 1 ? "" : "s")\(filter)")
                .foregroundStyle(.secondary)
        }
    }

    private var displayPath: String {
        rules.fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// In whatever opens JSON on this Mac, or TextEdit when nothing does.
    private func openFile() {
        let url = rules.fileURL
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            NSWorkspace.shared.open([url], withApplicationAt: textEdit,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
