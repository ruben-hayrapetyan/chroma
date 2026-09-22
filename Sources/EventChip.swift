import SwiftUI

/// The signature treatment: every event, everywhere in the app, is a pale paper
/// block with a solid pigment spine down its left edge.
///
/// Tinted fills — the Google and Apple approach — wash the colour out at the
/// small sizes a month grid forces, and turn a dense week into a smear. A solid
/// spine holds its hue at three pixels wide, so the colour stays readable no
/// matter how little room the block has.
struct EventChip: View {
    @EnvironmentObject var colors: EventColors
    let item: EventItem
    var compact = false
    /// Defaults to the month grid's tight row. The all-day band passes the
    /// height of a half-hour block, so its entries carry the same weight as the
    /// timed events below them.
    var height: CGFloat = 17

    var body: some View {
        let pigment = colors.color(for: item.seriesID)
        HStack(spacing: 5) {
            Rectangle()
                .fill(pigment)
                .frame(width: Theme.spine)

            HStack(spacing: 4) {
                if !item.isAllDay && !compact {
                    Text(shortTime)
                        .font(Theme.time(9.5))
                        .foregroundStyle(Theme.graphite)
                }
                Text(item.title)
                    .font(Theme.ui(11, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(height > 30 ? 2 : 1)
                Spacer(minLength: 0)
            }
            .padding(.trailing, 4)
        }
        .frame(height: height)
        .background(pigment.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous))
    }

    /// "9" and "9:30" — the grid has no room for meridiems.
    private var shortTime: String {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: item.start) % 12
        let minute = calendar.component(.minute, from: item.start)
        let display = hour == 0 ? 12 : hour
        return minute == 0 ? "\(display)" : String(format: "%d:%02d", display, minute)
    }
}

/// The full-size block in the day and week grids. Same spine, more room.
struct EventBlock: View {
    @EnvironmentObject var colors: EventColors
    let item: EventItem
    let height: CGFloat

    var body: some View {
        let pigment = colors.color(for: item.seriesID)
        HStack(spacing: 0) {
            Rectangle()
                .fill(pigment)
                .frame(width: Theme.spine)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(Theme.ui(11, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(height > 36 ? 2 : 1)
                // Under about three-quarters of an hour there is only room for
                // the title, so time and place drop away in that order.
                if height > 36 {
                    Text(timeRange)
                        .font(Theme.time(9.5))
                        .foregroundStyle(Theme.graphite)
                }
                if height > 60 && !item.location.isEmpty {
                    Text(item.location)
                        .font(Theme.ui(9.5))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
            .padding(.trailing, 4)
            .padding(.vertical, 3)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(pigment.opacity(0.11))
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous))
    }

    private var timeRange: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        let tail = DateFormatter()
        tail.dateFormat = "h:mm a"
        return "\(formatter.string(from: item.start))–\(tail.string(from: item.end))"
    }
}
