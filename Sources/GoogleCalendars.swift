import AppKit
import EventKit
import SwiftUI

/// One event as Google's Calendar API returns it — only the fields Chroma
/// asks for.
struct GoogleEvent: Decodable {
    struct Time: Decodable {
        var date: String?
        var dateTime: String?
    }

    struct Organizer: Decodable {
        var isSelf: Bool?
        private enum CodingKeys: String, CodingKey { case isSelf = "self" }
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
        + "originalStartTime,recurrence,locked,guestsCanModify,organizer(self),eventType"
}

/// What it takes to change a Google event later.
struct GoogleEventRef {
    let calendarID: String
    /// The occurrence's own id for an event in a series, which is how Google
    /// changes one date on its own; the event's id otherwise.
    let eventID: String
    /// Where this occurrence sits in its series, before any edit moved it.
    let originalStart: Date?
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

    func insert(_ calendar: String, _ body: [String: Any]) async throws -> GoogleEvent {
        try await write("POST", "/calendars/\(segment(calendar))/events", body)
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
        guard let data else { return false }
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

    private func write(_ method: String, _ path: String, _ body: [String: Any]) async throws -> GoogleEvent {
        let query = [URLQueryItem(name: "fields", value: GoogleEvent.fields)]
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

    private struct Stored {
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
    /// When Chroma last changed something on each calendar. A fetch that
    /// started before then is out of date by the time it lands, so it runs
    /// again.
    private var editedAt: [String: Date] = [:]
    /// A calendar whose fetch just failed isn't asked again on every redraw.
    private var retryAfter: [String: Date] = [:]
    private var timer: Timer?
    private var activation: NSObjectProtocol?
    private var lastCheck = Date.distantPast

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
        try await loadCalendars()
        startWatching()
    }

    func signOut() async {
        stopWatching()
        caches = [:]
        entries = []
        account = nil
        await auth.signOut()
    }

    // MARK: - Calendars

    func calendars() -> [CalendarInfo] { entries }

    var defaultCalendarID: String? { account }

    /// Returns whether the list changed.
    @discardableResult
    private func loadCalendars() async throws -> Bool {
        let list = try await api.calendarList()
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

    private func fetch(_ id: String, covering range: DateInterval) {
        guard !fetching.contains(id), (retryAfter[id] ?? .distantPast) < Date() else { return }
        var window = caches[id]?.window ?? standardWindow()
        for extra in [standardWindow(), range] {
            window = DateInterval(start: min(window.start, extra.start), end: max(window.end, extra.end))
        }
        Task { await load(id, window: window) }
    }

    /// Fetches a calendar's window: every occurrence, plus each series once
    /// for its rule.
    private func load(_ id: String, window: DateInterval) async {
        guard !fetching.contains(id) else { return }
        fetching.insert(id)
        defer { fetching.remove(id) }
        var started: Date
        repeat {
            started = Date()
            do {
                async let occurrences = api.events(id, from: window.start, to: window.end, expanded: true)
                async let series = api.events(id, from: window.start, to: window.end, expanded: false,
                                              fields: "id,recurrence")
                let (events, masters) = try await (occurrences, series)
                var rules: [String: [EKRecurrenceRule]] = [:]
                for master in masters {
                    if let parsed = RRule.rules(master.recurrence) { rules[master.id] = parsed }
                }
                caches[id] = Cache(window: window, events: events.compactMap(stored),
                                   rules: rules, fetchedAt: started)
                retryAfter[id] = nil
                onProblem?(nil)
                onChange?()
            } catch {
                retryAfter[id] = Date().addingTimeInterval(30)
                handle(error)
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
        let from = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: dates.min() ?? Date())) ?? Date()
        let to = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: dates.max() ?? Date())) ?? Date()
        do {
            let fresh = try await api.events(id, from: from, to: to, expanded: true)
            guard var cache = caches[id] else { return }
            cache.events.removeAll { $0.start < to && ($0.end > from || $0.start >= from) }
            cache.events += fresh.compactMap(stored)
            caches[id] = cache
            onChange?()
        } catch {
            handle(error)
        }
    }

    private func handle(_ error: Error) {
        if case GoogleError.signedOut = error {
            stopWatching()
            onSignedOut?()
        } else {
            onProblem?("Couldn't reach Google — \(error.localizedDescription)")
        }
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
        do {
            let listChanged = try await loadCalendars()
            for (id, cache) in caches where !fetching.contains(id) {
                // A minute's overlap, for a clock that's a little off Google's.
                if try await api.hasChanges(id, since: cache.fetchedAt.addingTimeInterval(-60)) {
                    await load(id, window: cache.window)
                }
            }
            if listChanged { onChange?() }
            onProblem?(nil)
        } catch {
            handle(error)
        }
    }

    // MARK: - Changing

    func create(_ fields: EventFields, recurrence: EKRecurrenceRule?,
                in calendar: CalendarInfo) async throws -> String? {
        var body = Self.body(fields, calendar: self.calendar, forInsert: true)
        if let recurrence { body["recurrence"] = [RRule.line(recurrence, allDay: fields.isAllDay)] }
        editedAt[calendar.id] = Date()
        let created = try await api.insert(calendar.id, body)
        await refetch(calendar.id, around: [fields.start, fields.end], wholeWindow: recurrence != nil)
        return created.id
    }

    func update(_ item: EventItem, to fields: EventFields, recurrence: RecurrenceEdit,
                span: EKSpan) async throws -> String? {
        guard case .google(let ref) = item.origin else { return nil }
        editedAt[ref.calendarID] = Date()
        let touched = [item.start, item.end, fields.start, fields.end]

        guard item.isRecurring else {
            var body = Self.body(fields, calendar: calendar)
            var becomesSeries = false
            if case .set(let rule) = recurrence {
                body["recurrence"] = [RRule.line(rule, allDay: fields.isAllDay)]
                becomesSeries = true
            }
            let saved = try await api.patch(ref.calendarID, ref.eventID, body)
            await refetch(ref.calendarID, around: touched, wholeWindow: becomesSeries)
            return saved.id
        }

        if span == .thisEvent {
            // One date on its own: Google keeps it as an exception in the series.
            _ = try await api.patch(ref.calendarID, ref.eventID, Self.body(fields, calendar: calendar))
            await refetch(ref.calendarID, around: touched, wholeWindow: false)
            return item.seriesID
        }

        let savedID = try await changeFromHere(item, ref: ref, to: fields, recurrence: recurrence)
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
        guard let master = try await api.event(ref.calendarID, item.seriesID), master.status != "cancelled" else {
            throw GoogleError.server(404, "\(item.title) was removed in the meantime.")
        }
        let lines = master.recurrence ?? []
        let seriesStart = stored(master)?.start
        let here = ref.originalStart ?? item.start
        var body = Self.body(fields, calendar: calendar)

        if let seriesStart, here <= seriesStart {
            switch recurrence {
            case .unchanged: break
            case .clear: body["recurrence"] = [String]()
            case .set(let rule): body["recurrence"] = [RRule.line(rule, allDay: fields.isAllDay)]
            }
            return try await api.patch(ref.calendarID, master.id, body).id
        }

        switch recurrence {
        case .unchanged:
            // A series that ends after a number of times keeps only what's
            // left of the count. Cancelled dates still count, as they do in
            // the rule itself.
            var kept = lines
            if let count = RRule.count(in: lines) {
                let from = (seriesStart ?? here).addingTimeInterval(-86_400)
                let before = try await api.instances(ref.calendarID, of: master.id, from: from, to: here,
                                                     includingCancelled: true).count
                kept = RRule.setting(count: count - before, in: lines)
            }
            body["recurrence"] = kept
        case .clear:
            break
        case .set(let rule):
            body["recurrence"] = [RRule.line(rule, allDay: fields.isAllDay)]
        }

        let created = try await api.insert(ref.calendarID, Self.insertable(body))
        do {
            let ended = RRule.ending(lines, before: here, allDay: master.start?.date != nil, calendar: calendar)
            _ = try await api.patch(ref.calendarID, master.id, ["recurrence": ended])
        } catch {
            try? await api.delete(ref.calendarID, created.id)
            throw error
        }
        return created.id
    }

    func delete(_ item: EventItem, span: EKSpan) async throws {
        guard case .google(let ref) = item.origin else { return }
        editedAt[ref.calendarID] = Date()

        guard item.isRecurring, span == .futureEvents else {
            try await api.delete(ref.calendarID, ref.eventID)
            await refetch(ref.calendarID, around: [item.start, item.end], wholeWindow: false)
            return
        }

        // This and later: the whole series from its first occurrence, or the
        // series cut short before this one.
        if let master = try await api.event(ref.calendarID, item.seriesID), master.status != "cancelled" {
            let here = ref.originalStart ?? item.start
            if let seriesStart = stored(master)?.start, here <= seriesStart {
                try await api.delete(ref.calendarID, master.id)
            } else {
                let ended = RRule.ending(master.recurrence ?? [], before: here,
                                         allDay: master.start?.date != nil, calendar: calendar)
                _ = try await api.patch(ref.calendarID, master.id, ["recurrence": ended])
            }
        }
        await refetch(ref.calendarID, around: [item.start, item.end], wholeWindow: true)
    }

    /// Unsure counts as yes: a colour isn't cleared because the network
    /// dropped for a moment.
    func seriesExists(_ item: EventItem) async -> Bool {
        guard case .google(let ref) = item.origin else { return false }
        do {
            guard let series = try await api.event(ref.calendarID, item.seriesID) else { return false }
            return series.status != "cancelled"
        } catch {
            return true
        }
    }

    func occurrence(of item: EventItem, on day: Date) async -> EventItem? {
        guard case .google(let ref) = item.origin,
              let info = entries.first(where: { $0.id == ref.calendarID }) else { return nil }
        let from = calendar.startOfDay(for: day)
        let to = calendar.date(byAdding: .day, value: 1, to: from) ?? from
        let found: [GoogleEvent]
        if item.isRecurring {
            found = (try? await api.instances(ref.calendarID, of: item.seriesID, from: from, to: to)) ?? []
        } else {
            found = (try? await api.event(ref.calendarID, item.seriesID)).flatMap { $0 }.map { [$0] } ?? []
        }
        return found.lazy
            .filter { $0.status != "cancelled" }
            .compactMap(stored)
            .first { self.calendar.isDate($0.start, inSameDayAs: day) }
            .map { self.item($0, in: info, rules: self.caches[info.id]?.rules ?? [:]) }
    }

    func current(_ item: EventItem) async -> EventItem? {
        guard case .google(let ref) = item.origin,
              let info = entries.first(where: { $0.id == ref.calendarID }),
              let event = try? await api.event(ref.calendarID, ref.eventID),
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
        let mine = event.organizer?.isSelf ?? true
        return EventItem(seriesID: series,
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
                             originalStart: event.originalStartTime.flatMap(Self.date),
                             rules: rules[series] ?? RRule.rules(event.recurrence))))
    }

    /// Working-location markers are left out, as Calendar.app leaves them out.
    private func stored(_ event: GoogleEvent) -> Stored? {
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
    static func body(_ fields: EventFields, calendar: Calendar, forInsert: Bool = false) -> [String: Any] {
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
            // A named zone, which Google needs to repeat an event correctly
            // across a clock change.
            let zone = TimeZone.autoupdatingCurrent.identifier
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
