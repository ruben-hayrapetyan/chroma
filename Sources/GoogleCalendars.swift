import AppKit
import EventKit
import SwiftUI

/// One event as Google's Calendar API returns it — only the fields Chroma
/// asks for.
struct GoogleEvent: Decodable {
    struct Time: Decodable {
        var date: String?
        var dateTime: String?
        /// The zone a timed event was set in, which its repeats follow.
        var timeZone: String?
    }

    struct Organizer: Decodable {
        var email: String?
        var isSelf: Bool?
        private enum CodingKeys: String, CodingKey { case email, isSelf = "self" }
    }

    var id: String
    var status: String?
    var summary: String?
    var description: String?
    var location: String?
    var start: Time?
    var end: Time?
    var recurringEventId: String?
    var originalStartTime: Time?
    var recurrence: [String]?
    var locked: Bool?
    var guestsCanModify: Bool?
    var organizer: Organizer?
    var eventType: String?

    static let fields = "id,status,summary,description,location,start,end,recurringEventId,"
        + "originalStartTime,recurrence,locked,guestsCanModify,organizer(email,self),eventType"
}

/// What it takes to change a Google event later.
struct GoogleEventRef {
    let calendarID: String
    /// The occurrence's own id for an event in a series, which is how Google
    /// changes one date on its own; the event's id otherwise.
    let eventID: String
    /// The series' own id, as Google knows it. `EventItem.seriesID` adds the
    /// calendar, since an invitation keeps one id on every calendar it's on.
    let seriesEventID: String
    /// Where this occurrence sits in its series, before any edit moved it.
    let originalStart: Date?
    /// The zone the event was set in, kept when it's edited from elsewhere.
    let timeZone: String?
    let rules: [EKRecurrenceRule]?
}

/// Google's Calendar API, the few calls Chroma makes.
@MainActor
final class GoogleAPI {
    private let auth: GoogleAuth
    private let base = "https://www.googleapis.com/calendar/v3"

    init(auth: GoogleAuth) {
        self.auth = auth
    }

    struct CalendarEntry: Decodable {
        var id: String
        var summary: String?
        var summaryOverride: String?
        var backgroundColor: String?
        var accessRole: String?
        var primary: Bool?
    }

    private struct Page<Item: Decodable>: Decodable {
        var items: [Item]?
        var nextPageToken: String?
    }

    func calendarList() async throws -> [CalendarEntry] {
        try await pages("/users/me/calendarList",
                        fields: "id,summary,summaryOverride,backgroundColor,accessRole,primary",
                        query: [])
    }

    /// Every event touching the window, each occurrence of a series on its
    /// own when `expanded`, or each series once, with its rule, when not.
    func events(_ calendar: String, from start: Date, to end: Date, expanded: Bool,
                fields: String = GoogleEvent.fields) async throws -> [GoogleEvent] {
        try await pages("/calendars/\(segment(calendar))/events", fields: fields, query: [
            URLQueryItem(name: "timeMin", value: stamp(start)),
            URLQueryItem(name: "timeMax", value: stamp(end)),
            URLQueryItem(name: "singleEvents", value: expanded ? "true" : "false"),
        ])
    }

    func instances(_ calendar: String, of series: String, from start: Date, to end: Date,
                   includingCancelled: Bool = false) async throws -> [GoogleEvent] {
        try await pages("/calendars/\(segment(calendar))/events/\(segment(series))/instances",
                        fields: GoogleEvent.fields, query: [
            URLQueryItem(name: "timeMin", value: stamp(start)),
            URLQueryItem(name: "timeMax", value: stamp(end)),
            URLQueryItem(name: "showDeleted", value: includingCancelled ? "true" : "false"),
        ])
    }

    /// Nil when Google has no such event.
    func event(_ calendar: String, _ id: String) async throws -> GoogleEvent? {
        try await send("GET", "/calendars/\(segment(calendar))/events/\(segment(id))",
                       query: [URLQueryItem(name: "fields", value: GoogleEvent.fields)])
            .map { try JSONDecoder().decode(GoogleEvent.self, from: $0) }
    }

