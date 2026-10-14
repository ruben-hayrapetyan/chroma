import EventKit
import SwiftUI

/// The two toggles this copy of Chroma was built around, kept on the
/// `personal` branch rather than in the general app: the shared study-room
/// bookings, and the TA and advising drop-in hours. Each gets its own toolbar
/// button and shortcut instead of a place in a menu.
///
/// Both ride on the general machinery, so `main` merges in cleanly. Library
/// Rooms is an ordinary connected calendar, coloured Cobalt Violet; the TA
/// hours are whatever the filter in `categories.json` matches.
enum Personal {
    static let libraryCalendarTitle = "Library Rooms"

    /// Ignoring case and surrounding whitespace, since the title comes from
    /// whoever created the calendar on Google, not from this app.
    static func isLibrary(_ title: String) -> Bool {
        title.trimmingCharacters(in: .whitespaces).lowercased() == libraryCalendarTitle.lowercased()
    }
}

extension EventStore {
    /// The library calendar once it's connected.
    var libraryRooms: ExtraCalendar? {
        extraCalendars.first { Personal.isLibrary($0.ref.title) }
    }

    /// The library calendar on this Mac, connected or not.
    var libraryCalendar: EKCalendar? {
        calendarGroups().flatMap(\.calendars).first { Personal.isLibrary($0.title) }
    }

    var showsLibraryRooms: Bool { libraryRooms?.isShown == true }

    /// Shows or hides the bookings, connecting the calendar first if it isn't
    /// yet — the button should just work rather than send you to Settings.
    func toggleLibraryRooms() {
        if let extra = libraryRooms {
            setShown(extra.id, !extra.isShown)
        } else if let calendar = libraryCalendar {
            connect(calendar)
            if let id = libraryRooms?.id { setColor(id, "violet") }
        }
    }
}

/// The TA-hours and Library Rooms buttons, side by side in the toolbar.
struct PersonalToggles: View {
    @EnvironmentObject var store: EventStore
    @ObservedObject private var rules = RuleBook.shared

    var body: some View {
        // Shown only while categories.json defines the TA filter.
        if rules.rules.filter != nil {
            GlyphButton(
                systemName: store.showFilteredEvents ? "person.2.fill" : "person.2.slash.fill",
                help: store.showFilteredEvents
                    ? "Hide TA & advising hours (⇧⌘O)"
                    : "Show TA & advising hours (⇧⌘O)"
            ) {
                store.showFilteredEvents.toggle()
            }
        }

        // Says so in its tooltip when the calendar hasn't reached this Mac,
        // since otherwise switching it on would silently do nothing.
        GlyphButton(
            systemName: store.showsLibraryRooms ? "books.vertical.fill" : "books.vertical",
            help: store.libraryCalendar == nil
                ? "No \u{201C}\(Personal.libraryCalendarTitle)\u{201D} calendar on this Mac yet — enable it under your Google account in Calendar.app"
                : store.showsLibraryRooms
                    ? "Hide library rooms (⇧⌘L)"
                    : "Show library rooms (⇧⌘L)"
        ) {
            store.toggleLibraryRooms()
        }
    }
}
