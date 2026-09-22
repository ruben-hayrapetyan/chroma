import SwiftUI

/// The inspector that slides in on the right when an event is clicked, and the
/// editor when it is double-clicked.
///
/// Read and edit are one pane rather than a pane plus a modal sheet: a sheet
/// covers the calendar, which is the thing you want in view while changing an
/// event's time.
struct DetailPane: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var colors: EventColors

    let item: EventItem
    @Binding var isEditing: Bool
    let onClose: () -> Void

    @State private var title = ""
    @State private var start = Date()
    @State private var end = Date()
    @State private var isAllDay = false
    @State private var location = ""
    @State private var notes = ""
    @State private var recurrence = RecurrenceDraft()
    @State private var error: String?
    @State private var confirmingDelete = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isEditing { editFields } else { readFields }
                    swatches
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                }
                .padding(18)
            }

            Divider().foregroundStyle(Theme.rule)
            actions
        }
        .frame(width: 320)
        .background(Theme.panel)
        .onAppear(perform: seed)
        // Reseed when a different event is selected, and when an edit arriving
        // from Calendar.app changes this one underneath us.
        .onChange(of: item.id) { _, _ in if !isEditing { seed() } }
        .onChange(of: isEditing) { _, editing in
            if editing { seed(); titleFocused = true } else { error = nil }
        }
        .onChange(of: start) { old, new in
            guard isEditing, end <= new else { return }
            end = new.addingTimeInterval(max(end.timeIntervalSince(old), 3600))
        }
        .confirmationDialog("Delete \"\(item.title)\"?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { performDelete() }
        } message: {
            Text(item.isRecurring
                 ? "This and all later occurrences will be removed from your \"\(targetCalendarTitle)\" calendar and from iCloud."
                 : "It will be removed from your \"\(targetCalendarTitle)\" calendar and from iCloud.")
        }
    }

    // MARK: - Heading

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if isEditing {
                    Text("EDITING")
                        .font(Theme.eyebrow)
                        .foregroundStyle(Theme.graphite)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.graphite)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.wash))
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .top, spacing: 9) {
                Rectangle()
                    .fill(colors.color(for: item.seriesID))
                    .frame(width: Theme.spine, height: isEditing ? 30 : 36)

                if isEditing {
                    TextField("Title", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .semibold))
                        .focused($titleFocused)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Theme.wash)
                        )
                } else {
                    Text(item.title)
                        .font(Theme.paneTitle)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    // MARK: - Read

    private var readFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                label("When", systemImage: "clock")
                Text(dayLine).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.ink)
                Text(timeLine).font(Theme.time(11)).foregroundStyle(Theme.graphite)
            }
            if !item.location.isEmpty {
                field("Location", systemImage: "mappin.and.ellipse", value: item.location)
            }
            if item.isRecurring {
                field("Repeats", systemImage: "repeat", value: "Part of a repeating series")
            }
            if !item.notes.isEmpty {
                field("Notes", systemImage: "text.alignleft", value: item.notes)
            }
        }
    }

    // MARK: - Edit

    private var editFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("All-day", isOn: $isAllDay)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 8) {
                label("When", systemImage: "clock")
                DatePicker("Starts", selection: $start,
                           displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                DatePicker("Ends", selection: $end,
                           displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
            }
            .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 6) {
                label("Location", systemImage: "mappin.and.ellipse")
                TextField("Optional", text: $location)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            VStack(alignment: .leading, spacing: 6) {
                label("Notes", systemImage: "text.alignleft")
                TextField("Optional", text: $notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .lineLimit(2...5)
            }

            RecurrenceEditor(draft: $recurrence)

            if item.isRecurring {
                Label("Changes apply to this and all later occurrences.",
                      systemImage: "repeat")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
            }
        }
    }

    // MARK: - Shared pieces

    private func field(_ title: String, systemImage: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            label(title, systemImage: systemImage)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func label(_ text: String, systemImage: String) -> some View {
        Label(text.uppercased(), systemImage: systemImage)
            .font(Theme.eyebrow)
            .foregroundStyle(Theme.graphite)
    }

    /// Colour applies immediately in both modes — it is not part of the event as
    /// EventKit sees it, so there is nothing to save.
    private var swatches: some View {
        VStack(alignment: .leading, spacing: 7) {
            label("Colour", systemImage: "paintpalette")
            HStack(spacing: 7) {
                swatch(nil, color: EventColors.fallback.color)
                ForEach(EventColor.palette) { option in
                    swatch(option, color: option.color)
                }
            }
            if item.isRecurring {
                Text("Applies to every occurrence in the series.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
            }
        }
    }

    private func swatch(_ option: EventColor?, color: Color) -> some View {
        let isOn = colors.assigned(for: item.seriesID)?.id == option?.id
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color)
            .frame(width: 21, height: 21)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Theme.ink.opacity(isOn ? 0.75 : 0), lineWidth: 1.5)
                    .padding(-3)
            )
            .contentShape(Rectangle())
            .onTapGesture { colors.set(option, for: item.seriesID) }
            .help(option?.name ?? EventColors.fallback.name)
    }

    private var actions: some View {
        HStack {
            if isEditing {
                Button("Cancel") { isEditing = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                Button("Delete", role: .destructive) { confirmingDelete = true }
                Spacer()
                Button("Edit") { isEditing = true }
                    .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
        .padding(14)
    }

    // MARK: - Actions

    private func seed() {
        title = item.title
        start = item.start
        end = item.end
        isAllDay = item.isAllDay
        location = item.location
        notes = item.notes
        recurrence = RecurrenceDraft.from(item.ekEvent.recurrenceRules?.first)
    }

    private func save() {
        let cleaned = title.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return }
        do {
            try store.update(item, title: cleaned, start: start, end: end,
                             isAllDay: isAllDay, location: location, notes: notes,
                             recurrence: recurrence.edit)
            isEditing = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func performDelete() {
        do {
            try store.delete(item)
            colors.set(nil, for: item.seriesID)
            onClose()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var dayLine: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.string(from: item.start)
    }

    private var timeLine: String {
        if item.isAllDay { return "All day" }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let minutes = Int(item.durationMinutes)
        let length = minutes >= 60
            ? "\(minutes / 60)h\(minutes % 60 == 0 ? "" : " \(minutes % 60)m")"
            : "\(minutes)m"
        return "\(formatter.string(from: item.start)) – \(formatter.string(from: item.end))  ·  \(length)"
    }
}