    /// The whole event, every field Google has — what a series split copies,
    /// so guests, the Meet link and reminders carry over to the new half.
    func fullEvent(_ calendar: String, _ id: String) async throws -> [String: Any]? {
        try await send("GET", "/calendars/\(segment(calendar))/events/\(segment(id))")
            .flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func insert(_ calendar: String, _ body: [String: Any]) async throws -> GoogleEvent {
        // Without these, Google drops a copied Meet link and attachments.
        try await write("POST", "/calendars/\(segment(calendar))/events", body, extra: [
            URLQueryItem(name: "conferenceDataVersion", value: "1"),
            URLQueryItem(name: "supportsAttachments", value: "true"),
        ])
    }

    func patch(_ calendar: String, _ id: String, _ body: [String: Any]) async throws -> GoogleEvent {
        try await write("PATCH", "/calendars/\(segment(calendar))/events/\(segment(id))", body)
    }

    /// Already gone counts as done.
    func delete(_ calendar: String, _ id: String) async throws {
        _ = try await send("DELETE", "/calendars/\(segment(calendar))/events/\(segment(id))")
    }

    /// Whether anything on the calendar changed since `date` — one tiny
    /// request, so checking often costs next to nothing.
    func hasChanges(_ calendar: String, since date: Date) async throws -> Bool {
        let data = try await send("GET", "/calendars/\(segment(calendar))/events", query: [
            URLQueryItem(name: "updatedMin", value: stamp(date)),
            URLQueryItem(name: "showDeleted", value: "true"),
            URLQueryItem(name: "maxResults", value: "1"),
            URLQueryItem(name: "fields", value: "items(id)"),
        ])
        // A 410 means the last look is too long ago for Google to answer
        // from — which only a full fetch can settle.
        guard let data else { return true }
        return !(try JSONDecoder().decode(Page<GoogleEvent>.self, from: data).items ?? []).isEmpty
    }

    // MARK: - Plumbing

    private func pages<Item: Decodable>(_ path: String, fields: String,
                                        query: [URLQueryItem]) async throws -> [Item] {
        var all: [Item] = []
        var token: String?
        repeat {
            var items = query + [
                URLQueryItem(name: "maxResults", value: "2500"),
                URLQueryItem(name: "fields", value: "nextPageToken,items(\(fields))"),
            ]
            if let token { items.append(URLQueryItem(name: "pageToken", value: token)) }
            guard let data = try await send("GET", path, query: items) else { return all }
            let page = try JSONDecoder().decode(Page<Item>.self, from: data)
            all += page.items ?? []
            token = page.nextPageToken
        } while token != nil
        return all
    }

    private func write(_ method: String, _ path: String, _ body: [String: Any],
                       extra: [URLQueryItem] = []) async throws -> GoogleEvent {
        let query = [URLQueryItem(name: "fields", value: GoogleEvent.fields)] + extra
        guard let data = try await send(method, path, query: query, body: body) else {
            throw GoogleError.server(404, "Google couldn't find that event any more.")
        }
        return try JSONDecoder().decode(GoogleEvent.self, from: data)
    }

    /// Nil for 404 and 410, which mean the thing is gone. Retries once on 401
    /// with a fresh token, since an access token can lapse between the check
    /// and the call.
    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [],
                      body: [String: Any]? = nil) async throws -> Data? {
        var components = URLComponents(string: base + path)!
        if !query.isEmpty {
            components.queryItems = query
            // URLComponents leaves "+" alone, and Google would read it as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        for attempt in 0..<2 {
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.setValue("Bearer \(try await auth.token(forceRefresh: attempt > 0))",
                             forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200..<300: return data
            case 401 where attempt == 0: continue
            case 404, 410: return nil
            case let status: throw GoogleError.server(status, GoogleAuth.errorMessage(data))
            }
        }
        throw GoogleError.signedOut
    }

