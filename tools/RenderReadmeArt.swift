// Renders README art: a static hero (week view) and four frames (Day, Week,
// Month, Year) used as an animated GIF. Built from the app's real design
// tokens (Theme.swift, EventColors.swift), with invented sample events —
// never live calendar data. Run as a script:
//   swift tools/RenderReadmeArt.swift <output-dir>
import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write("usage: RenderReadmeArt.swift <output-dir>\n".data(using: .utf8)!)
    exit(1)
}
let outputDir = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

// Theme.swift, light appearance.
let paper = rgb(0xF7F5F1)
let panel = rgb(0xFFFFFF)
let ink = rgb(0x16181C)
let graphite = rgb(0x6A6F77)
let faint = rgb(0x9AA0A8)
let rule = ink.withAlphaComponent(0.13)
let hairline = ink.withAlphaComponent(0.07)
let outsideMonth = ink.withAlphaComponent(0.028)
let now = rgb(0xC7332A)

// EventColors.swift palette.
let vermilion = rgb(0xC2402D)
let amber = rgb(0xCE7C22)
let ochre = rgb(0xBE9A1F)
let verdigris = rgb(0x34877A)
let sapGreen = rgb(0x74A03A)
let cerulean = rgb(0x2A6C9C)
let ultramarine = rgb(0x4A48A0)
let magenta = rgb(0xA63F76)
let palette = [vermilion, amber, ochre, verdigris, sapGreen, cerulean, ultramarine, magenta]

let width: CGFloat = 1400
let height: CGFloat = 860

func serif(_ size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    let descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
    return NSFont(descriptor: descriptor, size: size) ?? base
}
func mono(_ size: CGFloat, weight: NSFont.Weight = .medium) -> NSFont {
    .monospacedSystemFont(ofSize: size, weight: weight)
}
func ui(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
    .systemFont(ofSize: size, weight: weight)
}

func draw(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
    NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]).draw(at: point)
}
func drawCentered(_ text: String, centerX: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
    let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    s.draw(at: NSPoint(x: centerX - s.size().width / 2, y: y))
}

/// Wordmark, tagline, mode label and the pigment legend — shared by every frame.
func drawHeader(mode: String) {
    draw("Chroma", at: NSPoint(x: 48, y: height - 78), font: serif(30), color: ink)
    draw("A macOS calendar with per-event colour", at: NSPoint(x: 48, y: height - 110),
         font: ui(14), color: graphite)

    let legend: [(String, NSColor)] = [
        ("Vermilion", vermilion), ("Amber", amber), ("Ochre", ochre), ("Verdigris", verdigris),
        ("Sap Green", sapGreen), ("Cerulean", cerulean), ("Ultramarine", ultramarine), ("Magenta", magenta),
    ]
    var lx = width - 48
    for (name, color) in legend.reversed() {
        let font = ui(11)
        let sz = NSAttributedString(string: name, attributes: [.font: font]).size()
        lx -= sz.width
        draw(name, at: NSPoint(x: lx, y: height - 72), font: font, color: graphite)
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: lx - 16, y: height - 69, width: 9, height: 9)).fill()
        lx -= 30
    }

    // Day / Week / Month / Year tabs, ink underline marking the active one.
    let modes = ["Day", "Week", "Month", "Year"]
    var tx: CGFloat = 48
    let ty = height - 148
    for label in modes {
        let isOn = label == mode
        draw(label, at: NSPoint(x: tx, y: ty), font: ui(13, weight: isOn ? .semibold : .regular),
             color: isOn ? ink : faint)
        let w = NSAttributedString(string: label, attributes: [.font: ui(13)]).size().width
        if isOn {
            ink.setFill()
            NSRect(x: tx, y: ty - 8, width: w, height: 1.5).fill()
        }
        tx += w + 26
    }

    draw("Every event carries one colour, chosen by rule or by hand. Sample data — not a real calendar.",
         at: NSPoint(x: 48, y: 30), font: ui(11), color: faint)
}

let gridRect = NSRect(x: 48, y: 64, width: width - 96, height: height - 260)

func panelBackground() {
    panel.setFill()
    NSBezierPath(roundedRect: gridRect, xRadius: 14, yRadius: 14).fill()
}
func panelBorder() {
    rule.setStroke()
    let border = NSBezierPath(roundedRect: gridRect, xRadius: 14, yRadius: 14)
    border.lineWidth = 0.5
    border.stroke()
}

