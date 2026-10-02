import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class SpotifyAdapter: ProviderAdapter {
    private static let clientKey = "bravune.spotify.clientID"
    private static let nameKey = "bravune.spotify.displayName"

    let id = ProviderID.spotify
    let displayName = "Spotify"

    private var api: SpotifyAPI?
    private var accountName: String?

    var isConnected: Bool {
        api != nil
    }

    var connectionDetail: String? {
        guard isConnected else { return nil }
        return accountName.map { "Signed in as \($0)" } ?? "Connected"
    }

    init(api: SpotifyAPI?, accountName: String? = nil) {
        self.api = api
        self.accountName = accountName
    }

    convenience init() {
        let defaults = UserDefaults.standard
        if let clientID = defaults.string(forKey: Self.clientKey),
           let refresh = Keychain.get(account: SpotifySession.refreshAccount) {
            self.init(
                api: SpotifyAPI(session: SpotifySession(clientID: clientID, refreshToken: refresh)),
                accountName: defaults.string(forKey: Self.nameKey)
            )
        } else {
            self.init(api: nil)
        }
    }

    func connect() async throws {
        let defaults = UserDefaults.standard
        guard let clientID = promptClientID(current: defaults.string(forKey: Self.clientKey)) else { return }
        let session = SpotifySession(clientID: clientID)
        try await session.authorize()
        let newAPI = SpotifyAPI(session: session)
        let name = try await newAPI.displayName()
        defaults.set(clientID, forKey: Self.clientKey)
        defaults.set(name, forKey: Self.nameKey)
        accountName = name
        api = newAPI
    }

    func disconnect() {
        api = nil
        accountName = nil
        Keychain.delete(account: SpotifySession.refreshAccount)
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
    }

    func tracks() async throws -> [UnifiedTrack] {
        guard let api else { return [] }
        return try await api.savedTracks().compactMap { track in
            guard let trackID = track.id, track.is_local != true else { return nil }
            return UnifiedTrack(
                provider: id,
                providerTrackId: trackID,
                title: track.name,
                artist: track.artists.map(\.name).joined(separator: ", "),
                album: track.album.name,
                duration: TimeInterval(track.duration_ms) / 1000,
                artwork: Self.artwork(from: track.album.images)
            )
        }
        .sortedForLibrary()
    }

    func makePlayback() -> any TrackPlayback {
        SpotifyPlayback { [weak self] in
            guard let api = self?.api else { throw SpotifyError.notConnected }
            return api
        }
    }

    static func artwork(from images: [SpotifyTrack.Image]) -> URL? {
        let sorted = images.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        let chosen = sorted.first { ($0.width ?? 0) >= 300 } ?? sorted.last
        return chosen.flatMap { URL(string: $0.url) }
    }

    private func promptClientID(current: String?) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Spotify Client ID"
        field.stringValue = current ?? ""

        let alert = NSAlert()
        alert.messageText = "Connect Spotify"
        alert.informativeText = "Create an app at developer.spotify.com, add this Redirect URI, and paste its Client ID:\n\(SpotifySession.redirectURI)\n\nPlayback needs Spotify Premium and the Spotify app open on this Mac."
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
