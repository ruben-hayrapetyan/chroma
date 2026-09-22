import Combine
import Foundation
import SwiftUI

/// Runs the Claude CLI in print mode and streams its output back.
///
/// Claude gets **no tools at all**. It reads a snapshot of the calendar handed to
/// it in the prompt and replies with a plan; Chroma applies that plan through
/// EventKit. Driving Calendar.app over AppleScript was what used to launch it
/// and leave it sitting in the Dock, and it made every date locale-dependent —
/// both problems disappear along with the tool access.
@MainActor
final class ClaudeRunner: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var transcript = ""
    @Published private(set) var failure: String?

    private var process: Process?

    /// Where the CLI might live. Checked in order; the app has no login shell,
    /// so PATH cannot be relied on.
    private static let candidatePaths = [
        "\(NSHomeDirectory())/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    /// A neutral, unprotected directory for the CLI to start in.
    static var workingFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("Chroma/session", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static var executable: URL? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    func run(prompt: String, day: Date, calendarName: String, snapshot: String) {
        guard !isRunning else { return }
        guard let executable = Self.executable else {
            failure = "Couldn't find the claude CLI. Looked in ~/.local/bin, /opt/homebrew/bin and /usr/local/bin."
            return
        }

        transcript = ""
        failure = nil
        isRunning = true

        let task = Process()
        task.executableURL = executable
        task.arguments = [
            "-p", Self.fullPrompt(request: prompt, day: day,
                                  calendarName: calendarName, snapshot: snapshot),
            "--output-format", "text",
        ]
        // Run from a folder Chroma owns, not the home directory. The CLI looks
        // around its working directory on startup, and from home that means
        // brushing against Downloads, Documents and Desktop — each of which
        // makes macOS raise a file-access prompt.
        task.currentDirectoryURL = Self.workingFolder

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        task.environment = environment

        // Without this the CLI waits on stdin it will never get, and warns
        // about it three seconds in.
        task.standardInput = FileHandle.nullDevice

        let output = Pipe()
        task.standardOutput = output
        task.standardError = output

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            Task { @MainActor in self?.transcript += text }
        }

        task.terminationHandler = { [weak self] finished in
            output.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.isRunning = false
                self.process = nil
                if finished.terminationStatus != 0 && self.transcript.isEmpty {
                    self.failure = "Claude exited with status \(finished.terminationStatus)."
                }
            }
        }

        do {
            try task.run()
            process = task
        } catch {
            isRunning = false
            failure = error.localizedDescription
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
        isRunning = false
    }

    /// Replaces the transcript with just the prose, once the plan has been
    /// lifted out of it.
    func showProse(_ text: String) { transcript = text }

    /// The request, the calendar, and the shape of the reply.
    private static func fullPrompt(request: String, day: Date,
                                   calendarName: String, snapshot: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"

        return """
        You are the assistant inside Chroma, a macOS calendar app, working on the \
        calendar named "\(calendarName)".

        You have NO tools. Do not try to run commands or read files. You act by \
        returning a plan, which the app applies for you through EventKit.

        Today is \(formatter.string(from: Date())). The user is looking at \
        \(formatter.string(from: day)). Resolve anything relative — "tomorrow", \
        "next Friday" — against the day they are looking at.

        Their calendar for the year around that day — five months back, seven \
        ahead — numbered so you can refer to an entry. A line marked "repeats" \
        stands for the whole series and shows its first occurrence; changing one \
        changes the series.
        \(snapshot)

        Categories — every event you create needs one, chosen by you unless the \
        user names it. Use the slug:
        \(Categories.promptList)

        Reply with one short sentence saying what you did or answering the \
        question, then a single JSON block:

        ```json
        {"operations": []}
        ```

        Each operation is one of:
        - {"op":"create","title":"…","start":"2026-09-08T15:00","end":"2026-09-08T16:00",
           "category":"advising","location":"…","notes":"…","allDay":false}
        - {"op":"update","ref":12,"start":"…","title":"…"}  — ref is the #n above; \
        include only the fields that change
        - {"op":"delete","ref":12}

        A repeating event can be changed one occurrence at a time. Add the dates \
        to either operation and only those dates are affected:
        - {"op":"delete","ref":12,"occurrences":["2026-09-02","2026-09-09","2026-09-16"]}
        - {"op":"update","ref":12,"occurrences":["2026-09-09"],"start":"2026-09-09T14:00"}
        Leave "occurrences" off and the change applies to the whole series, so \
        include it whenever the user names particular dates. Work the dates out \
        yourself — if they ask for "Wednesdays from Sept 2 to 16", list them.

        Times are local, "YYYY-MM-DDTHH:MM", or "YYYY-MM-DD" when allDay is true.

        To repeat an event, add a recurrence to a create:
        "recurrence":{"freq":"weekly","interval":1,"until":"2026-12-19","byDay":["MO","WE"]}
        freq is daily, weekly, monthly or yearly. Use "until" for "until <date>" \
        (inclusive) or "count" for a fixed number of occurrences. byDay is weekly \
        only, and takes MO TU WE TH FR SA SU.

        If nothing needs changing — a question, or a request you cannot fulfil — \
        return {"operations": []} and say so in the sentence. Never re-create an \
        event that is already in the list above.

        Request: \(request)
        """
    }
}

