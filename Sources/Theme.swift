import AppKit
import SwiftUI

/// Design tokens for the whole app.
///
/// The governing idea: **the chrome refuses colour so the content can own it.**
/// Chroma exists because per-event colour carries meaning, and a tinted
/// interface competes with the very thing it frames. So every structural
/// element here is ink or paper, and saturation is spent exclusively on events —
/// with one exception, the red now-line, because "you are here" is the only
/// other thing worth a hue.
///
/// The vocabulary is a printed course timetable: serif headings, a monospaced
/// time gutter, hairline rules, and events set as paper blocks with a pigment
/// spine down one edge, the way a swatch card shows its colour.
enum Theme {

    // MARK: - Ground

    /// Warm paper behind the window. Not neutral grey: paper has a temperature.
    static let paper = dynamic(light: 0xF7F5F1, dark: 0x121417)

    /// The grid and the panes sit on this.
    static let panel = dynamic(light: 0xFFFFFF, dark: 0x1B1E22)

    /// The sidebar, one step back from the panel.
    static let recessed = dynamic(light: 0xF2EFEA, dark: 0x16191C)

    // MARK: - Ink

    /// Primary text, and the accent. Chrome is monochrome by design; anywhere
    /// another app would put a brand colour, Chroma puts ink.
    static let ink = dynamic(light: 0x16181C, dark: 0xECEEF1)
    static let graphite = dynamic(light: 0x6A6F77, dark: 0x9298A1)
    static let faint = dynamic(light: 0x9AA0A8, dark: 0x6B717A)

    /// Kept under this name so every call site reads consistently: the accent
    /// simply *is* ink.
    static var accent: Color { ink }

    /// The single reserved hue. Only the now-line uses it.
    static let now = Color(red: 0.78, green: 0.20, blue: 0.16)

    // MARK: - Rules

    static var hairline: Color { ink.opacity(0.07) }
    static var rule: Color { ink.opacity(0.13) }
    static var wash: Color { ink.opacity(0.045) }
    static var outsideMonth: Color { ink.opacity(0.028) }
    static var weekendWash: Color { ink.opacity(0.022) }

    // MARK: - Metrics

    static let hourHeight: CGFloat = 54
    static let cardRadius: CGFloat = 10
    static let chipRadius: CGFloat = 4
    static let spine: CGFloat = 3          // the pigment edge on every event
    static let gutterWidth: CGFloat = 62
    static let sidebarWidth: CGFloat = 236

    // MARK: - Type
    //
    // Three roles, each doing one job: a serif for headings, a monospace for
    // anything that is a time or a count, and the system sans for interface
    // text. The serif gives the app a voice no other Mac calendar has; the
    // monospace is not decoration — times and day numbers are tabular data and
    // they align.

    static let display = Font.system(size: 21, weight: .semibold, design: .serif)
    static let paneTitle = Font.system(size: 16, weight: .semibold, design: .serif)
    static let eyebrow = Font.system(size: 10, weight: .semibold).width(.expanded)

    static func time(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // MARK: - Lift

    static let liftRadius: CGFloat = 18
    static var lift: Color { Color.black.opacity(0.20) }

    /// Resolves per appearance, so light and dark are both deliberate rather
    /// than one being a washed-out inversion of the other.
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
                           green: Double((hex >> 8) & 0xFF) / 255,
                           blue: Double(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }
}

/// A flat panel with a hairline edge. No drop shadows in the layout — depth is
/// carried by the paper/panel tone difference instead.
struct Card: ViewModifier {
    var radius: CGFloat = Theme.cardRadius

    func body(content: Content) -> some View {
        content
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.rule, lineWidth: 0.5)
            )
    }
}

extension View {
    func card(radius: CGFloat = Theme.cardRadius) -> some View {
        modifier(Card(radius: radius))
    }
}

/// Day / Week / Month / Year as ruled tabs.
///
/// A filled pill would put a block of colour in the toolbar, which is the one
/// thing this design will not do. An ink underline marks the active view using
/// the same hairline vocabulary as the grid it controls.
struct ModePicker: View {
    @Binding var selection: ViewMode
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ViewMode.allCases) { mode in
                let isOn = selection == mode
                VStack(spacing: 5) {
                    Text(mode.title)
                        .font(Theme.ui(12, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? Theme.accent : Theme.graphite)
                    Group {
                        if isOn {
                            Capsule().fill(Theme.accent)
                                .matchedGeometryEffect(id: "mode", in: namespace)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(height: 1.5)
                }
                .padding(.horizontal, 9)
                .padding(.top, 3)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.snappy(duration: 0.22)) { selection = mode }
                }
            }
        }
    }
}

/// A square icon button with a hairline edge — the chevrons and toolbar glyphs.
struct GlyphButton: View {
    let systemName: String
    var help: String = ""
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.8))
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Theme.wash : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.rule, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
