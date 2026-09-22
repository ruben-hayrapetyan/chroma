import Combine
import EventKit
import Foundation

/// The single calendar this app reads and writes.
///
/// Deliberately narrow: a focused window onto the iCloud calendar named
/// "Calendar", not a general calendar client. Everything else in the account is
/// left alone. The actual title lives in `Sources/LocalConfig.swift`, which is
/// git-ignored — see `LocalConfig.swift.example`.
let targetCalendarTitle = localCalendarTitle ?? "Calendar"

/// What the sidebar calls it. The calendar's real title is an email address,
/// which is precise and useless as a label.
let calendarDisplayName = "Google" 

/// One occurrence of an event, flattened for display.
///
/// EventKit hands back a fresh `EKEvent` per occurrence of a repeating event,
/// all sharing one `eventIdentifier`. SwiftUI needs per-row identity, so `id`
/// pins the occurrence while `seriesID` stays stable across the series — which
/// is what per-event colour is keyed on.
struct EventItem: Identifiable {
    let id: String
    let seriesID: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String
    let notes: String
    let isRecurring: Bool
    let ekEvent: EKEvent

    init(_ event: EKEvent) {
        let series = event.eventIdentifier ?? UUID().uuidString
        self.seriesID = series
        self.id = series + "@" + String(event.startDate.timeIntervalSinceReferenceDate)
        self.title = (event.title?.isEmpty == false) ? event.title! : "(no title)"
        self.start = event.startDate
        self.end = event.endDate
        self.isAllDay = event.isAllDay
        self.location = event.location ?? ""
        self.notes = event.notes ?? ""
        self.isRecurring = event.hasRecurrenceRules
        self.ekEvent = event
    }

    /// Minutes from midnight, used to place the block in the day and week grids.
    func minutesFromMidnight(in calendar: Calendar) -> Double {
        let startOfDay = calendar.startOfDay(for: start)
        return start.timeIntervalSince(startOfDay) / 60
    }

    var durationMinutes: Double {
        max(end.timeIntervalSince(start) / 60, 15)   // never thinner than 15 min
    }
}

/// Owns the EventKit connection and republishes what the current view needs.
///
/// There is no syncing here in any real sense. The app talks to the same
/// EventKit database Calendar.app does, so an edit made anywhere — this app,
/// Calendar.app, or arriving from iCloud — is the same object. All this class
/// does is notice and reload.
@MainActor
final class EventStore: ObservableObject {
    enum Access: Equatable {
        case pending
        case granted
        case denied(String)
    }

    @Published private(set) var access: Access = .pending
    @Published private(set) var items: [EventItem] = []

    /// Events bucketed by the day they appear on, rebuilt with every reload.
    ///
    /// The year view asks 504 cells whether they are busy and the month view
    /// asks 42 cells for their contents; scanning the whole array each time is
    /// what made switching to Year crawl.
    @Published private(set) var itemsByDay: [Date: [EventItem]] = [:]

    /// Bumped on every reload. The categoriser watches this so events arriving
    /// from anywhere — Claude, Calendar.app, another device — get a pigment
    /// without anyone asking.
    @Published private(set) var revision = 0
    /// Whether the TA and GTA office hours are drawn at all.
    ///
    /// Off by default: they outnumber everything else on a weekday and turn the
    /// grid into a wall of green. The professors' own hours are never part of
    /// this — they are the ones worth seeing.
    @Published var showSupportingOfficeHours: Bool = UserDefaults.standard
        .bool(forKey: "showSupportingOfficeHours") {
        didSet {
            guard oldValue != showSupportingOfficeHours else { return }
            UserDefaults.standard.set(showSupportingOfficeHours,
                                      forKey: "showSupportingOfficeHours")
            reload()
        }
    }

    @Published var anchor: Date = Date()
    @Published var selectedDay: Date = Calendar.current.startOfDay(for: Date())

    /// Opens on Day. The calendar's job first thing is "what am I doing now",
    /// and the month grid answers a different question.
    @Published var mode: ViewMode = .day {
        didSet { if oldValue != mode { reload() } }
    }