struct Chip { let startHour: Double; let endHour: Double; let title: String; let color: NSColor }

/// Day and Week share one hour grid; `columns` is 1 for Day, 7 for Week.
func drawTimeGrid(dayLabels: [String], dayNumbers: [Int], todayIndex: Int?,
                  events: [[Chip]], nowColumn: Int?, nowHour: Double) {
    let gutter: CGFloat = 64
    let columns = dayLabels.count
    let colWidth = (gridRect.width - gutter) / CGFloat(columns)
    let hours = 8...20
    let headerHeight: CGFloat = 40
    let hourHeight = (gridRect.height - headerHeight) / CGFloat(hours.count)

    panelBackground()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: gridRect, xRadius: 14, yRadius: 14).addClip()

    for (i, day) in dayLabels.enumerated() {
        let cx = gridRect.minX + gutter + colWidth * CGFloat(i) + colWidth / 2
        drawCentered(day, centerX: cx, y: gridRect.maxY - 20, font: ui(10, weight: .semibold), color: faint)
        drawCentered("\(dayNumbers[i])", centerX: cx, y: gridRect.maxY - 38, font: mono(13, weight: .semibold),
                     color: i == todayIndex ? ink : graphite)
    }
    hairline.setStroke()
    let headerLine = NSBezierPath()
    headerLine.move(to: NSPoint(x: gridRect.minX, y: gridRect.maxY - headerHeight))
    headerLine.line(to: NSPoint(x: gridRect.maxX, y: gridRect.maxY - headerHeight))
    headerLine.lineWidth = 1
    headerLine.stroke()

    let body = NSRect(x: gridRect.minX, y: gridRect.minY, width: gridRect.width, height: gridRect.height - headerHeight)

    for (i, hour) in hours.enumerated() {
        let y = body.maxY - hourHeight * CGFloat(i)
        hairline.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: body.minX, y: y))
        line.line(to: NSPoint(x: body.maxX, y: y))
        line.lineWidth = 0.5
        line.stroke()
        let label = hour == 12 ? "12 PM" : (hour > 12 ? "\(hour - 12) PM" : "\(hour) AM")
        draw(label, at: NSPoint(x: body.minX + 8, y: y - 14), font: mono(10), color: faint)
    }

    if columns > 1 {
        for i in [5, 6] where i < columns {
            outsideMonth.setFill()
            NSRect(x: body.minX + gutter + colWidth * CGFloat(i), y: body.minY,
                   width: colWidth, height: body.height).fill()
        }
    }

    func y(for hour: Double) -> CGFloat { body.maxY - hourHeight * CGFloat(hour - Double(hours.lowerBound)) }

    for (day, chips) in events.enumerated() {
        for chip in chips {
            let colX = body.minX + gutter + colWidth * CGFloat(day) + 4
            let top = y(for: chip.startHour)
            let bottom = y(for: chip.endHour)
            let rect = NSRect(x: colX, y: bottom, width: colWidth - 8, height: top - bottom)

            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            panel.setFill(); path.fill()
            chip.color.withAlphaComponent(0.10).setFill(); path.fill()
            chip.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height),
                        xRadius: 1.5, yRadius: 1.5).fill()
            if rect.height > 16 {
                draw(chip.title, at: NSPoint(x: rect.minX + 9, y: rect.maxY - 14),
                     font: ui(10, weight: .medium), color: ink)
            }
        }
    }

    if let nowColumn {
        let nowY = y(for: nowHour)
        now.setStroke()
        let nowLine = NSBezierPath()
        nowLine.move(to: NSPoint(x: body.minX + gutter + colWidth * CGFloat(nowColumn), y: nowY))
        nowLine.line(to: NSPoint(x: body.maxX, y: nowY))
        nowLine.lineWidth = 1.5
        nowLine.stroke()
        now.setFill()
        NSBezierPath(ovalIn: NSRect(x: body.minX + gutter + colWidth * CGFloat(nowColumn) - 4,
                                    y: nowY - 4, width: 8, height: 8)).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    panelBorder()
}

