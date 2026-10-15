import Foundation

/// A category every event on this calendar falls into, and the pigment it wears.
///
/// Matching is by title, in priority order — put more specific rules first so
/// they win over broader ones. The rules live in `categories.json` in the app's
/// Application Support folder, not in the source, so each person's real
/// courses, clubs and employers stay on their own Mac. `defaultCategories`
/// below is what that file starts out as.
struct EventCategory: Codable {
    let name: String
    /// The short name Claude picks categories by, and what a `[chroma: …]`
    /// marker in an event's notes refers to.
    let slug: String
    let pigmentID: String
    let pattern: String
    /// Ignored by the app; somewhere to say why a rule is the way it is, since
    /// JSON has no comments.
    var note: String?

    init(name: String, slug: String, pigmentID: String, pattern: String, note: String? = nil) {
        self.name = name
        self.slug = slug
        self.pigmentID = pigmentID
        self.pattern = pattern
        self.note = note
    }

    private enum CodingKeys: String, CodingKey { case name, slug, color, pattern, note }

    /// Validated here rather than at match time, so a typo is reported once,
    /// against the rule that has it, instead of silently matching nothing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        slug = try container.decode(String.self, forKey: .slug)
        guard slug.range(of: #"^[a-z-]+$"#, options: .regularExpression) != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .slug, in: container,
                debugDescription: "\"\(slug)\" — slugs are lowercase letters and hyphens only.")
        }
        let color = try container.decode(String.self, forKey: .color)
        guard let pigment = EventColor.matching(color) else {
            throw DecodingError.dataCorruptedError(
                forKey: .color, in: container,
                debugDescription: "\"\(color)\" isn't one of Chroma's colours: \(EventColor.catalogue).")
        }
        pigmentID = pigment.id
        pattern = try container.decode(String.self, forKey: .pattern)
        try Categories.validate(pattern, forKey: .pattern, in: container)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(slug, forKey: .slug)
        try container.encode(pigmentID, forKey: .color)
        try container.encode(pattern, forKey: .pattern)
        try container.encodeIfPresent(note, forKey: .note)
    }
}

/// Events to keep off the grid until asked for — the toolbar's eye button.
///
/// For whatever crowds out the rest of a week: drop-in hours run by a dozen
/// TAs, say. `except` names categories that are never hidden even when the
/// title matches, so the sessions that matter can share a word with the ones
/// that don't.
struct EventFilter: Codable {
    let label: String
    let pattern: String
    var except: [String]?

    private enum CodingKeys: String, CodingKey { case label, pattern, except }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        pattern = try container.decode(String.self, forKey: .pattern)
        try Categories.validate(pattern, forKey: .pattern, in: container)
        except = try container.decodeIfPresent([String].self, forKey: .except)
    }
}

/// The whole of `categories.json`.
struct RuleSet: Codable {
    var categories: [EventCategory]
    var filter: EventFilter?
}

/// Loads `categories.json` and keeps it current.
///
/// The file is re-read whenever the app comes forward, so an edit saved in a
/// text editor takes effect the moment you switch back. A file that fails to
/// parse leaves the last good rules in place and says why in Settings, rather
/// than wiping every category over a missing comma.
@MainActor
final class RuleBook: ObservableObject {
    static let shared = RuleBook()

    @Published private(set) var rules = RuleSet(categories: Categories.defaultCategories)
    @Published private(set) var problem: String?

    let fileURL: URL
    private var loadedStamp: Date?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("Chroma", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("categories.json")
        reload()
    }

    /// Cheap enough to call on every activation: one stat, and a parse only
    /// when the file has actually changed.
    func reloadIfChanged() {
        if modificationDate != loadedStamp { reload() }
    }

