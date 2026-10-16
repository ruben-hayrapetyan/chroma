import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The first question on first launch: read the calendars macOS syncs, or go
/// straight to Google. Set like the calendar picker that follows it.
struct SourceChooser: View {
    @EnvironmentObject var store: EventStore
    @State private var selection: CalendarSource = .apple
    @FocusState private var listFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Where are your calendars?")
                .font(Theme.display)
                .foregroundStyle(Theme.ink)
            Text("Chroma can show the calendars this Mac already syncs, or sign in to Google and work with Google Calendar directly. You can switch later in Settings.")
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.graphite)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            VStack(spacing: 2) {
                ForEach(CalendarSource.allCases) { source in
                    SourceRow(source: source, isSelected: source == selection)
                        .onTapGesture { select(source) }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { store.use(source) })
                }
            }
            .padding(8)
            .card()
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { select(.apple); return .handled }
            .onKeyPress(.downArrow) { select(.google); return .handled }
            .onAppear { listFocused = true }
            .padding(.top, 20)

            HStack {
                Spacer()
                Button("Continue with \(selection.title)") { store.use(selection) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .frame(width: 452)
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
    }

    private func select(_ source: CalendarSource) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { selection = source }
        listFocused = true
    }
}

private struct SourceRow: View {
    let source: CalendarSource
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: source == .apple ? "calendar" : "globe")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Theme.ink.opacity(0.8))
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.title)
                    .font(Theme.ui(13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.graphite)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Theme.wash : hovering ? Theme.outsideMonth : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.ink.opacity(isSelected ? 0.55 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var detail: String {
        switch source {
        case .apple:
            return "Every account in System Settings › Internet Accounts — iCloud, Google, Exchange, CalDAV. macOS asks once for permission."
        case .google:
            return "One Google account, signed in through your browser. Nothing is added to macOS, and changes go straight to Google."
        }
    }
}

/// Stands in for the calendar while Google mode has no way in: no client to
/// sign in with, no account signed in, or Google out of reach.
struct GoogleSignIn: View {
    @EnvironmentObject var store: EventStore
    @State private var clientProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(heading)
                .font(Theme.display)
                .foregroundStyle(Theme.ink)
            Text(detail)
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.graphite)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            if let problem = clientProblem ?? store.signInProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            HStack(spacing: 12) {
                links
                Spacer(minLength: 12)
                primary
            }
            .padding(.top, 20)

            if !store.signingIn, store.hasGoogleClient, store.access == .signedOut {
                Text("Chroma talks to Google directly from this Mac. The sign-in is kept in your keychain, and Settings › Calendars signs out.")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
            }
        }
        .frame(width: 452)
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
    }

    private var unreachable: String? {
        if case .unreachable(let reason) = store.access { return reason }
        return nil
    }

    private var heading: String {
        if !store.hasGoogleClient { return "Set up Google sign-in" }
        if store.signingIn { return "Waiting for your browser" }
        if unreachable != nil { return "Can't reach Google" }
        return "Sign in to Google"
    }

    private var detail: String {
        if !store.hasGoogleClient {
            return "Google only lets an app reach your calendar through a client registered in Google Cloud. Make a Desktop client in Google Cloud Console, download its JSON, and choose it here — the README walks through it."
        }
        if store.signingIn {
            return "Finish signing in in the browser tab that just opened. Chroma carries on by itself once you allow access."
        }
        if let unreachable { return unreachable }
        return "Chroma opens Google in your browser. Allow both things it asks for — seeing your calendar list, and seeing and editing your events — and you'll come straight back here."
    }

    @ViewBuilder
    private var primary: some View {
        Group {
            if !store.hasGoogleClient {
                Button("Choose Client File…", action: chooseClientFile)
            } else if store.signingIn {
                Button("Cancel") { store.cancelGoogleSignIn() }
            } else if unreachable != nil {
                Button("Try Again") { store.retryAccess() }
            } else {
                Button("Sign In with Google") { store.signInToGoogle() }
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    @ViewBuilder
    private var links: some View {
        if !store.hasGoogleClient {
            link("Open Google Cloud Console") {
                if let url = URL(string: "https://console.cloud.google.com/apis/credentials") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        if !store.signingIn {
            link("Use Apple Calendar instead") { store.use(.apple) }
        }
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.graphite)
                .underline(color: Theme.rule)
        }
        .buttonStyle(.plain)
    }

    private func chooseClientFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose the client JSON you downloaded from Google Cloud Console"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.installGoogleClient(from: url)
            clientProblem = nil
        } catch {
            clientProblem = error.localizedDescription
        }
    }
}