/// A six-week grid, each day a mini cell with up to three pigment dashes.
func drawMonthGrid(monthDays: [[Int?]], today: (row: Int, col: Int), marks: [[[NSColor]]]) {
    let days = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
    let headerHeight: CGFloat = 32
    let colWidth = gridRect.width / 7
    let rowHeight = (gridRect.height - headerHeight) / CGFloat(monthDays.count)

    panelBackground()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: gridRect, xRadius: 14, yRadius: 14).addClip()

    for (i, day) in days.enumerated() {
        drawCentered(day, centerX: gridRect.minX + colWidth * CGFloat(i) + colWidth / 2,
                    y: gridRect.maxY - 20, font: ui(10, weight: .semibold), color: faint)
    }
    hairline.setStroke()
    let headerLine = NSBezierPath()
    headerLine.move(to: NSPoint(x: gridRect.minX, y: gridRect.maxY - headerHeight))
    headerLine.line(to: NSPoint(x: gridRect.maxX, y: gridRect.maxY - headerHeight))
    headerLine.lineWidth = 1
    headerLine.stroke()

    for (row, week) in monthDays.enumerated() {
        for (col, dayNumber) in week.enumerated() {
            let x = gridRect.minX + colWidth * CGFloat(col)
            let y = gridRect.maxY - headerHeight - rowHeight * CGFloat(row + 1)
            let cell = NSRect(x: x, y: y, width: colWidth, height: rowHeight)

            hairline.setStroke()
            NSBezierPath(rect: cell).stroke()

            guard let dayNumber else { continue }
            let isToday = row == today.row && col == today.col
            if isToday {
                ink.setFill()
                NSBezierPath(ovalIn: NSRect(x: cell.minX + 8, y: cell.maxY - 26, width: 18, height: 18)).fill()
                drawCentered("\(dayNumber)", centerX: cell.minX + 17, y: cell.maxY - 21,
                            font: mono(11, weight: .semibold), color: panel)
            } else {
                draw("\(dayNumber)", at: NSPoint(x: cell.minX + 8, y: cell.maxY - 20),
                     font: mono(11), color: graphite)
            }

            let dashes = marks[row][col]
            var dx = cell.minX + 8
            for color in dashes.prefix(4) {
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: dx, y: cell.minY + 8, width: 14, height: 4),
                            xRadius: 2, yRadius: 2).fill()
                dx += 18
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    panelBorder()
}

/// Twelve mini months, three columns by four rows.
func drawYearGrid(highlightMonth: Int) {
    let cols = 4, rows = 3
    let cellW = gridRect.width / CGFloat(cols)
    let cellH = gridRect.height / CGFloat(rows)
    let months = ["January", "February", "March", "April", "May", "June",
                  "July", "August", "September", "October", "November", "December"]

    panelBackground()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: gridRect, xRadius: 14, yRadius: 14).addClip()

    for index in 0..<12 {
        let row = index / cols, col = index % cols
        let cell = NSRect(x: gridRect.minX + cellW * CGFloat(col),
                          y: gridRect.maxY - cellH * CGFloat(row + 1),
                          width: cellW, height: cellH).insetBy(dx: 14, dy: 12)

        hairline.setStroke()
        NSBezierPath(rect: cell.insetBy(dx: -14, dy: -12)).stroke()

        let isHighlighted = index == highlightMonth
        draw(months[index], at: NSPoint(x: cell.minX, y: cell.maxY - 16),
             font: ui(11, weight: isHighlighted ? .semibold : .regular), color: isHighlighted ? ink : graphite)

        // A miniature 5×6 dot grid standing in for the day cells.
        let dotCols = 7, dotRows = 5
        let dotArea = NSRect(x: cell.minX, y: cell.minY, width: cell.width, height: cell.height - 26)
        let dotW = dotArea.width / CGFloat(dotCols)
        let dotH = dotArea.height / CGFloat(dotRows)
        var seed = index * 17 + 3
        func nextRandom() -> Int { seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF; return seed }

        for r in 0..<dotRows {
            for c in 0..<dotCols {
                let cx = dotArea.minX + dotW * CGFloat(c) + dotW / 2
                let cy = dotArea.maxY - dotH * CGFloat(r) - dotH / 2
                let roll = nextRandom() % 10
                if roll < 3 {
                    palette[nextRandom() % palette.count].withAlphaComponent(0.75).setFill()
                    NSBezierPath(ovalIn: NSRect(x: cx - 2, y: cy - 2, width: 4, height: 4)).fill()
                } else {
                    faint.withAlphaComponent(0.4).setFill()
                    NSBezierPath(ovalIn: NSRect(x: cx - 1, y: cy - 1, width: 2, height: 2)).fill()
                }
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    panelBorder()
}

func render(_ name: String, mode: String, _ body: () -> Void) {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    paper.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    drawHeader(mode: mode)
    body()
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return }
    bitmap.size = NSSize(width: width, height: height)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: outputDir.appendingPathComponent(name))
    print("wrote \(name)")
}

