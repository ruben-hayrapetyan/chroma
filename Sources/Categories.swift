import Foundation

/// A category every event on this calendar falls into, and the pigment it wears.
///
/// Matching is by title, in priority order — put more specific rules first so
/// they win over broader ones. `defaultCategories` below is a generic
/// placeholder so the public repo builds and runs on its own; the real,
/// personal rule set (actual courses, professors, clubs, employers) belongs in
/// `localCategories`, defined in the git-ignored `Sources/LocalConfig.swift` —
/// see `LocalConfig.swift.example`. When set, it overrides the default list
/// entirely.
struct EventCategory {
    let name: String
    /// The token Claude writes into an event's notes to name this category.
    let slug: String
    let pigmentID: String
    let pattern: String
}

enum Categories {
    /// Named because two places outside the rule list need to ask "is this the
    /// professor's own session?" — the toggle below and the colour rules above.
    static let faculty = "faculty"

    /// Drop-in help run by anyone other than the course's professor: the TA and
    /// GTA office hours, and the advising centre's drop-in hours. There are
    /// nineteen of these against five real ones, so they hide behind a toggle
    /// rather than crowding out the rest of the day.
    ///
    /// The professor's own sessions are excluded by asking the categoriser, not
    /// by matching the title — so renaming one can't accidentally hide it.
    static func isSupportingOfficeHours(_ item: EventItem) -> Bool {
        guard category(for: item)?.slug != faculty else { return false }
        return item.title.range(of: #"office hours|drop.?in"#,
                                options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Generic placeholder rules, enough to build and demo the app. Replace by
    /// setting `localCategories` in `Sources/LocalConfig.swift`.
    static let defaultCategories: [EventCategory] = [
        EventCategory(
            name: "Deadlines & assignments", slug: "deadline", pigmentID: "red",
            pattern: #"prelim|quiz|exam\b|\bdue\b|\bdeadline\b|last day"#),
        EventCategory(
            name: "Classes", slug: "class", pigmentID: "blue",
            pattern: #"\b(lec|disc|lab)\b"#),
        EventCategory(
            name: "Professor office hours", slug: faculty, pigmentID: "sapgreen",
            pattern: #"office hours — prof\."#),
        EventCategory(
            name: "Office hours & advising", slug: "advising", pigmentID: "green",
            pattern: #"office hours|advising|learning center|drop in"#),
        // Career-development events with no club or company in the title.
        EventCategory(
            name: "Professional meetings", slug: "professional", pigmentID: "purple",
            pattern: #"interview|resume|research|grad school|career|info session"#),
        // Then anything a student organisation runs — by host, not by topic, so
        // every event of a given club carries one colour.
        EventCategory(
            name: "Club meetings", slug: "club", pigmentID: "orange",
            pattern: #"club|project team|coffee chat|tabling"#),
        EventCategory(
            name: "Campus events", slug: "campus", pigmentID: "yellow",
            pattern: #"\bbreak\b|study day|convocation|welcom|orientation|open house|\btour\b|fest\b|seminar"#),
        EventCategory(
            name: "Social", slug: "social", pigmentID: "pink",
            pattern: #"birthday|dinner|picnic|party|music"#),
    ]

    /// `localCategories` (git-ignored) takes over entirely when set.
    static var all: [EventCategory] { localCategories ?? defaultCategories }

    /// What Claude is told it may choose from.
    static var promptList: String {
        var seen = Set<String>()
        return all.filter { seen.insert($0.slug).inserted }
            .map { "  \($0.slug) — \($0.name)" }
            .joined(separator: "\n")
    }

    /// An explicit marker beats the title rules.
    ///
    /// Claude writes `[chroma: club]` into an event's notes when it creates one,
    /// because it can only reach the calendar through AppleScript and has no way
    /// to touch the app's colour store directly. A marker in the event itself is
    /// the one channel that survives that boundary — and it syncs, so the
    /// category travels with the event.
    static func category(for item: EventItem) -> EventCategory? {
        if let marker = item.notes.range(of: #"\[chroma:\s*[a-z-]+\]"#,
                                         options: [.regularExpression, .caseInsensitive]) {
            let slug = item.notes[marker]
                .replacingOccurrences(of: #"[\[\]]|chroma:|\s"#, with: "",
                                      options: [.regularExpression, .caseInsensitive])
                .lowercased()
            if let matched = all.first(where: { $0.slug == slug }) { return matched }
        }
        let title = item.title.lowercased()
        return all.first { title.range(of: $0.pattern, options: [.regularExpression]) != nil }
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
    @MainActor
    @discardableResult
    static func apply(_ items: [EventItem], colors: EventColors,
                      overwritingManual: Bool = false) -> Result {
        var result = Result()
        var seen = Set<String>()
        var perCategory: [String: Set<String>] = [:]

        for item in items {
            guard !seen.contains(item.seriesID) else { continue }
            seen.insert(item.seriesID)

            guard let category = category(for: item) else {
                result.unmatched.append(item.title)
                continue
            }
            perCategory[category.name, default: []].insert(item.seriesID)

            if !overwritingManual, colors.assigned(for: item.seriesID) != nil { continue }
            colors.set(EventColor.named(category.pigmentID), for: item.seriesID)
            result.assigned += 1
        }

        result.counts = all.map { Count(name: $0.name, series: perCategory[$0.name]?.count ?? 0) }
        return result
    }
}