    func reload() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let defaults = RuleSet(categories: Categories.defaultCategories)
            try? Data(defaults.formatted.utf8).write(to: fileURL, options: .atomic)
        }
        loadedStamp = modificationDate
        do {
            let data = try Data(contentsOf: fileURL)
            rules = try JSONDecoder().decode(RuleSet.self, from: data)
            problem = nil
        } catch {
            problem = Self.describe(error)
        }
    }

    private var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    /// Decoding errors name a coding path and little else; this turns them into
    /// something that points at the line to fix.
    private static func describe(_ error: Error) -> String {
        func path(_ keys: [CodingKey]) -> String {
            keys.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }
                .joined()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        switch error {
        case DecodingError.dataCorrupted(let context):
            // Malformed JSON: the underlying error carries the line and column.
            if let underlying = context.underlyingError as NSError?,
               let detail = underlying.userInfo[NSDebugDescriptionErrorKey] as? String {
                return "Not valid JSON — \(detail)"
            }
            let location = path(context.codingPath)
            return location.isEmpty ? context.debugDescription
                                    : "\(location): \(context.debugDescription)"
        case DecodingError.keyNotFound(let key, let context):
            let location = path(context.codingPath)
            return "\(location.isEmpty ? "The file" : location) is missing \"\(key.stringValue)\"."
        case DecodingError.typeMismatch(_, let context),
             DecodingError.valueNotFound(_, let context):
            return "\(path(context.codingPath)): \(context.debugDescription)"
        default:
            return error.localizedDescription
        }
    }
}

extension RuleSet {
    /// Hand-ordered JSON — name first, pattern last — because this file is
    /// meant to be read and edited by a person, and an encoder's key order is
    /// whatever it happens to be.
    var formatted: String {
        func quoted(_ text: String) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            return (try? encoder.encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        }
        let rows = categories.map { category in
            var fields = [
                "\"name\": \(quoted(category.name))",
                "\"slug\": \(quoted(category.slug))",
                "\"color\": \(quoted(category.pigmentID))",
                "\"pattern\": \(quoted(category.pattern))",
            ]
            if let note = category.note { fields.append("\"note\": \(quoted(note))") }
            return "    {\n      " + fields.joined(separator: ",\n      ") + "\n    }"
        }
        var text = "{\n  \"categories\": [\n" + rows.joined(separator: ",\n") + "\n  ]"
        if let filter {
            var fields = [
                "\"label\": \(quoted(filter.label))",
                "\"pattern\": \(quoted(filter.pattern))",
            ]
            if let except = filter.except {
                fields.append("\"except\": [" + except.map(quoted).joined(separator: ", ") + "]")
            }
            text += ",\n  \"filter\": {\n    " + fields.joined(separator: ",\n    ") + "\n  }"
        }
        return text + "\n}\n"
    }
}

