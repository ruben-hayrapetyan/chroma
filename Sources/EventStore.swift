import AppKit
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

    init(_ calendar: CalendarInfo) {
        id = calendar.id
        title = calendar.title
        account = calendar.account
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
    let calendars: [CalendarInfo]
}

/// One occurrence of an event, flattened for display.
///
/// A repeating event comes back once per occurrence, every one sharing the
/// series' identifier. SwiftUI needs per-row identity, so `id` pins the
/// occurrence while `seriesID` stays stable across the series — which is what
/// per-event colour is keyed on.
struct EventItem: Identifiable {
    /// The event as its source holds it, for changing it later.
    enum Origin {
        case apple(EKEvent)
        case google(GoogleEventRef)
    }

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
    var calendarColorID: String?
    /// False for subscriptions, holiday calendars, and anything shared
    /// read-only.
    let isEditable: Bool
    let origin: Origin

    init(seriesID: String, title: String, start: Date, end: Date, isAllDay: Bool,
         location: String, notes: String, isRecurring: Bool, calendarID: String,
         calendarTitle: String, isEditable: Bool, origin: Origin) {
        self.seriesID = seriesID
        self.id = Self.id(series: seriesID, start: start)
        self.title = title.isEmpty ? "(no title)" : title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.isRecurring = isRecurring
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
        self.isEditable = isEditable
        self.origin = origin
    }

    /// An occurrence's identity: its series, and where it starts.
    static func id(series: String, start: Date) -> String {
        series + "@" + String(start.timeIntervalSinceReferenceDate)
    }

    /// The series an `id` belongs to. Split at the last "@", since series
    /// identifiers can hold one of their own — an EventKit id for a Google
    /// event ends in "@google.com".
    static func series(of id: String) -> String {
        id.lastIndex(of: "@").map { String(id[..<$0]) } ?? id
    }

    /// The series' repeat rules, nil when it doesn't repeat.
    var recurrenceRules: [EKRecurrenceRule]? {
        switch origin {
        case .apple(let event): return event.recurrenceRules
        case .google(let ref): return ref.rules
        }
    }

    /// Where the block sits in one day's column, in minutes from midnight:
    /// clipped to that day, so an event running past midnight shows on both,
    /// and read off the clock rather than the seconds elapsed, so on the day
    /// the clocks change a 3 PM event still lines up with 3 PM.
    func clockSpan(on day: Date, in calendar: Calendar) -> (start: Double, end: Double) {
        Self.clockSpan(from: start, to: end, on: day, in: calendar)
    }

    static func clockSpan(from start: Date, to end: Date, on day: Date,
                          in calendar: Calendar) -> (start: Double, end: Double) {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        func clock(_ date: Date) -> Double {
            let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
            return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
        }
        let from = start <= dayStart ? 0 : clock(start)
        let to = end >= dayEnd ? 24 * 60 : clock(end)
        return (from, max(to, from))
    }

    var durationMinutes: Double {
        max(end.timeIntervalSince(start) / 60, 15)   // never thinner than 15 min
    }
}

/// Owns the connection to the calendars and republishes what the current view
/// needs.
///
/// The calendars come from one source at a time — Apple Calendar or Google
/// Calendar, chosen on first launch and switchable in Settings. Everything
/// here works the same for either; the source sits behind `CalendarProvider`.
///
/// It works on one main calendar, picked on first launch: new events go there,
/// and it is the only one Claude may change. Other calendars can be connected
/// in Settings and drawn alongside it.
@MainActor
final class EventStore: ObservableObject {
    enum Access: Equatable {
        case pending
        case granted
        /// macOS refused access to its calendars.
        case denied(String)
        /// Google, with no account signed in.
        case signedOut
        /// Google, signed in but out of reach.
        case unreachable(String)
    }

    /// Nil until the first-launch choice.
    @Published private(set) var source: CalendarSource?
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

    /// Bumped whenever the source reports a change, even before a main
    /// calendar is chosen — what the first-launch picker watches.
    @Published private(set) var sourceRevision = 0

    /// A Google sign-in under way in the browser, and why the last one failed.
    @Published private(set) var signingIn = false
    @Published var signInProblem: String?
    /// Why Google can't be reached at the moment, nil while all is well.
    @Published private(set) var syncProblem: String?

    /// The calendar new events go to. Nil until one is chosen. Each source
    /// keeps its own, so switching back finds it as it was.
    @Published private(set) var mainCalendar: CalendarRef? {
        didSet { EventStore.saveDefault(mainCalendar, key("mainCalendar")) }
    }

