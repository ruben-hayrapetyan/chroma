import SwiftUI

/// The create form, in the right-hand pane rather than a sheet.
///
/// Pairs with the dashed block in the grid: both read from the same draft, so
/// dragging the time here moves the highlight there, and the calendar stays
/// visible the whole time.
struct NewEventPane: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var colors: EventColors

    /// Bound to the optional itself, not to an unwrapped copy.
    ///
    /// An earlier version took a non-optional binding whose getter invented a
    /// fresh draft whenever this was nil. Closing the pane set nil, the getter
    /// handed back an invention, `onChange` wrote it back, and the draft rose
    /// from the dead — which also kept the detail pane from ever showing.
    @Binding var draft: DraftEvent?
    let onClose: () -> Void

    @State private var error: String?
    @FocusState private var titleFocused: Bool

    /// A binding into one field of the draft that refuses to write once the
    /// draft is gone. This guard is the fix for the resurrection bug.
    private func field<T>(_ keyPath: WritableKeyPath<DraftEvent, T>, or fallback: T) -> Binding<T> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? fallback },
            set: { value in
                guard draft != nil else { return }
                draft?[keyPath: keyPath] = value
            }
        )
    }

    private var current: DraftEvent { draft ?? .hour(at: Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Title", text: field(\.title, or: ""))
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .focused($titleFocused)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Theme.wash)
                        )

                    Toggle("All-day", isOn: field(\.isAllDay, or: false))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.system(size: 12))

                    VStack(alignment: .leading, spacing: 8) {
                        label("When", systemImage: "clock")
                        DatePicker("Starts", selection: field(\.start, or: Date()),
                                   displayedComponents: current.isAllDay ? [.date] : [.date, .hourAndMinute])
                        DatePicker("Ends", selection: field(\.end, or: Date()),
                                   displayedComponents: current.isAllDay ? [.date] : [.date, .hourAndMinute])
                    }
                    .font(.system(size: 12))

                    VStack(alignment: .leading, spacing: 6) {
                        label("Location", systemImage: "mappin.and.ellipse")
                        TextField("Optional", text: field(\.location, or: ""))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }

                    RecurrenceEditor(draft: field(\.recurrence, or: RecurrenceDraft()))

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
        .onAppear { titleFocused = true }
        // Dragging the start should carry the end along rather than letting the
        // block invert.
        .onChange(of: draft?.start) { old, new in
            guard let old, let new, var value = draft, value.end <= new else { return }
            value.end = new.addingTimeInterval(max(value.end.timeIntervalSince(old), 3600))
            draft = value
        }
    }

    private var heading: some View {
        HStack {
            Text("New Event")
                .font(Theme.paneTitle)
                .foregroundStyle(Theme.ink)
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
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private func label(_ text: String, systemImage: String) -> some View {
        Label(text.uppercased(), systemImage: systemImage)
            .font(Theme.eyebrow)
            .foregroundStyle(Theme.graphite)
    }

    private var swatches: some View {
        VStack(alignment: .leading, spacing: 7) {
            label("Colour", systemImage: "paintpalette")
            HStack(spacing: 7) {
                swatch(nil, color: EventColors.fallback.color)
                ForEach(EventColor.palette) { option in
                    swatch(option, color: option.color)
                }
            }
        }
    }

    private func swatch(_ option: EventColor?, color: Color) -> some View {
        let isOn = current.colorID == option?.id
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color)
            .frame(width: 21, height: 21)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Theme.ink.opacity(isOn ? 0.75 : 0), lineWidth: 1.5)
                    .padding(-3)
            )
            .contentShape(Rectangle())
            .onTapGesture { field(\.colorID, or: nil).wrappedValue = option?.id }
            .help(option?.name ?? EventColors.fallback.name)
    }

    private var actions: some View {
        HStack {
            Button("Cancel", action: onClose)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Create") { create() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(current.title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(14)
    }

    private func create() {
        guard let value = draft else { return }
        let title = value.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        do {
            let seriesID = try store.create(title: title,
                                            start: value.start,
                                            end: value.end,
                                            isAllDay: value.isAllDay,
                                            location: value.location,
                                            notes: value.notes,
                                            recurrence: value.recurrence.rule)
            if let seriesID, let colorID = value.colorID {
                colors.set(EventColor.named(colorID), for: seriesID)
            }
            onClose()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