    private func segment(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlUnreserved) ?? text
    }

    /// UTC with a Z, so there's no "+" in a query to go wrong.
    private func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

/// One Google account's calendars, straight from Google.
///
/// The views ask for events while they draw, so this keeps a copy of what it
/// fetched — every calendar in use, two years either side of today — and
/// answers from that. It asks Google every two minutes, and whenever Chroma
/// comes forward, whether anything changed, and fetches a calendar again
/// only when something did. Changes made here go to Google first and are
/// read back from it, so what's drawn is always what Google has.
@MainActor
final class GoogleCalendars: CalendarProvider {
    var onChange: (() -> Void)?
    /// When Google stops accepting the sign-in, so the app can ask again.
    var onSignedOut: (() -> Void)?
    /// Why fetching is failing, while it is; nil once it works again.
    var onProblem: ((String?) -> Void)?

    let auth = GoogleAuth()
    private lazy var api = GoogleAPI(auth: auth)
    private(set) var account: String?
    private var entries: [CalendarInfo] = []
    private let calendar = Calendar.autoupdatingCurrent

    struct Stored {
        let event: GoogleEvent
        let start: Date
        let end: Date
        let isAllDay: Bool
    }

    private struct Cache {
        var window: DateInterval
        var events: [Stored]
        /// Each series' repeat rules, by its id. The occurrences don't carry
        /// them; the editor and Ask Claude need them.
        var rules: [String: [EKRecurrenceRule]]
        var fetchedAt: Date
    }

    private var caches: [String: Cache] = [:]
    private var fetching: Set<String> = []
    /// The window each calendar was last asked for. The background check
    /// fetches whatever this still covers more of than the cache — a first
    /// fetch that failed, or a window that couldn't be extended.
    private var wanted: [String: DateInterval] = [:]
    /// When Chroma last changed something on each calendar. A fetch that
    /// started before then is out of date by the time it lands, so it runs
    /// again.
    private var editedAt: [String: Date] = [:]
    /// A calendar whose fetch just failed isn't asked again on every redraw.
    private var retryAfter: [String: Date] = [:]
    /// What's failing, by calendar id, and "" for the calendar list. The
    /// offline note stays while anything is.
    private var failures: [String: String] = [:]
    /// Bumped on every sign-in and sign-out, so a fetch made for one account
    /// can't land after it's gone.
    private var generation = 0
    private var timer: Timer?
    private var activation: NSObjectProtocol?
    private var lastCheck = Date.distantPast

    /// The series key `EventItem` carries: the calendar and Google's id. An
    /// invitation keeps one id on every calendar it's on, and each copy needs
    /// its own row and its own colour.
    static func key(_ calendarID: String, _ eventID: String) -> String {
        calendarID + "/" + eventID
    }

    // MARK: - Access

