import Foundation

enum MixError: LocalizedError {
    case noProviders
    case invalidTrackCount
    case noTracks

    var errorDescription: String? {
        switch self {
        case .noProviders: "Select at least one provider"
        case .invalidTrackCount: "The track count must be greater than zero"
        case .noTracks: "The selected providers have no tracks to mix"
        }
    }
}

struct MixResult: Equatable {
    let tracks: [UnifiedTrack]
    let requested: Int

    var isShort: Bool {
        tracks.count < requested
    }
}

struct MixEngine {
    func mix(_ request: MixRequest, from library: [UnifiedTrack]) throws -> MixResult {
        var generator = SystemRandomNumberGenerator()
        return try mix(request, from: library, using: &generator)
    }

    func mix(
        _ request: MixRequest,
        from library: [UnifiedTrack],
        using generator: inout some RandomNumberGenerator
    ) throws -> MixResult {
        var providers: [ProviderID] = []
        for provider in request.providers where !providers.contains(provider) {
            providers.append(provider)
        }
        guard !providers.isEmpty else { throw MixError.noProviders }
        let requested = request.effectiveTrackCount
        guard requested > 0 else { throw MixError.invalidTrackCount }

        var pools: [ProviderID: [UnifiedTrack]] = [:]
        var cursors: [ProviderID: Int] = [:]
        for provider in providers {
            let candidates = library.filter { $0.provider == provider && !$0.isUnplayable }
            pools[provider] = request.randomize ? candidates.shuffled(using: &generator) : candidates
            cursors[provider] = 0
        }

        var usedTracks = Set<String>()
        var usedArtists = Set<String>()

        func take(_ provider: ProviderID) -> UnifiedTrack? {
            let pool = pools[provider] ?? []
            while let cursor = cursors[provider], cursor < pool.count {
                cursors[provider] = cursor + 1
                let track = pool[cursor]
                let trackKey = Self.trackKey(track)
                if usedTracks.contains(trackKey) { continue }
                let artistKey = Self.artistKey(track)
                if request.avoidDuplicateArtists, let artistKey, usedArtists.contains(artistKey) { continue }
                usedTracks.insert(trackKey)
                if let artistKey { usedArtists.insert(artistKey) }
                return track
            }
            return nil
        }

        var picked: [ProviderID: [UnifiedTrack]] = [:]
        for (provider, target) in zip(providers, Self.targets(for: request, providers: providers, total: requested)) {
            var chosen: [UnifiedTrack] = []
            while chosen.count < target, let track = take(provider) {
                chosen.append(track)
            }
            picked[provider] = chosen
        }

        var remaining = requested - picked.values.reduce(0) { $0 + $1.count }
        var progressed = true
        while remaining > 0 && progressed {
            progressed = false
            for provider in providers where remaining > 0 {
                if let track = take(provider) {
                    picked[provider, default: []].append(track)
                    remaining -= 1
                    progressed = true
                }
            }
        }

        let ordered: [UnifiedTrack]
        if request.randomize {
            ordered = providers.flatMap { picked[$0] ?? [] }.shuffled(using: &generator)
        } else {
            let longest = providers.map { picked[$0]?.count ?? 0 }.max() ?? 0
            ordered = (0..<longest).flatMap { index in
                providers.compactMap { provider in
                    let list = picked[provider] ?? []
                    return index < list.count ? list[index] : nil
                }
            }
        }
        return MixResult(tracks: ordered, requested: requested)
    }

    private static func targets(for request: MixRequest, providers: [ProviderID], total: Int) -> [Int] {
        if request.usesDistribution {
            return providers.map { max(request.providerDistribution[$0.rawValue] ?? 0, 0) }
        }
        let base = total / providers.count
        let extra = total % providers.count
        return providers.indices.map { base + ($0 < extra ? 1 : 0) }
    }

    private static func trackKey(_ track: UnifiedTrack) -> String {
        "\(normalized(track.title))|\(normalized(track.artist))"
    }

    private static func artistKey(_ track: UnifiedTrack) -> String? {
        let key = normalized(track.artist)
        return key.isEmpty || key == "unknown artist" ? nil : key
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
