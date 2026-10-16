import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Chroma › Settings: where the calendars come from, which one is home, which
/// others are drawn beside it, and where the category rules live.
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
    /// Where accounts are added for Apple Calendar, which shows what macOS
    /// already syncs.
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

    @State private var clientProblem: String?

    private var source: CalendarSource { store.source ?? .apple }

    var body: some View {
        let mainID = store.targetCalendar?.id
        let others = store.calendarGroups().compactMap { group -> CalendarGroup? in
            let rest = group.calendars.filter { $0.id != mainID }
            return rest.isEmpty ? nil : CalendarGroup(id: group.id, account: group.account, calendars: rest)
        }
        let missing = store.extraCalendars.filter { store.resolve($0.ref) == nil }

        Form {
            sourceSection

            Section {
                Picker("Main calendar", selection: mainSelection) {
                    if mainID == nil { Text("None").tag("") }
                    ForEach(store.calendarGroups(writableOnly: true)) { group in
                        Section(group.account) {
                            ForEach(group.calendars) { calendar in
                                Text(calendar.title).tag(calendar.id)
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
                    ForEach(group.calendars) { calendar in
                        row(calendar)
                    }
                }
            }

            if !missing.isEmpty {
                Section(source == .apple ? "Not on this Mac" : "Not in your Google account") {
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
                Button(source == .apple ? "Open Internet Accounts…" : "Open Google Calendar") {
                    CalendarChooser.addCalendars(for: source)
                }
            } footer: {
                Text(source == .apple
                     ? "Don't see a calendar? Add its account — iCloud, Google, Exchange, or any CalDAV server — in System Settings, and it appears here."
                     : "Don't see a calendar? Make it or subscribe to it in Google Calendar, and it appears here within a couple of minutes.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Source

    private var sourceSection: some View {
        Section {
            Picker("Calendars from", selection: Binding(get: { source }, set: { store.use($0) })) {
                ForEach(CalendarSource.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            if source == .google { googleAccount }
        } header: {
            Text("Source")
        } footer: {
            Text(source == .apple
                 ? "Every account this Mac syncs — iCloud, Google, Exchange, CalDAV — through macOS, the way Calendar.app sees them."
                 : "One Google account, straight from Google. Chroma checks for changes every couple of minutes, and whenever you switch back to it.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var googleAccount: some View {
        if !store.hasGoogleClient {
            LabeledContent("Google client") {
                Button("Choose Client File…", action: chooseClientFile)
            }
            Text("Google only lets an app reach your calendar through a client registered in Google Cloud. Make a Desktop client there, download its JSON, and choose it here — the README has the steps.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let clientProblem {
                Label(clientProblem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } else if store.access == .granted, let account = store.googleAccount {
            LabeledContent("Account") {
                HStack {
                    Text(account).textSelection(.enabled)
                    Button("Sign Out") { store.signOutOfGoogle() }
                }
            }
        } else {
            LabeledContent("Account") {
                if store.signingIn {
                    HStack {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { store.cancelGoogleSignIn() }
                    }
                } else {
                    Button("Sign In with Google…") { store.signInToGoogle() }
                }
            }
            if let problem = store.signInProblem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        if let problem = store.syncProblem {
            Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    private func chooseClientFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose the client JSON you downloaded from Google Cloud Console"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.installGoogleClient(from: url)
            clientProblem = nil
        } catch {
            clientProblem = error.localizedDescription
        }
    }

    private var mainSelection: Binding<String> {
        Binding(
            get: { store.targetCalendar?.id ?? "" },
            set: { id in
                let calendars = store.calendarGroups(writableOnly: true).flatMap(\.calendars)
                if let chosen = calendars.first(where: { $0.id == id }) {
                    store.useAsMain(chosen)
                }
            }
        )
    }

    private func row(_ calendar: CalendarInfo) -> some View {
        let extra = store.extraCalendars.first { $0.id == calendar.id }
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { extra != nil },
                set: { $0 ? store.connect(calendar) : store.disconnect(calendar.id) }
            )) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(calendar.color)
                        .frame(width: 8, height: 8)
                    Text(calendar.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !calendar.isWritable {
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
