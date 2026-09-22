import Combine
import Foundation
import SwiftUI

/// A pigment an event can be marked with.
///
/// Named after actual pigments rather than "Red / Orange / Yellow". The app is
/// called Chroma and its one feature is colour as meaning; a swatch card names
/// its colours, and naming them properly is most of what makes choosing one
/// feel like a decision rather than a setting.
///
/// The `id` values are deliberately unchanged from the first version — they are
/// the keys in `colors.json`, and renaming them would silently orphan every
/// colour already assigned.
struct EventColor: Identifiable, Hashable {
    let id: String
    let name: String
    let color: Color

    static let palette: [EventColor] = [
        EventColor(id: "red",      name: "Vermilion",    color: rgb(0xC2402D)),
        EventColor(id: "orange",   name: "Amber",        color: rgb(0xCE7C22)),
        EventColor(id: "yellow",   name: "Ochre",        color: rgb(0xBE9A1F)),
        EventColor(id: "green",    name: "Verdigris",    color: rgb(0x34877A)),
        EventColor(id: "sapgreen", name: "Sap Green",    color: rgb(0x74A03A)),
        EventColor(id: "blue",     name: "Cerulean",     color: rgb(0x2A6C9C)),
        EventColor(id: "purple",   name: "Ultramarine",  color: rgb(0x4A48A0)),
        EventColor(id: "pink",     name: "Magenta",      color: rgb(0xA63F76)),
        EventColor(id: "graphite", name: "Payne's Grey", color: rgb(0x6E7A8C)),
    ]

    static func named(_ id: String?) -> EventColor? {
        guard let id else { return nil }
        return palette.first { $0.id == id }
    }

    static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB,
              red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}

/// Stores per-event pigments alongside the calendar rather than inside it.
///
/// Two consequences worth knowing, neither avoidable: the assignments live on
/// this Mac only, and because they key on the event's series identifier, a
/// repeating event takes one pigment for every occurrence.
@MainActor
final class EventColors: ObservableObject {
    @Published private(set) var assignments: [String: String] = [:]

    /// Events nobody has marked yet.
    ///
    /// A neutral slate, not a colour: if untagged events were coloured, colour
    /// would stop meaning anything, which is the one thing this app cannot
    /// afford.
    static let fallback = EventColor(id: "default", name: "Unmarked",
                                     color: EventColor.rgb(0x8A9199))

    private let fileURL: URL

    init(storeURL: URL? = nil) {
        if let storeURL {
            self.fileURL = storeURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask)[0]
            let folder = support.appendingPathComponent("Chroma", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.fileURL = folder.appendingPathComponent("colors.json")
        }
        load()
    }

    func color(for seriesID: String) -> Color {
        EventColor.named(assignments[seriesID])?.color ?? Self.fallback.color
    }

    func assigned(for seriesID: String) -> EventColor? {
        EventColor.named(assignments[seriesID])
    }

    func set(_ color: EventColor?, for seriesID: String) {
        if let color {
            assignments[seriesID] = color.id
        } else {
            assignments.removeValue(forKey: seriesID)
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        assignments = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(assignments) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
