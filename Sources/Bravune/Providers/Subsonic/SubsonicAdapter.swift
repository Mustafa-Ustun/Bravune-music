import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class SubsonicAdapter: ProviderAdapter {
    private static let serverKey = "bravune.subsonic.server"
    private static let userKey = "bravune.subsonic.user"
    private static let passwordAccount = "subsonic.password"

    let id = ProviderID.subsonic
    let displayName = "Subsonic / Navidrome"

    private(set) var credentials: SubsonicCredentials?

    var isConnected: Bool {
        credentials != nil
    }

    var connectionDetail: String? {
        credentials.map { "\($0.username)@\($0.serverURL.host() ?? $0.serverURL.absoluteString)" }
    }

    init(credentials: SubsonicCredentials?) {
        self.credentials = credentials
    }

    convenience init() {
        self.init(credentials: Self.storedCredentials())
    }

    private static func storedCredentials() -> SubsonicCredentials? {
        let defaults = UserDefaults.standard
        guard let server = defaults.string(forKey: serverKey),
              let url = URL(string: server),
              let user = defaults.string(forKey: userKey),
              let password = Keychain.get(account: passwordAccount) else { return nil }
        return SubsonicCredentials(serverURL: url, username: user, password: password)
    }

    func connect() async throws {
        guard let entered = try promptCredentials() else { return }
        try await SubsonicClient(credentials: entered).ping()
        credentials = entered
        let defaults = UserDefaults.standard
        defaults.set(entered.serverURL.absoluteString, forKey: Self.serverKey)
        defaults.set(entered.username, forKey: Self.userKey)
        Keychain.set(entered.password, account: Self.passwordAccount)
    }

    func disconnect() {
        credentials = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.serverKey)
        defaults.removeObject(forKey: Self.userKey)
        Keychain.delete(account: Self.passwordAccount)
    }

    func tracks() async throws -> [UnifiedTrack] {
        guard let credentials else { return [] }
        let client = SubsonicClient(credentials: credentials)
        let songs = try await client.allSongs()
        return songs.map { song in
            UnifiedTrack(
                provider: id,
                providerTrackId: song.id,
                title: song.title,
                artist: song.artist ?? "Unknown Artist",
                album: song.album ?? "Unknown Album",
                duration: TimeInterval(song.duration ?? 0),
                artwork: song.coverArt.flatMap { client.coverArtURL(id: $0) }
            )
        }
        .sortedForLibrary()
    }

    func makePlayback() -> any TrackPlayback {
        SubsonicPlayback { [weak self] trackId in
            guard let credentials = self?.credentials else { throw SubsonicError.notConnected }
            return try SubsonicClient(credentials: credentials).streamURL(id: trackId)
        }
    }

    private func promptCredentials() throws -> SubsonicCredentials? {
        let server = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        server.placeholderString = "https://music.example.com"
        server.stringValue = credentials?.serverURL.absoluteString ?? ""
        let user = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        user.placeholderString = "Username"
        user.stringValue = credentials?.username ?? ""
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        password.placeholderString = credentials == nil ? "Password" : "Password (leave empty to keep current)"

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
        alert.messageText = "Connect Subsonic / Navidrome"
        alert.informativeText = "Enter your server details"
        alert.accessoryView = stack
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = server
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        var address = server.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.contains("://") {
            address = "https://" + address
        }
        guard let url = URL(string: address), url.host() != nil else { throw SubsonicError.invalidURL }
        let secret = password.stringValue.isEmpty ? (credentials?.password ?? "") : password.stringValue
        return SubsonicCredentials(
            serverURL: url,
            username: user.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            password: secret
        )
    }
}