    let calendar = Calendar.current
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.corpusIsStale = true
                self?.reload()
            }
        }
        requestAccess()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Access

    private func requestAccess() {
        store.requestFullAccessToEvents { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.access = .granted
                    self.reload()
                } else {
                    self.access = .denied(error?.localizedDescription
                        ?? "Calendar access was denied. Grant it in System Settings › Privacy & Security › Calendars, then reopen the app.")
                }
            }
        }
    }

    /// The calendar we operate on, or nil if it has been renamed or removed.
    var targetCalendar: EKCalendar? {
        store.calendars(for: .event).first { $0.title == targetCalendarTitle }
    }

    // MARK: - Loading

    /// Fetch a little past the visible span, so scrolling or a quick step to the
    /// next period has something to draw immediately.
    func reload() {
        guard access == .granted, let calendar = targetCalendar else {
            items = []
            itemsByDay = [:]
            return
        }
        let span = mode.interval(around: anchor, calendar: self.calendar)
        let from = self.calendar.date(byAdding: .day, value: -7, to: span.start) ?? span.start
        let to = self.calendar.date(byAdding: .day, value: 7, to: span.end) ?? span.end

        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [calendar])
        items = store.events(matching: predicate)
            .map(EventItem.init)
            .filter { showSupportingOfficeHours || !Categories.isSupportingOfficeHours($0) }
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.start < rhs.start
            }
        itemsByDay = Self.index(items, calendar: self.calendar)
        corpusIsStale = true
        revision += 1
    }

    /// Bucket each event under every day it shows on. All-day events span
    /// [start, end) and so land on several days; timed ones land on one.
    private static func index(_ items: [EventItem], calendar: Calendar) -> [Date: [EventItem]] {
        var index: [Date: [EventItem]] = [:]
        for item in items {
            let first = calendar.startOfDay(for: item.start)
            guard item.isAllDay else {
                index[first, default: []].append(item)
                continue
            }
            let last = calendar.startOfDay(for: item.end)
            var day = first
            repeat {
                index[day, default: []].append(item)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            } while day < last
        }
        return index
    }

    func items(on day: Date) -> [EventItem] {
        itemsByDay[calendar.startOfDay(for: day)] ?? []
    }

    func timedItems(on day: Date) -> [EventItem] { items(on: day).filter { !$0.isAllDay } }
    func allDayItems(on day: Date) -> [EventItem] { items(on: day).filter { $0.isAllDay } }

    /// Whether a day has anything on it — drives the dots in the mini months.
    func hasEvents(on day: Date) -> Bool {
        itemsByDay[calendar.startOfDay(for: day)] != nil
    }

    // MARK: - Mutating

    @discardableResult
    func create(title: String, start: Date, end: Date, isAllDay: Bool,
                location: String, notes: String,
                recurrence: EKRecurrenceRule? = nil) throws -> String? {
        guard let calendar = targetCalendar else { throw StoreError.missingCalendar }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = isAllDay
        event.location = location.isEmpty ? nil : location
        event.notes = notes.isEmpty ? nil : notes
        if let recurrence { event.recurrenceRules = [recurrence] }
        // A repeating event has to be saved across the series, not just the
        // first occurrence, or EventKit drops the rule.
        try store.save(event, span: recurrence == nil ? .thisEvent : .futureEvents, commit: true)
        reload()
        return event.eventIdentifier
    }

    /// Repeating events are changed for this and all later occurrences —
    /// occurrence-level editing is a bigger feature than this app claims.
    func update(_ item: EventItem, title: String, start: Date, end: Date,
                isAllDay: Bool, location: String, notes: String,
                recurrence: RecurrenceEdit = .unchanged,
                span: EKSpan? = nil) throws {
        let event = item.ekEvent
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = isAllDay
        event.location = location.isEmpty ? nil : location
        event.notes = notes.isEmpty ? nil : notes
        var nowRepeats = item.isRecurring
        switch recurrence {
        case .unchanged:
            break
        case .clear:
            event.recurrenceRules = nil
            nowRepeats = item.isRecurring        // still a series edit to clear it
        case .set(let rule):
            event.recurrenceRules = [rule]
            nowRepeats = true
        }
        let repeating = nowRepeats
        try store.save(event, span: span ?? (repeating ? .futureEvents : .thisEvent), commit: true)
        reload()
    }

    func delete(_ item: EventItem, span: EKSpan? = nil) throws {
        let scope = span ?? (item.isRecurring ? .futureEvents : .thisEvent)
        try store.remove(item.ekEvent, span: scope, commit: true)
        reload()
    }

    /// One occurrence of a repeating event, by the day it falls on.
    ///
    /// EventKit hands back a distinct `EKEvent` per occurrence, and holding the
    /// right one is what makes a `.thisEvent` edit affect a single date instead
    /// of the whole series.
    func occurrence(ofSeries seriesID: String, on day: Date) -> EventItem? {
        allKnownItems().first {
            $0.seriesID == seriesID && calendar.isDate($0.start, inSameDayAs: day)
        }
    }

    enum StoreError: LocalizedError {
        case missingCalendar
        var errorDescription: String? {
            "No calendar named \"\(targetCalendarTitle)\" was found in your account."
        }
    }

    // MARK: - Search

    /// Search has to reach past the visible span, so it keeps its own corpus:
    /// four years centred on today, fetched once and reused until something in
    /// the calendar changes.
    private var corpus: [EventItem] = []
    private var corpusIsStale = true

    private func buildCorpusIfNeeded() {
        guard corpusIsStale, access == .granted, let target = targetCalendar else { return }
        let from = calendar.date(byAdding: .year, value: -2, to: Date()) ?? Date()
        let to = calendar.date(byAdding: .year, value: 2, to: Date()) ?? Date()
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [target])
        corpus = store.events(matching: predicate).map(EventItem.init)
        corpusIsStale = false
    }

    /// Title matches, best first, then whichever is most useful to reach.
    ///
    /// Repeating events collapse to a single row — otherwise a weekly lecture
    /// returns forty identical ones — and the row kept is the **next upcoming**
    /// occurrence, not the last. Keeping the last meant searching "office hours"
    /// in September answered with December, and clicking a result threw the
    /// calendar three months forward.
    ///
    /// Ordering follows the same idea: upcoming before past, soonest first among
    /// what is upcoming, most recent first among what is not.
    func search(_ rawQuery: String, limit: Int = 60) -> [EventItem] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        buildCorpusIfNeeded()

        let ranked = corpus.compactMap { item -> (item: EventItem, rank: Int)? in
            guard let rank = Self.rank(title: item.title.lowercased(), query: query) else { return nil }
            return (item, rank)
        }

        let now = Date()
        var bestPerSeries: [String: (item: EventItem, rank: Int)] = [:]
        for hit in ranked {
            guard let existing = bestPerSeries[hit.item.seriesID] else {
                bestPerSeries[hit.item.seriesID] = hit
                continue
            }
            if Self.reachesFirst(hit.item.start, existing.item.start, now: now) {
                bestPerSeries[hit.item.seriesID] = hit
            }
        }

        return bestPerSeries.values
            .sorted { lhs, rhs in
                lhs.rank == rhs.rank
                    ? Self.reachesFirst(lhs.item.start, rhs.item.start, now: now)
                    : lhs.rank < rhs.rank
            }
            .prefix(limit)
            .map(\.item)
    }

    /// Whether `a` should be shown ahead of `b`: anything still to come beats
    /// anything past, the soonest of two future dates wins, and the latest of
    /// two past dates wins.
    private static func reachesFirst(_ a: Date, _ b: Date, now: Date) -> Bool {
        let aUpcoming = a >= now, bUpcoming = b >= now
        if aUpcoming != bUpcoming { return aUpcoming }
        return aUpcoming ? a < b : a > b
    }

    /// Every event the corpus knows about. The categoriser's full pass needs the
    /// whole calendar, not just the visible span.
    func allKnownItems() -> [EventItem] {
        buildCorpusIfNeeded()
        return corpus
    }

    /// Lower is a better match; nil is no match. The tiers are deliberately
    /// coarse — an exact title beats a prefix, a prefix beats a word start, and
    /// a scattered subsequence comes last so "cs22" still finds "CS 2210".
    private static func rank(title: String, query: String) -> Int? {
        if title == query { return 0 }
        if title.hasPrefix(query) { return 1 }
        let words = title.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.hasPrefix(query) }) { return 2 }
        if title.contains(query) { return 3 }
        // Scattered-subsequence matching only past two characters. On short
        // queries it matches almost everything — "cs" otherwise pulls in
        // "Career Services Info Session" on its c and s.
        guard query.count >= 3 else { return nil }
        return isSubsequence(query, of: title) ? 4 : nil
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var iterator = haystack.makeIterator()
        for character in needle {
            var matched = false
            while let next = iterator.next() {
                if next == character { matched = true; break }
            }
            if !matched { return false }
        }
        return true
    }

    // MARK: - Navigation

    var heading: String { mode.heading(for: anchor, calendar: calendar) }

    func step(_ direction: Int) {
        if let next = calendar.date(byAdding: mode.stepUnit, value: direction, to: anchor) {
            anchor = next
            reload()
        }
    }

    func goToToday() {
        anchor = Date()
        selectedDay = calendar.startOfDay(for: Date())
        reload()
    }

    /// Move the view to a day, optionally changing zoom level — how the year and
    /// month views drill down.
    func focus(on day: Date, switchingTo newMode: ViewMode? = nil) {
        anchor = day
        selectedDay = calendar.startOfDay(for: day)
        if let newMode, newMode != mode {
            mode = newMode          // its didSet reloads
        } else {
            reload()
        }
    }
}
