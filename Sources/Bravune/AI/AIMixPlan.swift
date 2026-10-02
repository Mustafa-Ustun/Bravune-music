import Foundation

struct AIMixPlan: Codable, Equatable {
    struct Share: Codable, Equatable {
        let provider: String
        let count: Int
    }

    let providers: [String]
    let trackCount: Int
    let durationMinutes: Int
    let distribution: [Share]
    let avoidDuplicateArtists: Bool
    let randomize: Bool
    let unsupported: [String]

    static let defaultTrackCount = 20
    static let fallbackTrackLength: TimeInterval = 210

    func makeRequest(connected: [ProviderID], averageTrackLength: TimeInterval) -> MixRequest {
        let known = Set(connected)
        var chosen: [ProviderID] = []
        for name in providers {
            let id = ProviderID(rawValue: name)
            if known.contains(id) && !chosen.contains(id) {
                chosen.append(id)
            }
        }
        if chosen.isEmpty {
            chosen = connected
        }

        let length = averageTrackLength > 0 ? averageTrackLength : Self.fallbackTrackLength
        let count: Int
        if trackCount > 0 {
            count = trackCount
        } else if durationMinutes > 0 {
            count = Int((Double(durationMinutes) * 60 / length).rounded())
        } else {
            count = Self.defaultTrackCount
        }

        var counts: [String: Int] = [:]
        for share in distribution where chosen.contains(ProviderID(rawValue: share.provider)) && share.count > 0 {
            counts[share.provider, default: 0] += share.count
        }

        return MixRequest(
            providers: chosen,
            trackCount: min(max(count, 1), 500),
            providerDistribution: counts,
            avoidDuplicateArtists: avoidDuplicateArtists,
            randomize: randomize
        )
    }
}