    /// Calendars drawn alongside the main one, in the order they were connected.
    @Published private(set) var extraCalendars: [ExtraCalendar] {
        didSet { EventStore.saveDefault(extraCalendars, key("extraCalendars")) }
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

    /// Follows the system's time zone as it changes, rather than keeping the
    /// one the app launched in.
    let calendar = Calendar.autoupdatingCurrent
    private var provider: CalendarProvider?
    private var observers: [NSObjectProtocol] = []
    private var rulesSubscription: AnyCancellable?

    /// The day that was today at the last check. The app stays open for days
    /// at a time, so "today" has to move on by itself.
    private var today = Calendar.current.startOfDay(for: Date())

    init() {
        let source = Self.savedSource()
        self.source = source
        mainCalendar = Self.loadDefault(Self.key("mainCalendar", for: source))
        extraCalendars = Self.loadDefault(Self.key("extraCalendars", for: source)) ?? []

        let center = NotificationCenter.default
        // Midnight, a clock or time-zone change, and waking from a night's
        // sleep — the last of which doesn't always arrive as a day change.
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
                     NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.rollOverIfNeeded() }
            })
        }
        // A new filter changes what is drawn, and new rules change what gets
        // coloured. Deferred a turn because @Published fires before the value
        // is stored, and the reload has to read the new one.
        rulesSubscription = RuleBook.shared.$rules
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
        connectSource()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
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

    // MARK: - Source

    /// A copy set up before there was a choice was using Apple Calendar, and
    /// carries on with it rather than being asked again.
    private static func savedSource() -> CalendarSource? {
        if let raw = UserDefaults.standard.string(forKey: "calendarSource") {
            return CalendarSource(rawValue: raw)
        }
        return UserDefaults.standard.data(forKey: "mainCalendar") != nil ? .apple : nil
    }

    /// Apple Calendar's settings keep the names they had before Google was an
    /// option.
    private static func key(_ name: String, for source: CalendarSource?) -> String {
        source == .google ? "google." + name : name
    }

    private func key(_ name: String) -> String { Self.key(name, for: source) }

    /// Switches where the calendars come from. Each source keeps its own main
    /// calendar and connected calendars, so switching back loses nothing.
    func use(_ source: CalendarSource) {
        guard source != self.source || provider == nil else { return }
        UserDefaults.standard.set(source.rawValue, forKey: "calendarSource")
        self.source = source
        mainCalendar = Self.loadDefault(key("mainCalendar"))
        extraCalendars = Self.loadDefault(key("extraCalendars")) ?? []
        connectSource()
    }

    private func connectSource() {
        // The old source may still have requests out; nothing it says from
        // here on is about the calendars being shown.
        if let old = provider {
            old.onChange = nil
            if let google = old as? GoogleCalendars {
                google.onProblem = nil
                google.onSignedOut = nil
                google.stopWatching()
                google.auth.cancelSignIn()
            }
        }
        provider = nil
        signingIn = false
        items = []
        itemsByDay = [:]
        corpus = []
        corpusIsStale = true
        syncProblem = nil
        signInProblem = nil
        access = .pending
        guard let source else { return }

        let provider: CalendarProvider
        switch source {
        case .apple:
            provider = AppleCalendars()
        case .google:
            let google = GoogleCalendars()
            google.onSignedOut = { [weak self] in self?.access = .signedOut }
            google.onProblem = { [weak self] in self?.syncProblem = $0 }
            provider = google
        }
        provider.onChange = { [weak self] in
            self?.sourceRevision += 1
            self?.corpusIsStale = true
            self?.reload()
        }
        self.provider = provider
        Task { await requestAccess() }
    }

    private func requestAccess() async {
        guard let provider else { return }
        let result = await provider.requestAccess()
        // Switched to the other source while asking.
        guard provider === self.provider else { return }
        access = result
        corpusIsStale = true
        reload()
    }

    /// Tries Google again after it couldn't be reached.
    func retryAccess() {
        access = .pending
        Task { await requestAccess() }
    }

    // MARK: - Google

    private var google: GoogleCalendars? { provider as? GoogleCalendars }

    /// The signed-in Google account's address.
    var googleAccount: String? { google?.account }

    var hasGoogleClient: Bool { GoogleClient.load() != nil }

    /// Opens Google in the browser and waits for it to send the browser back.
    func signInToGoogle() {
        guard let google, !signingIn else { return }
        signingIn = true
        signInProblem = nil
        Task {
            do {
                try await google.signIn()
                guard google === self.google else { return }
                signingIn = false
                access = .granted
                corpusIsStale = true
                reload()
            } catch {
                // A sign-in from a source since switched away from says nothing.
                guard google === self.google else { return }
                signingIn = false
                signInProblem = error.localizedDescription
            }
        }
    }

    func cancelGoogleSignIn() {
        google?.auth.cancelSignIn()
    }

    func signOutOfGoogle() {
        guard let google else { return }
        Task {
            await google.signOut()
            guard google === self.google else { return }
            access = .signedOut
            items = []
            itemsByDay = [:]
            corpus = []
            corpusIsStale = true
        }
    }

    /// Keeps a Google Cloud client file where sign-in looks for it.
    func installGoogleClient(from url: URL) throws {
        try GoogleClient.install(from: url)
        objectWillChange.send()
    }

    // MARK: - Calendars

    /// The calendar we create in, or nil if none is chosen or it has gone.
    var targetCalendar: CalendarInfo? { mainCalendar.flatMap(resolve) }

    /// What the sidebar calls the main calendar's account — "iCloud",
    /// "Google", "Exchange". An account titled by its email address is
    /// shortened to the service, since the address is precise and useless as
    /// a label.
    var accountLabel: String {
        if source == .google { return "Google" }
        guard let title = targetCalendar?.account, !title.isEmpty else { return "" }
        guard let at = title.firstIndex(of: "@") else { return title }
        let domain = title[title.index(after: at)...].lowercased()
        switch domain {
        case "gmail.com", "googlemail.com": return "Google"
        case "icloud.com", "me.com", "mac.com": return "iCloud"
        case "outlook.com", "hotmail.com", "live.com": return "Outlook"
        default: return domain
        }
    }

    /// The calendar the source would create in, used to preselect the
    /// first-launch picker.
    var defaultCalendarID: String? { provider?.defaultCalendarID }

    func resolve(_ ref: CalendarRef) -> CalendarInfo? {
        Self.resolve(ref, in: provider?.calendars() ?? [])
    }

    private static func resolve(_ ref: CalendarRef, in calendars: [CalendarInfo]) -> CalendarInfo? {
        calendars.first { $0.id == ref.id }
            ?? calendars.first { $0.title == ref.title && $0.account == ref.account }
    }

    /// A calendar found by its name after its identifier changed — EventKit
    /// hands out new ones when an account fully resyncs — takes the new one,
    /// so its colour, its toolbar button and Settings' tick follow it.
    private func adoptNewIdentifiers(_ calendars: [CalendarInfo]) {
        if let main = mainCalendar, let found = Self.resolve(main, in: calendars), found.id != main.id {
            mainCalendar = CalendarRef(found)
        }
        for (index, extra) in extraCalendars.enumerated() {
            guard let found = Self.resolve(extra.ref, in: calendars), found.id != extra.id,
                  !extraCalendars.contains(where: { $0.id == found.id }) else { continue }
            extraCalendars[index].ref = CalendarRef(found)
        }
    }

    /// Every calendar the source offers, grouped by account. Accounts are kept
    /// apart by identifier, not title, since two Google accounts are both
    /// "Google".
    func calendarGroups(writableOnly: Bool = false) -> [CalendarGroup] {
        let calendars = (provider?.calendars() ?? []).filter { !writableOnly || $0.isWritable }
        return Dictionary(grouping: calendars, by: \.accountID).map { id, members in
            CalendarGroup(id: id,
                          account: members.first.map { $0.account.isEmpty ? "Other" : $0.account } ?? "Other",
                          calendars: members.sorted {
                              $0.title.localizedStandardCompare($1.title) == .orderedAscending
                          })
        }
        .sorted { $0.account.localizedStandardCompare($1.account) == .orderedAscending }
    }

    func useAsMain(_ calendar: CalendarInfo) {
        mainCalendar = CalendarRef(calendar)
        extraCalendars.removeAll { $0.id == calendar.id }
        corpusIsStale = true
        reload()
    }

    func isConnected(_ calendar: CalendarInfo) -> Bool {
        extraCalendars.contains { $0.id == calendar.id }
    }

    func connect(_ calendar: CalendarInfo) {
        guard !isConnected(calendar), calendar.id != targetCalendar?.id else { return }
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
        // this Mac has asked for it; this nudges the accounts to sync.
        if shown, resolve(extraCalendars[index].ref) == nil {
            provider?.refreshSources()
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
    /// calendar that is switched on and still there.
    private func visibleCalendars(_ main: CalendarInfo) -> [CalendarInfo] {
        [main] + extraCalendars.filter(\.isShown).compactMap { resolve($0.ref) }
            .filter { $0.id != main.id }
    }

    /// Gives each item the pigment its calendar wears, if it has one.
    private func decorated(_ items: [EventItem]) -> [EventItem] {
        let pigments = Dictionary(extraCalendars.map { ($0.id, $0.colorID) }, uniquingKeysWith: { first, _ in first })
        return items.map { item in
            var item = item
            item.calendarColorID = pigments[item.calendarID] ?? nil
            return item
        }
    }

    /// What is on a calendar over the next month, soonest first — how the
    /// first-launch picker makes calendars recognisable by their contents.
    func upcoming(on calendar: CalendarInfo, days: Int = 30) -> [EventItem] {
        guard access == .granted, let provider else { return [] }
        let now = Date()
        let to = self.calendar.date(byAdding: .day, value: days, to: now) ?? now
        return decorated(provider.events(from: now, to: to, in: [calendar])
            .filter { $0.end > now }
            .sorted { $0.start < $1.start })
    }

    /// Every event on one connected calendar across the search window, shown
    /// or not — what a calendar-wide colour change has to reach.
    func allItems(on extra: ExtraCalendar) -> [EventItem] {
        guard access == .granted, let provider, let calendar = resolve(extra.ref) else { return [] }
        let from = self.calendar.date(byAdding: .year, value: -2, to: Date()) ?? Date()
        let to = self.calendar.date(byAdding: .year, value: 2, to: Date()) ?? Date()
        return decorated(provider.events(from: from, to: to, in: [calendar]))
    }

    // MARK: - Loading

    /// Fetch a little past the visible span, so scrolling or a quick step to the
    /// next period has something to draw immediately — and far enough to cover
    /// the sidebar too: its mini month shows the whole month around the view,
    /// and its agenda the selected day, which paging doesn't move.
    func reload() {
        guard access == .granted, let provider else {
            items = []
            itemsByDay = [:]
            return
        }
        adoptNewIdentifiers(provider.calendars())
        guard let calendar = targetCalendar else {
            items = []
            itemsByDay = [:]
            return
        }
        let span = mode.interval(around: anchor, calendar: self.calendar)
        let month = ViewMode.month.interval(around: anchor, calendar: self.calendar)
        let day = self.calendar.startOfDay(for: selectedDay)
        let from = self.calendar.date(byAdding: .day, value: -7, to: min(span.start, month.start, day)) ?? span.start
        let to = self.calendar.date(byAdding: .day, value: 7,
                                    to: max(span.end, month.end, day.addingTimeInterval(86_400))) ?? span.end

        items = decorated(provider.events(from: from, to: to, in: visibleCalendars(calendar)))
            .filter { showFilteredEvents || !Categories.isFilteredOut($0) }
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.start < rhs.start
            }
        itemsByDay = Self.index(items, calendar: self.calendar)
        revision += 1
    }

    /// Bucket each event under every day it shows on: each day that starts
    /// before the event ends. That keeps the last day of a multi-day all-day
    /// event whether its end comes as 23:59:59 on that day or as the midnight
    /// after it, and puts a timed event running past midnight on both days —
    /// while one ending exactly at midnight stays on its own.
    private static func index(_ items: [EventItem], calendar: Calendar) -> [Date: [EventItem]] {
        var index: [Date: [EventItem]] = [:]
        for item in items {
            var day = calendar.startOfDay(for: item.start)
            repeat {
                index[day, default: []].append(item)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                // Back to midnight each time: where a clock change skips
                // midnight, that day starts at 1:00, and adding a day to it
                // would land every later key an hour off.
                day = calendar.startOfDay(for: next)
            } while day < item.end
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
                recurrence: EKRecurrenceRule? = nil) async throws -> String? {
        guard let provider, let calendar = targetCalendar else { throw StoreError.missingCalendar }
        let fields = EventFields(title: title, start: start, end: end, isAllDay: isAllDay,
                                 location: location, notes: notes)
        let seriesID = try await provider.create(fields, recurrence: recurrence, in: calendar)
        changed()
        return seriesID
    }

    /// Repeating events are changed for this and all later occurrences —
    /// occurrence-level editing is a bigger feature than this app claims.
    ///
    /// Returns the event's identifier after the save. Changing a series from
    /// partway through splits it in two, and the later half comes back under a
    /// new identifier — which is what its colour has to follow.
    @discardableResult
    func update(_ item: EventItem, title: String, start: Date, end: Date,
                isAllDay: Bool, location: String, notes: String,
                recurrence: RecurrenceEdit = .unchanged,
                span: EKSpan? = nil) async throws -> String? {
        let provider = try provider(for: item)
        var recurrence = recurrence
        var repeating = item.isRecurring        // still a series edit to clear it
        if case .set = recurrence { repeating = true }
        let scope = span ?? (repeating ? .futureEvents : .thisEvent)
        // A weekly series on one weekday, moved to another, repeats on the
        // new one — as in Calendar.app — rather than carrying on on the old.
        if case .unchanged = recurrence, scope == .futureEvents,
           let moved = RecurrenceDraft.following(item.recurrenceRules, from: item.start, to: start,
                                                 calendar: calendar) {
            recurrence = .set(moved)
        }
        let fields = EventFields(title: title, start: start, end: end, isAllDay: isAllDay,
                                 location: location, notes: notes)
        let savedID = try await provider.update(item, to: fields, recurrence: recurrence, span: scope)
        changed()
        return savedID
    }

    func delete(_ item: EventItem, span: EKSpan? = nil) async throws {
        let provider = try provider(for: item)
        try await provider.delete(item, span: span ?? (item.isRecurring ? .futureEvents : .thisEvent))
        changed()
    }

    /// The source an item came from, if it's still the one in use. An edit
    /// begun before switching sources goes nowhere rather than to the wrong
    /// calendar.
    private func provider(for item: EventItem) throws -> CalendarProvider {
        guard let provider else { throw StoreError.missingCalendar }
        switch (item.origin, provider) {
        case (.apple, is AppleCalendars), (.google, is GoogleCalendars): return provider
        default: throw StoreError.sourceChanged
        }
    }

    private func changed() {
        corpusIsStale = true
        reload()
    }

    /// Whether any of a series is left. Deleting "this and later" from partway
    /// through keeps the earlier occurrences, and with them their colour.
    func seriesExists(_ item: EventItem) async -> Bool {
        guard let provider = try? provider(for: item) else { return true }
        return await provider.seriesExists(item)
    }

    /// One occurrence of a repeating event, by the day it falls on, read fresh
    /// — holding the right one is what makes a single-date edit affect that
    /// date instead of the whole series.
    func occurrence(of item: EventItem, on day: Date) async throws -> EventItem? {
        guard let found = try await provider(for: item).occurrence(of: item, on: day) else { return nil }
        return decorated([found]).first
    }

    /// The event as the calendar has it now, or nil if it has since been
    /// deleted.
    func current(_ item: EventItem) async throws -> EventItem? {
        guard let found = try await provider(for: item).current(item) else { return nil }
        return decorated([found]).first
    }

    enum StoreError: LocalizedError {
        case missingCalendar
        case sourceChanged
        var errorDescription: String? {
            switch self {
            case .missingCalendar:
                return "The calendar Chroma uses can't be found any more. Choose another in Settings."
            case .sourceChanged:
                return "That event is from the calendar source Chroma was using before. Open it again and retry."
            }
        }
    }

    // MARK: - Search

    /// Search has to reach past the visible span, so it keeps its own corpus:
    /// four years centred on today, fetched once and reused until something in
    /// the calendar changes. Moving the view doesn't count: the corpus doesn't
    /// depend on where you're looking, so stepping to the next week has no
    /// reason to fetch four years of events again.
    private var corpus: [EventItem] = []
    private var corpusIsStale = true

    private func buildCorpusIfNeeded() {
        guard corpusIsStale, access == .granted, let provider, let target = targetCalendar else { return }
        let from = calendar.date(byAdding: .year, value: -2, to: Date()) ?? Date()
        let to = calendar.date(byAdding: .year, value: 2, to: Date()) ?? Date()
        corpus = decorated(provider.events(from: from, to: to, in: visibleCalendars(target)))
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
            // What the filter hides from the grid stays out of search too: a
            // result that opens nothing when clicked is worse than none.
            guard showFilteredEvents || !Categories.isFilteredOut(item),
                  let rank = Self.rank(title: item.title.lowercased(), query: query) else { return nil }
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

    /// Moves the view on when the day changes under it. Whoever was looking at
    /// today goes on looking at today; whoever had gone to another day stays
    /// there. Either way the grids redraw, so the today marker moves too.
    private func rollOverIfNeeded() {
        let now = calendar.startOfDay(for: Date())
        guard now != today else { return }
        let dayAfter = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        if selectedDay == today { selectedDay = now }
        if anchor >= today && anchor < dayAfter { anchor = Date() }
        today = now
        corpusIsStale = true
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
