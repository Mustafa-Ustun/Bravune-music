import Foundation

struct UnifiedTrack: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let provider: ProviderID
    let providerTrackId: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var artwork: URL?
    var metadata: [String: String]

    init(
        provider: ProviderID,
        providerTrackId: String,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        artwork: URL? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = "\(provider.rawValue):\(providerTrackId)"
        self.provider = provider
        self.providerTrackId = providerTrackId
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artwork = artwork
        self.metadata = metadata
    }
}

extension UnifiedTrack {
    static let unplayableKey = "unplayable"

    var isUnplayable: Bool {
        metadata[Self.unplayableKey] != nil
    }
}

extension Array where Element == UnifiedTrack {
    func sortedForLibrary() -> [UnifiedTrack] {
        sorted {
            [$0.artist, $0.album, $0.title].lexicographicallyPrecedes([$1.artist, $1.album, $1.title]) { lhs, rhs in
                lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
        }
    }
}
