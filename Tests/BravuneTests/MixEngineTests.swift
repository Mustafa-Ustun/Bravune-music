import XCTest
@testable import Bravune

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

final class MixEngineTests: XCTestCase {
    private let spotify = ProviderID(rawValue: "spotify")
    private let youtube = ProviderID(rawValue: "youtube_music")
    private let local = ProviderID.localMusic

    private func tracks(_ provider: ProviderID, count: Int, artistPrefix: String? = nil, sameArtist: String? = nil) -> [UnifiedTrack] {
        (0..<count).map { index in
            UnifiedTrack(
                provider: provider,
                providerTrackId: "\(index)",
                title: "\(provider.rawValue) song \(index)",
                artist: sameArtist ?? "\(artistPrefix ?? provider.rawValue) artist \(index)",
                album: "Album",
                duration: 100
            )
        }
    }

    private func run(_ request: MixRequest, _ library: [UnifiedTrack], seed: UInt64 = 1) throws -> MixResult {
        var generator = SeededGenerator(state: seed)
        return try MixEngine().mix(request, from: library, using: &generator)
    }

    func testSpecExampleDistribution() throws {
        let library = tracks(spotify, count: 20) + tracks(youtube, count: 20) + tracks(local, count: 20)
        let request = MixRequest(
            providers: [spotify, youtube, local],
            trackCount: 22,
            providerDistribution: ["spotify": 5, "youtube_music": 7, "local_music": 10],
            avoidDuplicateArtists: true
        )
        let result = try run(request, library)
        XCTAssertEqual(result.tracks.count, 22)
        XCTAssertFalse(result.isShort)
        XCTAssertEqual(result.tracks.filter { $0.provider == spotify }.count, 5)
        XCTAssertEqual(result.tracks.filter { $0.provider == youtube }.count, 7)
        XCTAssertEqual(result.tracks.filter { $0.provider == local }.count, 10)
    }

    func testEvenSplitGivesRemainderToFirstProviders() throws {
        let library = tracks(spotify, count: 10) + tracks(local, count: 10)
        let result = try run(MixRequest(providers: [spotify, local], trackCount: 5, randomize: false), library)
        XCTAssertEqual(result.tracks.filter { $0.provider == spotify }.count, 3)
        XCTAssertEqual(result.tracks.filter { $0.provider == local }.count, 2)
    }

    func testShortfallIsRedistributedToOtherProviders() throws {
        let library = tracks(spotify, count: 2) + tracks(local, count: 20)
        let result = try run(MixRequest(providers: [spotify, local], trackCount: 10), library)
        XCTAssertEqual(result.tracks.count, 10)
        XCTAssertEqual(result.tracks.filter { $0.provider == spotify }.count, 2)
    }

    func testReportsShortMixWhenLibraryIsTooSmall() throws {
        let library = tracks(local, count: 4)
        let result = try run(MixRequest(providers: [local], trackCount: 10), library)
        XCTAssertEqual(result.tracks.count, 4)
        XCTAssertTrue(result.isShort)
    }

    func testAvoidDuplicateArtists() throws {
        let library = tracks(spotify, count: 10, sameArtist: "Same") + tracks(local, count: 10, artistPrefix: "x")
        let result = try run(MixRequest(providers: [spotify, local], trackCount: 8, avoidDuplicateArtists: true), library)
        let artists = result.tracks.map(\.artist)
        XCTAssertEqual(Set(artists).count, artists.count)
        XCTAssertEqual(result.tracks.filter { $0.artist == "Same" }.count, 1)
    }

    func testSameSongOnTwoProvidersAppearsOnce() throws {
        let one = UnifiedTrack(provider: spotify, providerTrackId: "1", title: "Song", artist: "Artist", album: "A", duration: 1)
        let two = UnifiedTrack(provider: local, providerTrackId: "2", title: " song ", artist: "ARTIST", album: "B", duration: 1)
        let result = try run(MixRequest(providers: [spotify, local], trackCount: 2), [one, two])
        XCTAssertEqual(result.tracks.count, 1)
    }

    func testNonRandomInterleavesProviders() throws {
        let library = tracks(spotify, count: 3) + tracks(local, count: 3)
        let result = try run(MixRequest(providers: [spotify, local], trackCount: 6, randomize: false), library)
        XCTAssertEqual(result.tracks.map(\.provider), [spotify, local, spotify, local, spotify, local])
    }

    func testSameSeedGivesSameMix() throws {
        let library = tracks(spotify, count: 30) + tracks(local, count: 30)
        let request = MixRequest(providers: [spotify, local], trackCount: 12)
        XCTAssertEqual(try run(request, library, seed: 7), try run(request, library, seed: 7))
    }

    func testOnlyRequestedProvidersAreUsed() throws {
        let library = tracks(spotify, count: 10) + tracks(local, count: 10)
        let result = try run(MixRequest(providers: [local], trackCount: 5), library)
        XCTAssertTrue(result.tracks.allSatisfy { $0.provider == local })
    }

