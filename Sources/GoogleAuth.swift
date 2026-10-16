import AppKit
import CryptoKit
import Foundation
import Network
import Security

/// The OAuth client Chroma signs in to Google as.
///
/// Google only lets an app reach someone's calendar through a client
/// registered in Google Cloud. A copy built with one has it in its Info.plist
/// (see build.sh); otherwise it's the JSON file Google Cloud Console downloads
/// for a Desktop client, kept in Chroma's Application Support folder.
struct GoogleClient: Equatable {
    let id: String
    /// Google issues one even for desktop apps, where it can't be kept secret;
    /// it's sent because Google's token endpoint asks for it.
    let secret: String?

    static func load() -> GoogleClient? {
        let info = Bundle.main.infoDictionary ?? [:]
        if let id = info["ChromaGoogleClientID"] as? String, !id.isEmpty {
            let secret = info["ChromaGoogleClientSecret"] as? String
            return GoogleClient(id: id, secret: secret?.isEmpty == false ? secret : nil)
        }
        return (try? Data(contentsOf: fileURL)).flatMap(parse)
    }

    static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Chroma/google-client.json")
    }

    /// The Console's download — `{"installed": {"client_id": …, "client_secret": …}}` —
    /// or the inner object on its own.
    static func parse(_ data: Data) -> GoogleClient? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let fields = (object["installed"] as? [String: Any]) ?? object
        guard let id = fields["client_id"] as? String, !id.isEmpty else { return nil }
        return GoogleClient(id: id, secret: fields["client_secret"] as? String)
    }

    /// Checks a downloaded file and keeps a copy where `load` looks.
    static func install(from url: URL) throws {
        guard let data = try? Data(contentsOf: url), parse(data) != nil else {
            throw GoogleError.badClientFile
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

enum GoogleError: LocalizedError {
    case noClient
    case badClientFile
    case signedOut
    case missingPermission
    case refused(String)
    case timedOut
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .noClient:
            return "Chroma has no Google client to sign in with yet."
        case .badClientFile:
            return "That isn't a Google OAuth client file. Download the JSON for a Desktop client from Google Cloud Console."
        case .signedOut:
            return "Google signed Chroma out. Sign in again to carry on."
        case .missingPermission:
            return "Chroma needs both permissions Google asked about — seeing your calendar list, and seeing and editing events. Sign in again and leave both ticked."
        case .refused(let reason):
            return reason == "access_denied" ? "Google sign-in was cancelled." : "Google refused the sign-in (\(reason))."
        case .timedOut:
            return "The sign-in in your browser wasn't finished, so Chroma stopped waiting."
        case .server(let status, let message):
            return message.isEmpty ? "Google answered with an error (\(status))." : message
        }
    }
}

/// Signs in to one Google account and keeps a working access token.
///
/// The browser does the signing in — Chroma never sees a password. Google
/// sends the browser back to a one-off listener on 127.0.0.1 with a code,
/// which Chroma trades for tokens; PKCE ties that code to this sign-in, so a
/// code picked up anywhere else is worthless. The long-lived refresh token is
/// kept in the login keychain, never in a file.
@MainActor
final class GoogleAuth {
    static let scopes = [
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.events",
    ]

    private struct Saved: Codable {
        var client: String
        var refreshToken: String
    }

    private var saved: Saved?
    private var accessToken: String?
    private var expiry = Date.distantPast
    private var refreshing: Task<String, Error>?
    private var receiver: LoopbackReceiver?

    init() {
        saved = Keychain.read().flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        // A token issued to another client is no use to this one.
        if let saved, saved.client != GoogleClient.load()?.id { self.saved = nil }
    }

    var isSignedIn: Bool { saved != nil }

    // MARK: - Signing in