/// The in-app Claude popup.
struct ClaudePanel: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var colors: EventColors
    @StateObject private var runner = ClaudeRunner()
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    /// What was last sent. The field clears on send, so this is what keeps the
    /// reply attached to the question that produced it.
    @State private var lastRequest = ""
    @State private var snapshot: [EventItem] = []
    @State private var applied: [String] = []
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            TextEditor(text: $prompt)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                // The overlay sits on the editor's own bounds, before the
                // padding below, so the only offset left to match is the text
                // container's 5pt line-fragment padding. Putting it outside the
                // padding is what knocked the placeholder off the caret.
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("Move my 5pm to Thursday, or add office hours every Tuesday at 3…")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.faint)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(10)
                .frame(height: 88)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .focused($promptFocused)
                .padding(.horizontal, 20)

            if !runner.transcript.isEmpty || runner.isRunning
                || runner.failure != nil || !applied.isEmpty {
                transcriptArea
            }

            Divider().padding(.top, 14)
            footer
        }
        .frame(width: 520)
        .background(Theme.panel)
        .onAppear { promptFocused = true }
        // When the run ends, lift the plan out of the reply and apply it.
        .onChange(of: runner.isRunning) { wasRunning, isRunning in
            guard wasRunning, !isRunning else { return }
            applyPlan()
        }
        .onDisappear { store.reload() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.graphite)
            Text("Ask Claude")
                .font(Theme.paneTitle)
                .foregroundStyle(Theme.ink)
            Spacer()
            Text(dayLabel)
                .font(.system(size: 11))
                .foregroundStyle(Theme.graphite)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var transcriptArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !lastRequest.isEmpty {
                Text(lastRequest)
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.graphite)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.wash)
                    )
            }
            // What actually changed, listed separately from what Claude said
            // about it — the app is the one that made these edits.
            if !applied.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(applied, id: \.self) { line in
                        Label(line, systemImage: "checkmark.circle")
                            .font(Theme.ui(11))
                            .foregroundStyle(Theme.ink)
                    }
                }
                .padding(.bottom, 2)
            }
            if let failure = runner.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            ScrollView {
                Text(runner.transcript.isEmpty ? "Working…" : runner.transcript)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.graphite)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if runner.isRunning {
                ProgressView().controlSize(.small)
                Text("Claude is working…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.graphite)
            } else {
                HStack(spacing: 5) {
                    Text("⌘↩")
                        .font(Theme.time(10, weight: .semibold))
                        .foregroundStyle(Theme.graphite)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Theme.wash)
                        )
                    Text("to send. Claude can change this calendar and nothing else.")
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.faint)
                }
            }
            Spacer()
            if runner.isRunning {
                Button("Stop") { runner.cancel() }
            } else {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Button("Send") { send() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .help("Send to Claude (⌘↩)")
                .disabled(runner.isRunning || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(16)
    }

    private func send() {
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        applied = []
        lastRequest = request
        prompt = ""                 // ready for the next one
        promptFocused = true
        snapshot = buildSnapshot()
        runner.run(prompt: request, day: store.selectedDay,
                   calendarName: targetCalendarTitle,
                   snapshot: snapshotText(snapshot))
    }

    private func applyPlan() {
        let (plan, prose) = PlanParser.extract(from: runner.transcript)
        runner.showProse(prose)
        guard let plan else { return }
        applied = PlanApplier.apply(plan, snapshot: snapshot, store: store, colors: colors)
    }

    /// What Claude gets to see: a year around the day in view — five months back,
    /// seven ahead.
    ///
    /// Repeating events collapse to their first occurrence in the window. Left
    /// expanded, a term of Math 1920 alone is forty-five lines and the whole
    /// prompt runs to thousands; collapsed, the snapshot stays legible. Nothing
    /// is lost by it, because editing a repeating event applies to the series
    /// anyway.
    private func buildSnapshot() -> [EventItem] {
        let calendar = store.calendar
        let from = calendar.date(byAdding: .month, value: -5, to: store.selectedDay) ?? store.selectedDay
        let to = calendar.date(byAdding: .month, value: 7, to: store.selectedDay) ?? store.selectedDay

        var seenSeries = Set<String>()
        var result: [EventItem] = []
        for item in store.allKnownItems().sorted(by: { $0.start < $1.start })
        where item.start >= from && item.start < to {
            if item.isRecurring {
                guard !seenSeries.contains(item.seriesID) else { continue }
                seenSeries.insert(item.seriesID)
            }
            result.append(item)
        }
        return Array(result.prefix(400))
    }

    private func snapshotText(_ items: [EventItem]) -> String {
        guard !items.isEmpty else { return "  (nothing scheduled in this window)" }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm"

        return items.enumerated().map { index, item in
            let when = item.isAllDay
                ? "\(day.string(from: item.start)) all-day"
                : "\(day.string(from: item.start)) \(clock.string(from: item.start))-\(clock.string(from: item.end))"
            let place = item.location.isEmpty ? "" : " · \(item.location)"
            let repeats = item.isRecurring ? " · repeats" : ""
            let tag = Categories.category(for: item).map { " [\($0.slug)]" } ?? ""
            return "        #\(index + 1)  \(when)  \(item.title)\(place)\(repeats)\(tag)"
        }.joined(separator: "\n")
    }

    private var dayLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: store.selectedDay)
    }
}
