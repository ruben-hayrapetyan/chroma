import EventKit
import SwiftUI

/// Where Chroma reads its calendars from, picked on first launch and changeable
/// in Settings.
enum CalendarSource: String, CaseIterable, Identifiable {
    /// The calendars macOS syncs — iCloud, Google, Exchange, CalDAV — through
    /// EventKit, the same database Calendar.app uses.
    case apple
    /// One Google account, straight from Google's Calendar API.
    case google

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple Calendar"
        case .google: return "Google Calendar"
        }
    }
}

/// A calendar as the pickers and Settings see it, whichever source it came
/// from.
struct CalendarInfo: Identifiable, Equatable {
    let id: String
    let title: String
    /// The account as it's shown: "iCloud", an email address.
    let account: String
    /// What keeps two accounts apart when both are titled "Google".
    let accountID: String
    let color: Color
    /// False for subscriptions, holiday calendars, and anything shared
    /// read-only.
    let isWritable: Bool
}

/// The parts of an event Chroma edits.
struct EventFields {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String
    var notes: String
}

/// What a source has to do for the rest of the app. Everything above this —
/// the grids, search, colours, Ask Claude — works on `EventItem`s and never
/// knows which source is behind them.
///
/// Reads are synchronous because the views ask for them while drawing. EventKit
/// answers from its database; Google answers from what it last fetched,
/// fetches what it's missing, and calls `onChange` when that arrives. Changes
/// are async, since Google's go over the network.
@MainActor
protocol CalendarProvider: AnyObject {
    /// Called when events or calendars change underneath the app: an edit in
    /// Calendar.app, another device, a background check with Google.
    var onChange: (() -> Void)? { get set }

    func requestAccess() async -> EventStore.Access
    func calendars() -> [CalendarInfo]
    /// Where new events go unless told otherwise, to preselect the picker.
    var defaultCalendarID: String? { get }

    func events(from start: Date, to end: Date, in calendars: [CalendarInfo]) -> [EventItem]

    /// Returns the new event's series identifier.
    func create(_ fields: EventFields, recurrence: EKRecurrenceRule?,
                in calendar: CalendarInfo) async throws -> String?
    /// Returns the series identifier after the save, which is new when a
    /// change from partway through a series splits it in two.
    func update(_ item: EventItem, to fields: EventFields, recurrence: RecurrenceEdit,
                span: EKSpan) async throws -> String?
    func delete(_ item: EventItem, span: EKSpan) async throws

    /// Whether any of the item's series is left. Unsure counts as yes.
    func seriesExists(_ item: EventItem) async -> Bool
    /// The occurrence of the item's series on a given day, read fresh. Nil
    /// when there's none; throws when the calendar couldn't be asked.
    func occurrence(of item: EventItem, on day: Date) async throws -> EventItem?
    /// The item as the calendar has it now, or nil once it's gone. Throws
    /// when the calendar couldn't be asked, which isn't the same as gone.
    func current(_ item: EventItem) async throws -> EventItem?

    /// Nudges the accounts to sync, for a calendar that's expected but missing.
    func refreshSources()
}