    func signIn() async throws {
        guard let client = GoogleClient.load() else { throw GoogleError.noClient }
        let verifier = Self.randomString()
        let state = Self.randomString()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        let receiver = try await LoopbackReceiver.start()
        self.receiver = receiver
        defer { receiver.stop(); self.receiver = nil }
        let redirect = "http://127.0.0.1:\(receiver.port)"

        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            // Asked every time, so Google always hands over a refresh token.
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        NSWorkspace.shared.open(url.url!)

        let code = try await receiver.code(matching: state)
        NSApp.activate(ignoringOtherApps: true)

        let reply = try await Self.tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirect,
        ], client: client)
        // Google's consent screen lets each permission be unticked.
        let granted = Set((reply.scope ?? "").split(separator: " ").map(String.init))
        guard Self.scopes.allSatisfy(granted.contains) else { throw GoogleError.missingPermission }
        guard let refresh = reply.refresh_token else { throw GoogleError.server(0, "Google didn't return a refresh token.") }

        let record = Saved(client: client.id, refreshToken: refresh)
        Keychain.write(try JSONEncoder().encode(record))
        saved = record
        accessToken = reply.access_token
        expiry = Date().addingTimeInterval(TimeInterval(reply.expires_in ?? 3600))
    }

    /// Stops waiting for the browser.
    func cancelSignIn() {
        receiver?.stop()
    }

    /// Forgets the account here and tells Google to revoke the token.
    func signOut() async {
        let token = saved?.refreshToken
        Keychain.delete()
        saved = nil
        accessToken = nil
        expiry = .distantPast
        if let token {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form(["token": token])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    // MARK: - Access tokens

    /// A token good for at least another minute, refreshed when it isn't.
    /// Calls that arrive while a refresh is under way wait for that one.
    func token(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let accessToken, expiry > Date().addingTimeInterval(60) { return accessToken }
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.refresh() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func refresh() async throws -> String {
        guard let saved, let client = GoogleClient.load() else { throw GoogleError.signedOut }
        do {
            let reply = try await Self.tokenRequest([
                "grant_type": "refresh_token",
                "refresh_token": saved.refreshToken,
            ], client: client)
            accessToken = reply.access_token
            expiry = Date().addingTimeInterval(TimeInterval(reply.expires_in ?? 3600))
            return reply.access_token
        } catch GoogleError.server(let status, _) where status == 400 || status == 401 {
            // invalid_grant: revoked, expired, or the password changed.
            Keychain.delete()
            self.saved = nil
            throw GoogleError.signedOut
        }
    }

    // MARK: - Plumbing

    private struct TokenReply: Decodable {
        let access_token: String
        let expires_in: Int?
        let refresh_token: String?
        let scope: String?
    }

    private static func tokenRequest(_ fields: [String: String], client: GoogleClient) async throws -> TokenReply {
        var body = fields
        body["client_id"] = client.id
        if let secret = client.secret { body["client_secret"] = secret }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw GoogleError.server(status, errorMessage(data)) }
        return try JSONDecoder().decode(TokenReply.self, from: data)
    }

    /// Google's own words when it gives them: `error_description`, or the
    /// `error.message` the Calendar API uses.
    nonisolated static func errorMessage(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let description = object["error_description"] as? String { return description }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return object["error"] as? String ?? ""
    }

    private static func form(_ fields: [String: String]) -> Data {
        Data(fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlUnreserved) ?? value)"
        }.joined(separator: "&").utf8)
    }

    private static func randomString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The refresh token's place in the login keychain.
private enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.chroma.app.google",
        kSecAttrAccount as String: "refresh-token",
    ]

    static func read() -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func write(_ data: Data) {
        delete()
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Chroma — Google Calendar"
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// A listener on 127.0.0.1 that waits for Google to send the browser back
/// with a code, answers with a page saying to return to Chroma, and stops.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.chroma.app.loopback")
    private var waiting: CheckedContinuation<(code: String?, state: String?, error: String?), Error>?
    private var stopped = false
    private var listening = false
    private(set) var port: UInt16 = 0

    private init(listener: NWListener) {
        self.listener = listener
    }

    static func start() async throws -> LoopbackReceiver {
        let parameters = NWParameters.tcp
        // Loopback only: nothing off this Mac can reach it.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let receiver = LoopbackReceiver(listener: try NWListener(using: parameters))
        try await receiver.begin()
        return receiver
    }

    private func begin() async throws {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        port = try await withCheckedThrowingContinuation { continuation in
            // Every state change arrives on `queue`, one at a time.
            listener.stateUpdateHandler = { [self] state in
                guard !listening else { return }
                switch state {
                case .ready:
                    listening = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listening = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Waits up to five minutes for the redirect that carries `state`.
    func code(matching state: String) async throws -> String {
        let timeout = Task { [weak self] in
            try await Task.sleep(for: .seconds(300))
            self?.finish(.failure(GoogleError.timedOut))
        }
        defer { timeout.cancel() }
        let reply: (code: String?, state: String?, error: String?) = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if self.stopped {
                    continuation.resume(throwing: GoogleError.refused("access_denied"))
                } else {
                    self.waiting = continuation
                }
            }
        }
        if let error = reply.error { throw GoogleError.refused(error) }
        guard reply.state == state, let code = reply.code else {
            throw GoogleError.refused("the reply didn't match this sign-in")
        }
        return code
    }

    func stop() {
        finish(.failure(GoogleError.refused("access_denied")))
    }

    private func finish(_ result: Result<(code: String?, state: String?, error: String?), Error>) {
        queue.async {
            self.stopped = true
            self.listener.cancel()
            self.waiting?.resume(with: result)
            self.waiting = nil
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            // "GET /?code=…&state=… HTTP/1.1"
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let items = URLComponents(string: "http://127.0.0.1\(target)")?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            let code = value("code"), error = value("error")

            // The browser also asks for a favicon; only the redirect counts.
            guard code != nil || error != nil else {
                self.respond(connection, status: "404 Not Found", page: "")
                return
            }
            self.respond(connection, status: "200 OK", page: Self.page(signedIn: code != nil))
            self.finish(.success((code, value("state"), error)))
        }
    }

    private func respond(_ connection: NWConnection, status: String, page: String) {
        let body = Data(page.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func page(signedIn: Bool) -> String {
        let message = signedIn
            ? "Signed in. You can close this tab and go back to Chroma."
            : "Sign-in cancelled. You can close this tab."
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Chroma</title>
        <style>body{font:16px -apple-system,system-ui,sans-serif;background:#f6f5f2;color:#1d1d1f;
        display:grid;place-items:center;height:100vh;margin:0}p{max-width:22em;text-align:center}</style>
        </head><body><p>\(message)</p></body></html>
        """
    }
}