    func requestAccess() async -> EventStore.Access {
        guard GoogleClient.load() != nil, auth.isSignedIn else { return .signedOut }
        do {
            try await loadCalendars()
            startWatching()
            return .granted
        } catch GoogleError.signedOut {
            return .signedOut
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    func signIn() async throws {
        try await auth.signIn()
        forget()
        try await loadCalendars()
        startWatching()
    }

    func signOut() async {
        stopWatching()
        forget()
        entries = []
        account = nil
        await auth.signOut()
    }

    /// Drops everything fetched, for a change of account.
    private func forget() {
        generation += 1
        caches = [:]
        wanted = [:]
        editedAt = [:]
        retryAfter = [:]
        failures = [:]
        onProblem?(nil)
    }

    // MARK: - Calendars

    func calendars() -> [CalendarInfo] { entries }

    var defaultCalendarID: String? { account }

    /// Returns whether the list changed.
    @discardableResult
    private func loadCalendars() async throws -> Bool {
        let generation = self.generation
        let list = try await api.calendarList()
        guard generation == self.generation else { return false }
        // The primary calendar's id is the account's address.
        account = list.first { $0.primary == true }?.id ?? account
        let fresh = list.map { entry in
            CalendarInfo(id: entry.id,
                         title: entry.summaryOverride ?? entry.summary ?? entry.id,
                         account: account ?? "Google",
                         accountID: "google",
                         color: Self.color(entry.backgroundColor),
                         isWritable: entry.accessRole == "owner" || entry.accessRole == "writer")
        }
        guard fresh != entries else { return false }
        entries = fresh
        return true
    }

    func refreshSources() {
        Task { await checkForChanges() }
    }

    private static func color(_ hex: String?) -> Color {
        guard let hex, let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16)
        else { return EventColors.fallback.color }
        return EventColor.rgb(value)
    }

    // MARK: - Reading

    func events(from start: Date, to end: Date, in calendars: [CalendarInfo]) -> [EventItem] {
        var result: [EventItem] = []
        for info in calendars {
            let cache = caches[info.id]
            if cache.map({ $0.window.start > start || $0.window.end < end }) ?? true {
                fetch(info.id, covering: DateInterval(start: start, end: max(end, start)))
            }
            guard let cache else { continue }
            for stored in cache.events where stored.start < end && (stored.end > start || stored.start >= start) {
                result.append(item(stored, in: info, rules: cache.rules))
            }
        }
        return result
    }

    /// Two years either side of today, a month's margin on each end — what
    /// search and the categoriser look across.
    private func standardWindow() -> DateInterval {
        let today = calendar.startOfDay(for: Date())
        let from = calendar.date(byAdding: DateComponents(year: -2, month: -1), to: today) ?? today
        let to = calendar.date(byAdding: DateComponents(year: 2, month: 1), to: today) ?? today
        return DateInterval(start: from, end: to)
    }

    private static func union(_ a: DateInterval, _ b: DateInterval) -> DateInterval {
        DateInterval(start: min(a.start, b.start), end: max(a.end, b.end))
    }

    private func fetch(_ id: String, covering range: DateInterval) {
        let window = Self.union(Self.union(caches[id]?.window ?? standardWindow(), standardWindow()), range)
        wanted[id] = window
        guard !fetching.contains(id), (retryAfter[id] ?? .distantPast) < Date() else { return }
        Task { await load(id, window: window) }
    }

    /// Fetches a calendar's window: every occurrence, plus each series once
    /// for its rule.
    private func load(_ id: String, window: DateInterval) async {
        guard !fetching.contains(id) else { return }
        fetching.insert(id)
        defer { fetching.remove(id) }
        let generation = self.generation
        var started: Date
        repeat {
            started = Date()
            do {
                async let occurrences = api.events(id, from: window.start, to: window.end, expanded: true)
                async let series = api.events(id, from: window.start, to: window.end, expanded: false,
                                              fields: "id,recurrence")
                let (events, masters) = try await (occurrences, series)
                guard generation == self.generation else { return }
                var rules: [String: [EKRecurrenceRule]] = [:]
                for master in masters {
                    if let parsed = RRule.rules(master.recurrence) { rules[master.id] = parsed }
                }
                caches[id] = Cache(window: window, events: events.compactMap(stored),
                                   rules: rules, fetchedAt: started)
                if let asked = wanted[id], window.start <= asked.start, window.end >= asked.end {
                    wanted[id] = nil
                }
                retryAfter[id] = nil
                failures[id] = nil
                report()
                onChange?()
            } catch {
                guard generation == self.generation else { return }
                retryAfter[id] = Date().addingTimeInterval(30)
                handle(error, for: id)
                return
            }
        } while (editedAt[id] ?? .distantPast) > started
    }

    /// Brings one calendar up to date after Chroma changed it: just the days
    /// touched, for a single event, or the whole window, for a series.
    private func refetch(_ id: String, around dates: [Date], wholeWindow: Bool) async {
        guard let window = caches[id]?.window else { return }
        if wholeWindow || fetching.contains(id) {
            // A fetch under way runs again by itself, having started before
            // the change.
            await load(id, window: window)
            return
        }
        let generation = self.generation
        let from = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: dates.min() ?? Date())) ?? Date()
        let to = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: dates.max() ?? Date())) ?? Date()
        do {
            let fresh = try await api.events(id, from: from, to: to, expanded: true)
            guard generation == self.generation, var cache = caches[id] else { return }
            cache.events.removeAll { $0.start < to && ($0.end > from || $0.start >= from) }
            cache.events += fresh.compactMap(stored)
            caches[id] = cache
            onChange?()
        } catch {
            guard generation == self.generation else { return }
            handle(error, for: id)
        }
    }

    private func handle(_ error: Error, for key: String) {
        if case GoogleError.signedOut = error {
            stopWatching()
            forget()
            onSignedOut?()
        } else {
            failures[key] = "Couldn't reach Google — \(error.localizedDescription)"
            report()
        }
    }

    private func report() {
        onProblem?(failures.sorted { $0.key < $1.key }.first?.value)
    }

    /// Marks a calendar as changed by Chroma — before a write, and again once
    /// it lands, so a fetch that started in between runs again.
    private func edited(_ id: String) {
        editedAt[id] = Date()
    }

    // MARK: - Watching for changes

    private func startWatching() {
        stopWatching()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForChanges() }
        }
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, Date().timeIntervalSince(self.lastCheck) > 20 else { return }
                await self.checkForChanges()
            }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
    }

    private func checkForChanges() async {
        lastCheck = Date()
        let generation = self.generation
        do {
            let listChanged = try await loadCalendars()
            failures[""] = nil
            for (id, cache) in caches where !fetching.contains(id) {
                do {
                    // A minute's overlap, for a clock that's a little off Google's.
                    if try await api.hasChanges(id, since: cache.fetchedAt.addingTimeInterval(-60)) {
                        await load(id, window: cache.window)
                    } else {
                        failures[id] = nil
                    }
                } catch GoogleError.signedOut {
                    throw GoogleError.signedOut
                } catch {
                    guard generation == self.generation else { return }
                    failures[id] = "Couldn't reach Google — \(error.localizedDescription)"
                }
            }
            // What was asked for and never arrived.
            for (id, window) in wanted where !fetching.contains(id) {
                await load(id, window: caches[id].map { Self.union($0.window, window) } ?? window)
            }
            guard generation == self.generation else { return }
            if listChanged { onChange?() }
            report()
        } catch {
            guard generation == self.generation else { return }
            handle(error, for: "")
        }
    }

    // MARK: - Changing

    func create(_ fields: EventFields, recurrence: EKRecurrenceRule?,
                in calendar: CalendarInfo) async throws -> String? {
        var body = Self.body(fields, calendar: self.calendar, forInsert: true)
        if let recurrence { body["recurrence"] = [RRule.line(recurrence, allDay: fields.isAllDay)] }
        edited(calendar.id)
        let created = try await api.insert(calendar.id, body)
        edited(calendar.id)
        await refetch(calendar.id, around: [fields.start, fields.end], wholeWindow: recurrence != nil)
        return Self.key(calendar.id, created.id)
    }

    func update(_ item: EventItem, to fields: EventFields, recurrence: RecurrenceEdit,
                span: EKSpan) async throws -> String? {
        guard case .google(let ref) = item.origin else { return nil }
        let touched = [item.start, item.end, fields.start, fields.end]
        edited(ref.calendarID)

        guard item.isRecurring else {
            var body = Self.body(fields, calendar: calendar, zone: ref.timeZone)
            var becomesSeries = false
            if case .set(let rule) = recurrence {
                body["recurrence"] = [RRule.line(rule, allDay: fields.isAllDay)]
                becomesSeries = true
            }
            let saved = try await api.patch(ref.calendarID, ref.eventID, body)
            edited(ref.calendarID)
            await refetch(ref.calendarID, around: touched, wholeWindow: becomesSeries)
            return Self.key(ref.calendarID, saved.id)
        }

        if span == .thisEvent {
            // One date on its own: Google keeps it as an exception in the series.
            _ = try await api.patch(ref.calendarID, ref.eventID, Self.body(fields, calendar: calendar, zone: ref.timeZone))
            edited(ref.calendarID)
            await refetch(ref.calendarID, around: touched, wholeWindow: false)
            return item.seriesID
        }

        let savedID = try await changeFromHere(item, ref: ref, to: fields, recurrence: recurrence)
        edited(ref.calendarID)
        await refetch(ref.calendarID, around: touched, wholeWindow: true)
        return savedID
    }

    /// "This and all later occurrences", which Google has no single call for.
    /// From the first occurrence it's the whole series. From partway through,
    /// the series splits as Google Calendar itself splits it: a new series
    /// from this occurrence with the change, and the old one cut short just
    /// before it. The new one is made first, so a failure part-way leaves a
    /// duplicate to delete rather than weeks missing.
    private func changeFromHere(_ item: EventItem, ref: GoogleEventRef, to fields: EventFields,
                                recurrence: RecurrenceEdit) async throws -> String? {
        guard var master = try await api.fullEvent(ref.calendarID, ref.seriesEventID),
              master["status"] as? String != "cancelled" else {
            throw GoogleError.server(404, "\(item.title) was removed in the meantime.")
        }
        let lines = master["recurrence"] as? [String] ?? []
        let startField = master["start"] as? [String: Any] ?? [:]
        let masterStart = GoogleEvent.Time(date: startField["date"] as? String,
                                           dateTime: startField["dateTime"] as? String,
                                           timeZone: startField["timeZone"] as? String)
        let seriesStart = Self.date(masterStart)
        let allDaySeries = masterStart.date != nil
        let zone = ref.timeZone ?? masterStart.timeZone
        let here = ref.originalStart ?? item.start
        var body = Self.body(fields, calendar: calendar, zone: zone)

        if let seriesStart, here <= seriesStart {
            switch recurrence {
            case .unchanged: break
            case .clear: body["recurrence"] = [String]()
            case .set(let rule): body["recurrence"] = [RRule.line(rule, allDay: fields.isAllDay)]
            }
            let saved = try await api.patch(ref.calendarID, ref.seriesEventID, body)
            return Self.key(ref.calendarID, saved.id)
        }

        switch recurrence {
        case .unchanged:
            // A series that ends after a number of times keeps only what's
            // left of the count. Cancelled dates still count, as they do in
            // the rule itself.
            var kept = lines
            if let count = RRule.count(in: lines) {
                let from = (seriesStart ?? here).addingTimeInterval(-86_400)
                let before = try await api.instances(ref.calendarID, of: ref.seriesEventID, from: from, to: here,
                                                     includingCancelled: true).count
                kept = RRule.setting(count: count - before, in: lines)
            }
            body["recurrence"] = kept
        case .clear:
            break
        case .set(let rule):
            body["recurrence"] = [RRule.line(rule, allDay: fields.isAllDay)]
        }

        // The new half starts as a copy of the whole series — guests, Meet
        // link, reminders, colour, attachments — with the change on top.
        // Google's bookkeeping fields and the old rule stay behind.
        for field in ["id", "etag", "htmlLink", "iCalUID", "created", "updated", "recurringEventId",
                      "originalStartTime", "sequence", "kind", "creator", "organizer", "hangoutLink",
                      "recurrence", "status", "locked", "attendeesOmitted"] {
            master.removeValue(forKey: field)
        }
        for (field, value) in Self.insertable(body) { master[field] = value }

        let created = try await api.insert(ref.calendarID, master)
        do {
            let ended = RRule.ending(lines, before: here, allDay: allDaySeries, calendar: calendar)
            _ = try await api.patch(ref.calendarID, ref.seriesEventID, ["recurrence": ended])
        } catch {
            try? await api.delete(ref.calendarID, created.id)
            throw error
        }
        return Self.key(ref.calendarID, created.id)
    }

    func delete(_ item: EventItem, span: EKSpan) async throws {
        guard case .google(let ref) = item.origin else { return }
        edited(ref.calendarID)

        guard item.isRecurring, span == .futureEvents else {
            try await api.delete(ref.calendarID, ref.eventID)
            edited(ref.calendarID)
            await refetch(ref.calendarID, around: [item.start, item.end], wholeWindow: false)
            return
        }

        // This and later: the whole series from its first occurrence, or the
        // series cut short before this one.
        if let master = try await api.event(ref.calendarID, ref.seriesEventID), master.status != "cancelled" {
            let here = ref.originalStart ?? item.start
            if let seriesStart = stored(master)?.start, here <= seriesStart {
                try await api.delete(ref.calendarID, ref.seriesEventID)
            } else {
                let ended = RRule.ending(master.recurrence ?? [], before: here,
                                         allDay: master.start?.date != nil, calendar: calendar)
                _ = try await api.patch(ref.calendarID, ref.seriesEventID, ["recurrence": ended])
            }
        }
        edited(ref.calendarID)
        await refetch(ref.calendarID, around: [item.start, item.end], wholeWindow: true)
    }

    /// Unsure counts as yes: a colour isn't cleared because the network
    /// dropped for a moment.
    func seriesExists(_ item: EventItem) async -> Bool {
        guard case .google(let ref) = item.origin else { return true }
        do {
            guard let series = try await api.event(ref.calendarID, ref.seriesEventID) else { return false }
            return series.status != "cancelled"
        } catch {
            return true
        }
    }

    func occurrence(of item: EventItem, on day: Date) async throws -> EventItem? {
        guard case .google(let ref) = item.origin,
              let info = entries.first(where: { $0.id == ref.calendarID }) else { return nil }
        let from = calendar.startOfDay(for: day)
        let to = calendar.date(byAdding: .day, value: 1, to: from) ?? from
        let found: [GoogleEvent]
        if item.isRecurring {
            found = try await api.instances(ref.calendarID, of: ref.seriesEventID, from: from, to: to)
        } else {
            found = try await api.event(ref.calendarID, ref.seriesEventID).map { [$0] } ?? []
        }
        return found.lazy
            .filter { $0.status != "cancelled" }
            .compactMap(stored)
            .first { self.calendar.isDate($0.start, inSameDayAs: day) }
            .map { self.item($0, in: info, rules: self.caches[info.id]?.rules ?? [:]) }
    }

    func current(_ item: EventItem) async throws -> EventItem? {
        guard case .google(let ref) = item.origin,
              let info = entries.first(where: { $0.id == ref.calendarID }),
              let event = try await api.event(ref.calendarID, ref.eventID),
              event.status != "cancelled",
              let stored = stored(event)
        else { return nil }
        return self.item(stored, in: info, rules: caches[info.id]?.rules ?? [:])
    }

    // MARK: - Translating

    private func item(_ stored: Stored, in info: CalendarInfo,
                      rules: [String: [EKRecurrenceRule]]) -> EventItem {
        let event = stored.event
        let series = event.recurringEventId ?? event.id
        // Someone else's invitation can only be changed if they allowed it.
        // Google leaves `self` out when it's false, so an organizer without
        // it is someone else.
        let mine = event.organizer.map { $0.isSelf == true } ?? true
        return EventItem(seriesID: Self.key(info.id, series),
                         title: event.summary ?? "",
                         start: stored.start,
                         end: stored.end,
                         isAllDay: stored.isAllDay,
                         location: event.location ?? "",
                         notes: event.description ?? "",
                         isRecurring: event.recurringEventId != nil || event.recurrence != nil,
                         calendarID: info.id,
                         calendarTitle: info.title,
                         isEditable: info.isWritable && event.locked != true
                             && (mine || event.guestsCanModify == true),
                         origin: .google(GoogleEventRef(
                             calendarID: info.id,
                             eventID: event.id,
                             seriesEventID: series,
                             originalStart: event.originalStartTime.flatMap(Self.date),
                             timeZone: event.start?.timeZone,
                             rules: rules[series] ?? RRule.rules(event.recurrence))))
    }

    /// Working-location markers are left out, as Calendar.app leaves them out.
    func stored(_ event: GoogleEvent) -> Stored? {
        guard event.status != "cancelled", event.eventType != "workingLocation",
              let start = event.start.flatMap(Self.date) else { return nil }
        if event.start?.date != nil {
            // Google's all-day end is the day after the last; Chroma's, like
            // EventKit's, is the last second of the last day.
            let after = event.end.flatMap(Self.date)
                ?? calendar.date(byAdding: .day, value: 1, to: start) ?? start
            return Stored(event: event, start: start, end: max(after.addingTimeInterval(-1), start), isAllDay: true)
        }
        let end = event.end.flatMap(Self.date) ?? start
        return Stored(event: event, start: start, end: max(end, start), isAllDay: false)
    }

    private static func date(_ time: GoogleEvent.Time) -> Date? {
        if let day = time.date { return dayFormatter.date(from: day) }
        guard let text = time.dateTime else { return nil }
        return stampFormatter.date(from: text) ?? fractionalFormatter.date(from: text)
    }

    /// The fields Chroma edits, as Google wants them. A switch between timed
    /// and all-day has to clear the other kind of time explicitly, which is
    /// what the nulls are for; a new event leaves them out.
    ///
    /// A timed event keeps the zone it was set in, which its repeats follow —
    /// a Tokyo series edited from New York stays a Tokyo series. A new one
    /// takes this Mac's.
    static func body(_ fields: EventFields, calendar: Calendar, zone: String? = nil,
                     forInsert: Bool = false) -> [String: Any] {
        var body: [String: Any] = [
            "summary": fields.title,
            "location": fields.location,
            "description": fields.notes,
        ]
        if fields.isAllDay {
            let first = calendar.startOfDay(for: fields.start)
            // The end comes as a time on the last day, or as the midnight
            // after it; Google wants the day after either way.
            var last = calendar.startOfDay(for: fields.end)
            if last > first, fields.end == last {
                last = calendar.date(byAdding: .day, value: -1, to: last) ?? last
            }
            let after = calendar.date(byAdding: .day, value: 1, to: max(last, first)) ?? first
            body["start"] = ["date": dayFormatter.string(from: first), "dateTime": NSNull(), "timeZone": NSNull()]
            body["end"] = ["date": dayFormatter.string(from: after), "dateTime": NSNull(), "timeZone": NSNull()]
        } else {
            let zone = zone ?? TimeZone.autoupdatingCurrent.identifier
            body["start"] = ["dateTime": stampFormatter.string(from: fields.start), "timeZone": zone, "date": NSNull()]
            body["end"] = ["dateTime": stampFormatter.string(from: max(fields.end, fields.start)),
                           "timeZone": zone, "date": NSNull()]
        }
        return forInsert ? insertable(body) : body
    }

    /// The body without its nulls, for a new event.
    static func insertable(_ body: [String: Any]) -> [String: Any] {
        body.compactMapValues { value -> Any? in
            if value is NSNull { return nil }
            if let nested = value as? [String: Any] { return insertable(nested) }
            return value
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// RFC 3339 with the local offset: "2026-10-15T15:00:00-04:00".
    private static let stampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .autoupdatingCurrent
        return formatter
    }()

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

extension CharacterSet {
    /// RFC 3986's unreserved characters, plus "@" for calendar ids — ASCII
    /// only, where `.alphanumerics` would let accented letters through.
    static let urlUnreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~@")
}