    func testInvalidRequests() {
        XCTAssertThrowsError(try run(MixRequest(providers: [], trackCount: 5), []))
        XCTAssertThrowsError(try run(MixRequest(providers: [local], trackCount: 0), []))
    }

    func testDecodesSpecJSON() throws {
        let json = """
        {"providers":["spotify","youtube_music","local_music"],"trackCount":22,"providerDistribution":{"spotify":5,"youtube_music":7,"local_music":10},"avoidDuplicateArtists":true}
        """
        let request = try JSONDecoder().decode(MixRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.providers, [spotify, youtube, local])
        XCTAssertEqual(request.effectiveTrackCount, 22)
        XCTAssertTrue(request.avoidDuplicateArtists)
        XCTAssertTrue(request.randomize)
    }
}

@MainActor
final class SubscriptionTests: XCTestCase {
    private func makeSubscription(_ plan: Plan, now: @escaping () -> Date = Date.init) -> Subscription {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let subscription = Subscription(defaults: defaults, now: now)
        subscription.plan = plan
        return subscription
    }

    func testFreeLimits() {
        let subscription = makeSubscription(.free)
        let local = ProviderID.localMusic
        XCTAssertNoThrow(try subscription.authorize(MixRequest(providers: [local], trackCount: 25)))
        XCTAssertThrowsError(try subscription.authorize(MixRequest(providers: [local], trackCount: 26)))
        XCTAssertThrowsError(try subscription.authorize(MixRequest(providers: [local], trackCount: 10, providerDistribution: ["local_music": 10])))
        XCTAssertThrowsError(try subscription.authorize(MixRequest(providers: [local], trackCount: 10, avoidDuplicateArtists: true)))
        XCTAssertThrowsError(try subscription.authorizeRandomMix())
    }

    func testFreeDailyLimitResetsNextDay() {
        var current = Date()
        let subscription = makeSubscription(.free, now: { current })
        let request = MixRequest(providers: [.localMusic], trackCount: 5)
        for _ in 0..<3 {
            XCTAssertNoThrow(try subscription.authorize(request))
            subscription.recordMix()
        }
        XCTAssertEqual(subscription.remainingMixes, 0)
        XCTAssertThrowsError(try subscription.authorize(request))
        current = current.addingTimeInterval(86_400 * 2)
        let next = Subscription(defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { current })
        XCTAssertEqual(next.remainingMixes, 3)
    }

    func testProIsUnlimited() {
        let subscription = makeSubscription(.pro)
        XCTAssertNil(subscription.remainingMixes)
        XCTAssertNoThrow(try subscription.authorize(MixRequest(providers: [.localMusic], trackCount: 500, providerDistribution: ["local_music": 500], avoidDuplicateArtists: true)))
        XCTAssertNoThrow(try subscription.authorizeRandomMix())
    }
}

@MainActor
final class SavedMixStoreTests: XCTestCase {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("SavedMixes.json")
    }

    func testPersistsAcrossInstances() throws {
        let file = temporaryFile()
        let request = MixRequest(providers: [.localMusic], trackCount: 12, avoidDuplicateArtists: true)
        let store = SavedMixStore(fileURL: file)
        try store.add(name: "  Morning  ", request: request)
        let reloaded = SavedMixStore(fileURL: file)
        XCTAssertEqual(reloaded.mixes.count, 1)
        XCTAssertEqual(reloaded.mixes.first?.name, "Morning")
        XCTAssertEqual(reloaded.mixes.first?.request, request)
    }

    func testRenameAndRemove() throws {
        let file = temporaryFile()
        let store = SavedMixStore(fileURL: file)
        let mix = try store.add(name: "A", request: MixRequest(providers: [.localMusic], trackCount: 5))
        try store.rename(mix.id, to: "B")
        XCTAssertEqual(SavedMixStore(fileURL: file).mixes.first?.name, "B")
        try store.remove(mix.id)
        XCTAssertTrue(SavedMixStore(fileURL: file).mixes.isEmpty)
    }

    func testEmptyNameGetsDefault() throws {
        let store = SavedMixStore(fileURL: temporaryFile())
        let mix = try store.add(name: "   ", request: MixRequest(providers: [.localMusic], trackCount: 5))
        XCTAssertEqual(mix.name, "Untitled Mix")
    }

    func testCorruptFileStartsEmpty() throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        XCTAssertTrue(SavedMixStore(fileURL: file).mixes.isEmpty)
    }

    func testSavedMixesRequirePro() {
        let subscription = Subscription(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertThrowsError(try subscription.authorizeSavedMixes())
        subscription.plan = .pro
        XCTAssertNoThrow(try subscription.authorizeSavedMixes())
    }
}
