import Combine
import EventKit
import Foundation

/// A calendar chosen in Settings or on first launch.
///
/// Remembered by identifier, with its title and account kept alongside:
/// EventKit can hand out a new identifier after an account fully resyncs, and
/// the names are what survive that.
struct CalendarRef: Codable, Equatable {
    var id: String
    var title: String
    var account: String

    init(_ calendar: EKCalendar) {
        id = calendar.calendarIdentifier
        title = calendar.title
        account = calendar.source?.title ?? ""
    }
}

/// A calendar drawn alongside the main one, switched on and off from the
/// toolbar. Nothing is ever created in it from here, though its events can
/// still be edited when the calendar allows it.
struct ExtraCalendar: Codable, Equatable, Identifiable {
    var ref: CalendarRef
    var isShown = true
    /// One pigment for every event on it, ahead of the title rules — for a
    /// calendar whose titles say nothing about what kind of event it is, like
    /// room bookings. Nil leaves its events to the categories.
    var colorID: String?
    /// Whether it gets its own button in the toolbar, for a calendar worth
    /// flipping on and off more often than a trip into a menu allows.
    var inToolbar = false

    var id: String { ref.id }

    init(ref: CalendarRef) {
        self.ref = ref
    }

    private enum CodingKeys: String, CodingKey { case ref, isShown, colorID, inToolbar }

    /// Lenient about everything but the calendar itself, so a setting added
    /// later doesn't make calendars connected before it unreadable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ref = try container.decode(CalendarRef.self, forKey: .ref)
        isShown = try container.decodeIfPresent(Bool.self, forKey: .isShown) ?? true
        colorID = try container.decodeIfPresent(String.self, forKey: .colorID)
        inToolbar = try container.decodeIfPresent(Bool.self, forKey: .inToolbar) ?? false
    }
}

