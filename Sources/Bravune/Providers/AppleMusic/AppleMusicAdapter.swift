import Foundation
import MusicKit
import Observation

enum AppleMusicError: LocalizedError {
    case missingBundleConfiguration
    case accessDenied
    case trackUnavailable

    var errorDescription: String? {
        switch self {
        case .missingBundleConfiguration: "Apple Music needs the signed Bravune app with the MusicKit capability"
        case .accessDenied: "Access to Apple Music was not granted"
        case .trackUnavailable: "This track is not available in the Apple Music library"
        }
    }
}

enum AppleMusicSubscriptionStatus: Equatable {
    case unknown
    case active
    case inactive
}

enum AppleMusicConnectionSummary {
    static func text(songCount: Int?, subscription: AppleMusicSubscriptionStatus) -> String {
        var parts = ["Authorized"]
        switch subscription {
        case .unknown: break
        case .active: parts.append("subscription active")
        case .inactive: parts.append("no active subscription")
        }
        if let songCount {
            parts.append(songCount == 1 ? "1 song in library" : "\(songCount) songs in library")
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

@MainActor
@Observable
final class AppleMusicAdapter: ProviderAdapter {
    private static let enabledKey = "bravune.appleMusic.enabled"

    let id = ProviderID.appleMusic
    let displayName = "Apple Music"

    private(set) var isAuthorized: Bool
    private(set) var isEnabled: Bool
    private(set) var subscription: AppleMusicSubscriptionStatus = .unknown
    private(set) var librarySongCount: Int?

    @ObservationIgnored private var songs: [String: Song] = [:]

    var isConnected: Bool {
        isAuthorized && isEnabled
    }

    var connectionDetail: String? {
        isConnected ? AppleMusicConnectionSummary.text(songCount: librarySongCount, subscription: subscription) : nil
    }

    init() {
        isAuthorized = MusicAuthorization.currentStatus == .authorized
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false
    }

    func connect() async throws {
        guard Bundle.main.object(forInfoDictionaryKey: "NSAppleMusicUsageDescription") != nil else {
            throw AppleMusicError.missingBundleConfiguration
        }
        let status = await MusicAuthorization.request()
        isAuthorized = status == .authorized
        isEnabled = isAuthorized
        UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        guard isAuthorized else { throw AppleMusicError.accessDenied }
        await refreshSubscription()
    }

    private func refreshSubscription() async {
        do {
            let current = try await MusicSubscription.current
            subscription = current.canPlayCatalogContent ? .active : .inactive
        } catch {
            subscription = .unknown
        }
    }

    func disconnect() {
        isEnabled = false
        songs.removeAll()
        librarySongCount = nil
        subscription = .unknown
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
    }

    func tracks() async throws -> [UnifiedTrack] {
        guard isConnected else { return [] }
        var request = MusicLibraryRequest<Song>()
        request.limit = 10_000
        let response = try await request.response()
        var cache: [String: Song] = [:]
        let result = response.items.map { song -> UnifiedTrack in
            cache[song.id.rawValue] = song
            let artwork = song.artwork?.url(width: 300, height: 300)
            return UnifiedTrack(
                provider: id,
                providerTrackId: song.id.rawValue,
                title: song.title,
                artist: song.artistName,
                album: song.albumTitle ?? "Unknown Album",
                duration: song.duration ?? 0,
                artwork: artwork.flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
            )
        }
        songs = cache
        librarySongCount = result.count
        if subscription == .unknown {
            await refreshSubscription()
        }
        return result.sortedForLibrary()
    }

    func makePlayback() -> any TrackPlayback {
        AppleMusicPlayback { [weak self] trackId in
            self?.songs[trackId]
        }
    }
}
