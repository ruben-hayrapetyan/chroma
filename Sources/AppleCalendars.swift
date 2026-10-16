import EventKit
import SwiftUI

/// The calendars macOS syncs, through EventKit.
///
/// There is no syncing here in any real sense. The app talks to the same
/// EventKit database Calendar.app does, so an edit made anywhere — this app,
/// Calendar.app, or arriving from iCloud or Google — is the same object. All
/// this does is notice and say so.
@MainActor
final class AppleCalendars: CalendarProvider {
    var onChange: (() -> Void)?
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onChange?() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func requestAccess() async -> EventStore.Access {
        do {
            if try await store.requestFullAccessToEvents() { return .granted }
            return .denied(Self.deniedMessage)
        } catch {
            return .denied(error.localizedDescription)
        }
    }

    private static let deniedMessage =
        "Calendar access was denied. Grant it in System Settings › Privacy & Security › Calendars, then reopen the app."

    // MARK: - Calendars

    func calendars() -> [CalendarInfo] {
        store.calendars(for: .event).map(Self.info)
    }

    var defaultCalendarID: String? { store.defaultCalendarForNewEvents?.calendarIdentifier }

    private static func info(_ calendar: EKCalendar) -> CalendarInfo {
        CalendarInfo(id: calendar.calendarIdentifier,
                     title: calendar.title,
                     account: calendar.source?.title ?? "",
                     accountID: calendar.source?.sourceIdentifier ?? "",
                     color: Color(cgColor: calendar.cgColor),
                     isWritable: calendar.allowsContentModifications)
    }

    func refreshSources() { store.refreshSourcesIfNecessary() }

    // MARK: - Events

    func events(from start: Date, to end: Date, in calendars: [CalendarInfo]) -> [EventItem] {
        let wanted = calendars.compactMap { store.calendar(withIdentifier: $0.id) }
        guard !wanted.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: wanted)
        return store.events(matching: predicate).map { EventItem($0) }
    }

    func create(_ fields: EventFields, recurrence: EKRecurrenceRule?,
                in calendar: CalendarInfo) async throws -> String? {
        guard let target = store.calendar(withIdentifier: calendar.id) else {
            throw EventStore.StoreError.missingCalendar
        }
        let event = EKEvent(eventStore: store)
        event.calendar = target
        apply(fields, to: event)
        if let recurrence { event.recurrenceRules = [recurrence] }
        // A repeating event has to be saved across the series, not just the
        // first occurrence, or EventKit drops the rule.
        try store.save(event, span: recurrence == nil ? .thisEvent : .futureEvents, commit: true)
        return event.eventIdentifier
    }

    func update(_ item: EventItem, to fields: EventFields, recurrence: RecurrenceEdit,
                span: EKSpan) async throws -> String? {
        guard case .apple(let event) = item.origin else { return nil }
        apply(fields, to: event)
        switch recurrence {
        case .unchanged: break
        case .clear: event.recurrenceRules = nil
        case .set(let rule): event.recurrenceRules = [rule]
        }
        try store.save(event, span: span, commit: true)
        return event.eventIdentifier
    }

    func delete(_ item: EventItem, span: EKSpan) async throws {
        guard case .apple(let event) = item.origin else { return }
        try store.remove(event, span: span, commit: true)
    }

    private func apply(_ fields: EventFields, to event: EKEvent) {
        event.title = fields.title
        event.startDate = fields.start
        event.endDate = fields.end
        event.isAllDay = fields.isAllDay
        event.location = fields.location.isEmpty ? nil : fields.location
        event.notes = fields.notes.isEmpty ? nil : fields.notes
    }

    func seriesExists(_ item: EventItem) async -> Bool {
        store.event(withIdentifier: item.seriesID) != nil
    }

    /// EventKit hands back a distinct `EKEvent` per occurrence, and holding
    /// the right one is what makes a `.thisEvent` edit affect a single date
    /// instead of the whole series.
    func occurrence(of item: EventItem, on day: Date) async throws -> EventItem? {
        let calendar = Calendar.autoupdatingCurrent
        let from = calendar.startOfDay(for: day)
        guard let to = calendar.date(byAdding: .day, value: 1, to: from),
              let home = store.calendar(withIdentifier: item.calendarID) else { return nil }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [home])
        return store.events(matching: predicate)
            .first { $0.eventIdentifier == item.seriesID && calendar.isDate($0.startDate, inSameDayAs: day) }
            .map { EventItem($0) }
    }

    /// Falls back to looking the occurrence up again, for when an earlier step
    /// left the fetched copy unusable.
    func current(_ item: EventItem) async throws -> EventItem? {
        if case .apple(let event) = item.origin, event.refresh() {
            return EventItem(event)
        }
        return try await occurrence(of: item, on: item.start)
    }
}

extension EventItem {
    /// EventKit hands back a fresh `EKEvent` per occurrence of a repeating
    /// event, all sharing one `eventIdentifier` — the series.
    init(_ event: EKEvent) {
        self.init(seriesID: event.eventIdentifier ?? UUID().uuidString,
                  title: event.title ?? "",
                  start: event.startDate,
                  end: event.endDate,
                  isAllDay: event.isAllDay,
                  location: event.location ?? "",
                  notes: event.notes ?? "",
                  isRecurring: event.hasRecurrenceRules,
                  calendarID: event.calendar?.calendarIdentifier ?? "",
                  calendarTitle: event.calendar?.title ?? "",
                  isEditable: event.calendar?.allowsContentModifications ?? false,
                  origin: .apple(event))
    }
}