/// Every calendar on one account, for the pickers.
struct CalendarGroup: Identifiable {
    let id: String
    let account: String
    let calendars: [EKCalendar]
}

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
    let calendarID: String
    let calendarTitle: String
    /// The pigment its calendar was given in Settings, if any.
    let calendarColorID: String?
    /// False for subscriptions, holiday calendars, and anything shared
    /// read-only.
    let isEditable: Bool
    let ekEvent: EKEvent

    init(_ event: EKEvent, calendarColorID: String? = nil) {
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
        self.calendarID = event.calendar?.calendarIdentifier ?? ""
        self.calendarTitle = event.calendar?.title ?? ""
        self.calendarColorID = calendarColorID
        self.isEditable = event.calendar?.allowsContentModifications ?? false
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
/// Calendar.app, or arriving from iCloud or Google — is the same object. All
/// this class does is notice and reload.
///
/// It works on one main calendar, picked on first launch: new events go there,
/// and it is the only one Claude may change. Other calendars can be connected
/// in Settings and drawn alongside it.
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

    /// The calendar new events go to. Nil until one is chosen.
    @Published private(set) var mainCalendar: CalendarRef? = EventStore.loadDefault("mainCalendar") {
        didSet { EventStore.saveDefault(mainCalendar, "mainCalendar") }
    }

    /// Calendars drawn alongside the main one, in the order they were connected.
    @Published private(set) var extraCalendars: [ExtraCalendar] = EventStore.loadDefault("extraCalendars") ?? [] {
        didSet { EventStore.saveDefault(extraCalendars, "extraCalendars") }
    }

    /// Whether the events matched by the filter in `categories.json` are drawn.
    ///
    /// Off by default: a filter only exists because someone wanted those events
    /// out of the way. With no filter defined, this does nothing. Falls back to
    /// the setting's old name so an existing choice survives the rename.
    @Published var showFilteredEvents: Bool = UserDefaults.standard
        .object(forKey: "showFilteredEvents") as? Bool
        ?? UserDefaults.standard.bool(forKey: "showSupportingOfficeHours") {
        didSet {
            guard oldValue != showFilteredEvents else { return }
            UserDefaults.standard.set(showFilteredEvents, forKey: "showFilteredEvents")
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
    private var rulesSubscription: AnyCancellable?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.corpusIsStale = true
                self?.reload()
            }
        }
        // A new filter changes what is drawn, and new rules change what gets
        // coloured. Deferred a turn because @Published fires before the value
        // is stored, and the reload has to read the new one.
        rulesSubscription = RuleBook.shared.$rules
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
        requestAccess()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    nonisolated private static func loadDefault<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    nonisolated private static func saveDefault<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
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

    // MARK: - Calendars

    /// The calendar we create in, or nil if none is chosen or it has gone.
    var targetCalendar: EKCalendar? { mainCalendar.flatMap(resolve) }

    /// What the sidebar calls the main calendar: its account, as macOS names
    /// it — "iCloud", "Google", "Exchange". An account titled by its email
    /// address is shortened to the service, since the address is precise and
    /// useless as a label.
    var accountLabel: String {
        guard let title = targetCalendar?.source?.title else { return "" }
        guard let at = title.firstIndex(of: "@") else { return title }
        let domain = title[title.index(after: at)...].lowercased()
        switch domain {
        case "gmail.com", "googlemail.com": return "Google"
        case "icloud.com", "me.com", "mac.com": return "iCloud"
        case "outlook.com", "hotmail.com", "live.com": return "Outlook"
        default: return domain
        }
    }

    /// The calendar EventKit would create in, used to preselect the first-launch
    /// picker.
    var systemDefaultCalendar: EKCalendar? { store.defaultCalendarForNewEvents }

    func resolve(_ ref: CalendarRef) -> EKCalendar? {
        if let exact = store.calendar(withIdentifier: ref.id) { return exact }
        return store.calendars(for: .event).first {
            $0.title == ref.title && ($0.source?.title ?? "") == ref.account
        }
    }

    /// Every calendar on this Mac, grouped by account. Accounts are kept apart
    /// by identifier, not title, since two Google accounts are both "Google".
    func calendarGroups(writableOnly: Bool = false) -> [CalendarGroup] {
        let calendars = store.calendars(for: .event)
            .filter { !writableOnly || $0.allowsContentModifications }
        let bySource = Dictionary(grouping: calendars) { $0.source?.sourceIdentifier ?? "" }
        return bySource.map { id, members in
            CalendarGroup(id: id,
                          account: members.first?.source?.title ?? "Other",
                          calendars: members.sorted {
                              $0.title.localizedStandardCompare($1.title) == .orderedAscending
                          })
        }
        .sorted { $0.account.localizedStandardCompare($1.account) == .orderedAscending }
    }

    func useAsMain(_ calendar: EKCalendar) {
        mainCalendar = CalendarRef(calendar)
        extraCalendars.removeAll { $0.id == calendar.calendarIdentifier }
        corpusIsStale = true
        reload()
    }

    func isConnected(_ calendar: EKCalendar) -> Bool {
        extraCalendars.contains { $0.id == calendar.calendarIdentifier }
    }

    func connect(_ calendar: EKCalendar) {
        guard !isConnected(calendar),
              calendar.calendarIdentifier != targetCalendar?.calendarIdentifier else { return }
        extraCalendars.append(ExtraCalendar(ref: CalendarRef(calendar)))
        corpusIsStale = true
        reload()
    }

    func disconnect(_ id: String) {
        extraCalendars.removeAll { $0.id == id }
        corpusIsStale = true
        reload()
    }

    func setShown(_ id: String, _ shown: Bool) {
        guard let index = extraCalendars.firstIndex(where: { $0.id == id }) else { return }
        extraCalendars[index].isShown = shown
        // A calendar newly shared on Google can be on the server before
        // EventKit has asked for it; this nudges the accounts to sync.
        if shown, resolve(extraCalendars[index].ref) == nil {
            store.refreshSourcesIfNecessary()
        }
        corpusIsStale = true
        reload()
    }

    func setInToolbar(_ id: String, _ inToolbar: Bool) {
        guard let index = extraCalendars.firstIndex(where: { $0.id == id }) else { return }
        extraCalendars[index].inToolbar = inToolbar
    }

    func setColor(_ id: String, _ colorID: String?) {
        guard let index = extraCalendars.firstIndex(where: { $0.id == id }) else { return }
        extraCalendars[index].colorID = colorID
        corpusIsStale = true
        reload()
    }

    /// Every calendar currently being drawn: the main one, plus each connected
    /// calendar that is switched on and present on this Mac.
    private func visibleCalendars(_ main: EKCalendar) -> [EKCalendar] {
        [main] + extraCalendars.filter(\.isShown).compactMap { resolve($0.ref) }
            .filter { $0.calendarIdentifier != main.calendarIdentifier }
    }

    private func makeItem(_ event: EKEvent) -> EventItem {
        let id = event.calendar?.calendarIdentifier
        return EventItem(event, calendarColorID: extraCalendars.first { $0.id == id }?.colorID)
    }

    /// What is on a calendar over the next month, soonest first — how the
    /// first-launch picker makes calendars recognisable by their contents.
    func upcoming(on calendar: EKCalendar, days: Int = 30) -> [EventItem] {
        guard access == .granted else { return [] }
        let now = Date()
        let to = self.calendar.date(byAdding: .day, value: days, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: to, calendars: [calendar])
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map(makeItem)
    }

    /// Every event on one connected calendar across the search window, shown
    /// or not — what a calendar-wide colour change has to reach.
    func allItems(on extra: ExtraCalendar) -> [EventItem] {
        guard access == .granted, let calendar = resolve(extra.ref) else { return [] }
        let from = self.calendar.date(byAdding: .year, value: -2, to: Date()) ?? Date()
        let to = self.calendar.date(byAdding: .year, value: 2, to: Date()) ?? Date()
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [calendar])
        return store.events(matching: predicate).map(makeItem)
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

        let predicate = store.predicateForEvents(withStart: from, end: to,
                                                 calendars: visibleCalendars(calendar))
        items = store.events(matching: predicate)
            .map(makeItem)
            .filter { showFilteredEvents || !Categories.isFilteredOut($0) }
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
            "The calendar Chroma uses isn't on this Mac any more. Choose another in Settings."
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
        let predicate = store.predicateForEvents(withStart: from, end: to,
                                                 calendars: visibleCalendars(target))
        corpus = store.events(matching: predicate).map(makeItem)
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