@MainActor
enum Categories {
    /// Events the filter in `categories.json` keeps off the grid while the eye
    /// button is off. Nothing is hidden when the file has no filter.
    ///
    /// The exceptions are checked by asking the categoriser, not by matching
    /// the title — so renaming a session that matters can't accidentally hide it.
    static func isFilteredOut(_ item: EventItem) -> Bool {
        guard let filter = RuleBook.shared.rules.filter else { return false }
        if let except = filter.except, let slug = category(for: item)?.slug,
           except.contains(slug) { return false }
        return item.title.range(of: filter.pattern,
                                options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Generic placeholder rules — what `categories.json` holds on first launch.
    nonisolated static let defaultCategories: [EventCategory] = [
        EventCategory(
            name: "Deadlines & assignments", slug: "deadline", pigmentID: "red",
            pattern: #"prelim|quiz|exam\b|\bdue\b|\bdeadline\b|last day"#),
        EventCategory(
            name: "Classes", slug: "class", pigmentID: "blue",
            pattern: #"\b(lec|disc|lab)\b"#),
        EventCategory(
            name: "Professor office hours", slug: "faculty", pigmentID: "sapgreen",
            pattern: #"office hours — prof\."#),
        EventCategory(
            name: "Office hours & advising", slug: "advising", pigmentID: "green",
            pattern: #"office hours|advising|learning center|drop in"#),
        EventCategory(
            name: "Professional meetings", slug: "professional", pigmentID: "purple",
            pattern: #"interview|resume|research|grad school|career|info session"#,
            note: "Career-development events with no club or company in the title."),
        EventCategory(
            name: "Club meetings", slug: "club", pigmentID: "orange",
            pattern: #"club|project team|coffee chat|tabling"#,
            note: "Anything a student organisation runs — by host, not by topic, so every event of a given club carries one colour."),
        EventCategory(
            name: "Campus events", slug: "campus", pigmentID: "yellow",
            pattern: #"\bbreak\b|study day|convocation|welcom|orientation|open house|\btour\b|fest\b|seminar"#),
        EventCategory(
            name: "Social", slug: "social", pigmentID: "pink",
            pattern: #"birthday|dinner|picnic|party|music"#),
    ]

    static var all: [EventCategory] { RuleBook.shared.rules.categories }

    /// What Claude is told it may choose from.
    static var promptList: String {
        var seen = Set<String>()
        return all.filter { seen.insert($0.slug).inserted }
            .map { "  \($0.slug) — \($0.name)" }
            .joined(separator: "\n")
    }

    /// Rejects a pattern NSRegularExpression can't compile. Matching with an
    /// invalid one doesn't fail — it just never matches — which is the worst
    /// way to find out.
    nonisolated static func validate<Key: CodingKey>(
        _ pattern: String, forKey key: Key, in container: KeyedDecodingContainer<Key>
    ) throws {
        guard (try? NSRegularExpression(pattern: pattern)) == nil else { return }
        throw DecodingError.dataCorruptedError(
            forKey: key, in: container,
            debugDescription: "\"\(pattern)\" isn't a valid regular expression.")
    }

    /// An explicit marker beats the title rules.
    ///
    /// `[chroma: club]` in an event's notes names its category outright. It's
    /// how something with no access to the colour store — another app, a
    /// script, a person on another device — can say what an event is, and
    /// since it lives in the event, it syncs with it.
    ///
    /// A calendar given its own colour in Settings beats both: its titles are
    /// whatever its owner typed, and the calendar says more about the event than
    /// any of them.
    static func category(for item: EventItem) -> EventCategory? {
        if let pigment = item.calendarColorID {
            return EventCategory(name: item.calendarTitle, slug: "calendar",
                                 pigmentID: pigment, pattern: "")
        }
        if let marker = item.notes.range(of: #"\[chroma:\s*[a-z-]+\]"#,
                                         options: [.regularExpression, .caseInsensitive]) {
            let slug = item.notes[marker]
                .replacingOccurrences(of: #"[\[\]]|chroma:|\s"#, with: "",
                                      options: [.regularExpression, .caseInsensitive])
                .lowercased()
            if let matched = all.first(where: { $0.slug == slug }) { return matched }
        }
        return all.first {
            item.title.range(of: $0.pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    struct Count {
        let name: String
        let series: Int
    }

    struct Result {
        var counts: [Count] = []
        var unmatched: [String] = []
        var assigned = 0

        var summary: String {
            var lines = counts.map { "\($0.series)\t\($0.name)" }
            let distinct = Set(unmatched).sorted()
            if !distinct.isEmpty {
                lines.append("")
                lines.append("No rule matched, left unmarked:")
                lines.append(contentsOf: distinct.prefix(8).map { "· \($0)" })
                if distinct.count > 8 {
                    lines.append("· …and \(distinct.count - 8) more")
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Colour a set of events by category.
    ///
    /// Works per series, since a pigment belongs to a whole repeating event, and
    /// leaves anything already coloured alone — so this can run continuously
    /// without ever overwriting a choice made by hand in the inspector.
    @discardableResult
    static func apply(_ items: [EventItem], colors: EventColors,
                      overwritingManual: Bool = false) -> Result {
        var result = Result()
        var seen = Set<String>()
        var perCategory: [String: Set<String>] = [:]

        for item in items {
            guard !seen.contains(item.seriesID) else { continue }
            seen.insert(item.seriesID)
            // Checked before the rules run: this pass repeats on every reload,
            // and nearly everything it sees already has a colour.
            if !overwritingManual, colors.hasChoice(for: item.seriesID) { continue }

            guard let category = category(for: item) else {
                result.unmatched.append(item.title)
                continue
            }
            perCategory[category.name, default: []].insert(item.seriesID)

            colors.set(EventColor.named(category.pigmentID), for: item.seriesID)
            result.assigned += 1
        }

        result.counts = all.map { Count(name: $0.name, series: perCategory[$0.name]?.count ?? 0) }
        return result
    }

    /// After a calendar's own colour changes in Settings: every series on it
    /// takes the new pigment, or, when the colour was cleared, goes back to the
    /// title rules. Asked for explicitly, so hand choices on that calendar go too.
    static func recolor(_ items: [EventItem], colors: EventColors) {
        for series in Set(items.map(\.seriesID)) { colors.set(nil, for: series) }
        apply(items, colors: colors, overwritingManual: true)
    }
}
