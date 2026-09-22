import Foundation

/// One event placed in the day/week grid, with the column it occupies.
///
/// Overlapping events share the width of their cluster, the way Google
/// Calendar's day view does: three events at the same hour each get a third of
/// the column, and an event overlapping nothing keeps the full width.
struct PositionedEvent: Identifiable {
    let item: EventItem
    let column: Int
    let columnCount: Int

    var id: String { item.id }
}

enum EventLayout {
    /// Assign columns to a single day's timed events.
    static func position(_ items: [EventItem]) -> [PositionedEvent] {
        let sorted = items.sorted { lhs, rhs in
            lhs.start == rhs.start ? lhs.end > rhs.end : lhs.start < rhs.start
        }

        var result: [PositionedEvent] = []
        var cluster: [EventItem] = []
        var clusterEnd = Date.distantPast

        // A cluster is a run of events that transitively overlap. It closes as
        // soon as an event starts after everything so far has ended.
        for item in sorted {
            if !cluster.isEmpty && item.start >= clusterEnd {
                result += assignColumns(cluster)
                cluster = []
                clusterEnd = .distantPast
            }
            cluster.append(item)
            clusterEnd = max(clusterEnd, item.end)
        }
        result += assignColumns(cluster)
        return result
    }

    /// Greedy column packing: an event takes the first column free at its start.
    private static func assignColumns(_ cluster: [EventItem]) -> [PositionedEvent] {
        guard !cluster.isEmpty else { return [] }

        var columnEnds: [Date] = []
        var placements: [(EventItem, Int)] = []

        for item in cluster {
            if let free = columnEnds.firstIndex(where: { $0 <= item.start }) {
                columnEnds[free] = item.end
                placements.append((item, free))
            } else {
                columnEnds.append(item.end)
                placements.append((item, columnEnds.count - 1))
            }
        }

        let width = columnEnds.count
        return placements.map { PositionedEvent(item: $0.0, column: $0.1, columnCount: width) }
    }
}
