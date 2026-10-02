import Foundation

struct MixRequest: Codable, Equatable, Sendable {
    var providers: [ProviderID]
    var trackCount: Int
    var providerDistribution: [String: Int]
    var avoidDuplicateArtists: Bool
    var randomize: Bool

    init(
        providers: [ProviderID],
        trackCount: Int,
        providerDistribution: [String: Int] = [:],
        avoidDuplicateArtists: Bool = false,
        randomize: Bool = true
    ) {
        self.providers = providers
        self.trackCount = trackCount
        self.providerDistribution = providerDistribution
        self.avoidDuplicateArtists = avoidDuplicateArtists
        self.randomize = randomize
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try container.decode([ProviderID].self, forKey: .providers)
        trackCount = try container.decodeIfPresent(Int.self, forKey: .trackCount) ?? 0
        providerDistribution = try container.decodeIfPresent([String: Int].self, forKey: .providerDistribution) ?? [:]
        avoidDuplicateArtists = try container.decodeIfPresent(Bool.self, forKey: .avoidDuplicateArtists) ?? false
        randomize = try container.decodeIfPresent(Bool.self, forKey: .randomize) ?? true
    }

    var usesDistribution: Bool {
        !providerDistribution.isEmpty
    }

    var effectiveTrackCount: Int {
        guard usesDistribution else { return trackCount }
        return providers.reduce(0) { $0 + max(providerDistribution[$1.rawValue] ?? 0, 0) }
    }

    static func random(from providers: [ProviderID], using generator: inout some RandomNumberGenerator) -> MixRequest {
        let shuffled = providers.shuffled(using: &generator)
        let size = Int.random(in: 1...max(shuffled.count, 1), using: &generator)
        let chosen = providers.filter { shuffled.prefix(size).contains($0) }
        return MixRequest(
            providers: chosen,
            trackCount: Int.random(in: 15...40, using: &generator),
            avoidDuplicateArtists: true
        )
    }
}
