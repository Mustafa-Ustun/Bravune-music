import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class JellyfinAdapter: ProviderAdapter {
    private static let serverKey = "bravune.jellyfin.server"
    private static let userIdKey = "bravune.jellyfin.userId"
    private static let userKey = "bravune.jellyfin.user"
    private static let deviceKey = "bravune.jellyfin.deviceId"
    private static let tokenAccount = "jellyfin.token"

    let id = ProviderID.jellyfin
    let displayName = "Jellyfin"

    private(set) var session: JellyfinSession?
    private let deviceId: String

    var isConnected: Bool {
        session != nil
    }

    var connectionDetail: String? {
        session.map { "\($0.username)@\($0.serverURL.host() ?? $0.serverURL.absoluteString)" }
    }

    init(session: JellyfinSession?, deviceId: String = JellyfinAdapter.storedDeviceId()) {
        self.session = session
        self.deviceId = deviceId
    }

    convenience init() {
        self.init(session: Self.storedSession())
    }

    static func storedDeviceId() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceKey) { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: deviceKey)
        return fresh
    }

    private static func storedSession() -> JellyfinSession? {
        let defaults = UserDefaults.standard
        guard let server = defaults.string(forKey: serverKey),
              let url = URL(string: server),
              let userId = defaults.string(forKey: userIdKey),
              let user = defaults.string(forKey: userKey),
              let token = Keychain.get(account: tokenAccount) else { return nil }
        return JellyfinSession(serverURL: url, userId: userId, username: user, accessToken: token)
    }

    func connect() async throws {
        guard let entered = try promptLogin() else { return }
        let fresh = try await JellyfinClient.authenticate(
            serverURL: entered.url,
            username: entered.username,
            password: entered.password,
            deviceId: deviceId
        )
        session = fresh
        let defaults = UserDefaults.standard
        defaults.set(fresh.serverURL.absoluteString, forKey: Self.serverKey)
        defaults.set(fresh.userId, forKey: Self.userIdKey)
        defaults.set(fresh.username, forKey: Self.userKey)
        Keychain.set(fresh.accessToken, account: Self.tokenAccount)
    }

    func disconnect() {
        session = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.serverKey)
        defaults.removeObject(forKey: Self.userIdKey)
        defaults.removeObject(forKey: Self.userKey)
        Keychain.delete(account: Self.tokenAccount)
    }

    func tracks() async throws -> [UnifiedTrack] {
        guard let session else { return [] }
        let client = JellyfinClient(session: session, deviceId: deviceId)
        let songs = try await client.allSongs()
        return songs.map { song in
            UnifiedTrack(
                provider: id,
                providerTrackId: song.id,
                title: song.name,
                artist: song.displayArtist,
                album: song.album ?? "Unknown Album",
                duration: song.duration,
                artwork: client.imageURL(for: song)
            )
        }
        .sortedForLibrary()
    }

    func makePlayback() -> any TrackPlayback {
        HTTPStreamPlayback { [weak self] trackId in
            guard let self, let session = self.session else { throw JellyfinError.notConnected }
            return try JellyfinClient(session: session, deviceId: self.deviceId).streamURL(id: trackId)
        }
    }

    private func promptLogin() throws -> (url: URL, username: String, password: String)? {
        let server = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        server.placeholderString = "https://jellyfin.example.com"
        server.stringValue = session?.serverURL.absoluteString ?? ""
        let user = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        user.placeholderString = "Username"
        user.stringValue = session?.username ?? ""
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        password.placeholderString = "Password"

        let stack = NSStackView(views: [server, user, password])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.distribution = .fillEqually
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 88)
        for field in [server, user, password] {
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }

        let alert = NSAlert()
        alert.messageText = "Connect Jellyfin"
        alert.informativeText = "Enter your server details. The password is only sent to your server and is not stored."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = server
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        var address = server.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.contains("://") {
            address = "https://" + address
        }
        guard let url = URL(string: address), url.host() != nil else { throw JellyfinError.invalidURL }
        return (url, user.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), password.stringValue)
    }
}