// MARK: - Week

let weekEvents: [[Chip]] = [
    [Chip(startHour: 9, endHour: 10.5, title: "Team Standup", color: cerulean),
     Chip(startHour: 13, endHour: 14, title: "Design Review", color: ultramarine)],
    [Chip(startHour: 10, endHour: 12, title: "Deep Work", color: sapGreen),
     Chip(startHour: 15, endHour: 16, title: "Deadline: Draft", color: vermilion)],
    [Chip(startHour: 9.5, endHour: 11, title: "Project Sync", color: cerulean),
     Chip(startHour: 17, endHour: 18, title: "Gym", color: magenta)],
    [Chip(startHour: 14, endHour: 16, title: "Workshop", color: amber)],
    [Chip(startHour: 11, endHour: 12, title: "1:1", color: ultramarine),
     Chip(startHour: 18.5, endHour: 20, title: "Dinner", color: magenta)],
    [Chip(startHour: 10, endHour: 11.5, title: "Study Session", color: verdigris)],
    [Chip(startHour: 11, endHour: 13, title: "Long Run", color: ochre)],
]
render("frame_week.png", mode: "Week") {
    drawTimeGrid(dayLabels: ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"],
                dayNumbers: [9, 10, 11, 12, 13, 14, 15], todayIndex: 2,
                events: weekEvents, nowColumn: 2, nowHour: 12.4)
}

// MARK: - Day

let dayEvents: [[Chip]] = [[
    Chip(startHour: 8.5, endHour: 9, title: "Coffee", color: ochre),
    Chip(startHour: 9, endHour: 10, title: "Team Standup", color: cerulean),
    Chip(startHour: 10.25, endHour: 12, title: "Deep Work", color: sapGreen),
    Chip(startHour: 13, endHour: 14, title: "Design Review", color: ultramarine),
    Chip(startHour: 14.5, endHour: 15.5, title: "1:1 with Manager", color: ultramarine),
    Chip(startHour: 17, endHour: 18, title: "Gym", color: magenta),
    Chip(startHour: 18.5, endHour: 20, title: "Dinner", color: magenta),
]]
render("frame_day.png", mode: "Day") {
    drawTimeGrid(dayLabels: ["WEDNESDAY"], dayNumbers: [11], todayIndex: 0,
                events: dayEvents, nowColumn: 0, nowHour: 12.4)
}

// MARK: - Month

func makeMonth() -> [[Int?]] {
    // November-shaped: starts on a Sunday, 30 days, six rows for a stable grid.
    var weeks: [[Int?]] = []
    var day = 1
    for row in 0..<6 {
        var week: [Int?] = []
        for _ in 0..<7 {
            week.append(day <= 30 ? day : nil)
            if day <= 30 { day += 1 }
        }
        weeks.append(week)
        if row == 5 { break }
    }
    return weeks
}
let monthDays = makeMonth()
var monthMarks: [[[NSColor]]] = monthDays.map { $0.map { _ in [] } }
let sampleMarks: [(Int, Int, [NSColor])] = [
    (1, 1, [cerulean]), (1, 3, [vermilion, sapGreen]), (1, 5, [magenta]),
    (2, 0, [amber]), (2, 2, [cerulean, ultramarine]), (2, 4, [verdigris]), (2, 6, [ochre]),
    (3, 1, [sapGreen]), (3, 3, [ultramarine, magenta]), (3, 5, [cerulean]),
    (4, 2, [vermilion]), (4, 4, [amber, verdigris]),
]
for (row, col, colors) in sampleMarks { monthMarks[row][col] = colors }
render("frame_month.png", mode: "Month") {
    drawMonthGrid(monthDays: monthDays, today: (row: 2, col: 3), marks: monthMarks)
}

// MARK: - Year

render("frame_year.png", mode: "Year") {
    drawYearGrid(highlightMonth: 10)
}

// MARK: - Static hero for the top of the README (week view).

if let weekFrame = try? Data(contentsOf: outputDir.appendingPathComponent("frame_week.png")) {
    try? weekFrame.write(to: outputDir.appendingPathComponent("hero.png"))
}
