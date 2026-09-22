import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Carries "do this" from the menu bar and the global hotkeys into the view.
///
/// Both fire outside the view hierarchy, so they set a flag here and the view
/// reacts, rather than trying to reach in and call a method.
@MainActor
final class Intents: ObservableObject {
    @Published var newEventRequested = false
    @Published var claudeRequested = false
    @Published var searchRequested = false
    @Published var categorizeRequested = false

    /// The event being drafted, if any. The highlighted box in the grid and the
    /// form in the right-hand pane are two views of this one value, which is why
    /// it lives up here rather than inside either of them.
    @Published var draft: DraftEvent?
}

/// An event that does not exist yet.
struct DraftEvent: Equatable {
    var start: Date
    var end: Date
    var title: String = ""
    var location: String = ""
    var notes: String = ""
    var isAllDay: Bool = false
    var colorID: String?
    var recurrence = RecurrenceDraft()

    /// The default block: one hour from `start`.
    static func hour(at start: Date) -> DraftEvent {
        DraftEvent(start: start, end: start.addingTimeInterval(3600))
    }

    /// Where a new event should land on a given day when no time was clicked —
    /// the next whole hour today, 9am on any other day.
    static func defaultStart(on day: Date, calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = calendar.isDateInToday(day)
            ? min(calendar.component(.hour, from: Date()) + 1, 22)
            : 9
        components.minute = 0
        return calendar.date(from: components) ?? day
    }
}

@main
struct ChromaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = EventStore()
    @StateObject private var colors = EventColors()
    @StateObject private var intents = Intents()

    var body: some Scene {
        WindowGroup("Calendar") {
            ContentView()
                .environmentObject(store)
                .environmentObject(colors)
                .environmentObject(intents)
                .onAppear { appDelegate.bind(intents: intents) }
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Event") { intents.newEventRequested = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Ask Claude…") { intents.claudeRequested = true }
                    .keyboardShortcut(.space, modifiers: .control)
            }
            CommandGroup(after: .textEditing) {
                Button("Find Event…") { intents.searchRequested = true }
                    .keyboardShortcut("f", modifiers: .command)
            }
            CommandMenu("Organize") {
                Button("Assign Categories to Everything…") { intents.categorizeRequested = true }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            }
            CommandMenu("View") {
                ForEach(ViewMode.allCases) { mode in
                    Button(mode.title) { store.mode = mode }
                        .keyboardShortcut(mode.shortcut, modifiers: .command)
                }
                Divider()
                Toggle("Show TA & Advising Hours", isOn: $store.showSupportingOfficeHours)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Today") { store.goToToday() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Previous") { store.step(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Next") { store.step(1) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var newEventHotKey: GlobalHotKey?
    private var claudeHotKey: GlobalHotKey?
    private var bound = false

    /// Registered once the window exists, since both shortcuts act on its state.
    @MainActor
    func bind(intents: Intents) {
        guard !bound else { return }
        bound = true

        // Both bring the app forward first: a popup behind another window would
        // be worse than no popup at all.
        //
        // Modifier+Space rather than ⌥⌘+letter: it is a one-hand, thumb-to-thumb
        // press, and it avoids stealing a letter combination from every app on
        // the machine. Raycast holds ⇧⌘Space and Spotlight ⌘Space, so both of
        // these are clear.
        claudeHotKey = GlobalHotKey(keyCode: UInt32(kVK_Space),
                                    modifiers: UInt32(controlKey)) { [weak intents] in
            NSApp.activate(ignoringOtherApps: true)
            intents?.claudeRequested = true
        }

        newEventHotKey = GlobalHotKey(keyCode: UInt32(kVK_Space),
                                      modifiers: UInt32(optionKey)) { [weak intents] in
            NSApp.activate(ignoringOtherApps: true)
            intents?.newEventRequested = true
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
