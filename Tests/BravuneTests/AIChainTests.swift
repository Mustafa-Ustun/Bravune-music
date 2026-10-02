import XCTest
@testable import Bravune

@MainActor
final class AIChainTests: XCTestCase {
    private let spotify = ProviderID(rawValue: "spotify")
    private let local = ProviderID.localMusic

    private var context: AIContext {
        AIContext(providers: [
            .init(id: spotify, name: "Spotify", trackCount: 40),
            .init(id: local, name: "Local Music", trackCount: 40)
        ])
    }

    private func run(_ plan: [String: Any], library: [UnifiedTrack]) async throws -> (AIMixPlan, MixRequest, MixResult, UnifiedQueue) {
        let transport = ScriptedTransport(response: ScriptedTransport.reply(plan: plan))
        let aiPlan = try await AIEngine(transport: transport).plan(for: "request", context: context)
        let durations = library.map(\.duration)
        let average = durations.reduce(0, +) / Double(durations.count)
        let request = aiPlan.makeRequest(connected: [spotify, local], averageTrackLength: average)
        var generator = SeededGenerator(state: 42)
        let result = try MixEngine().mix(request, from: library, using: &generator)
        let queue = UnifiedQueue()
        queue.add(contentsOf: result.tracks)
        return (aiPlan, request, result, queue)
    }

    func testDurationRequestBecomesTrackCountAndFillsQueue() async throws {
        let library = syntheticTracks(spotify, count: 40, duration: 240) + syntheticTracks(local, count: 40, duration: 240)
        let plan = ScriptedTransport.plan(providers: ["spotify", "local_music"], durationMinutes: 60, distribution: ["spotify": 10, "local_music": 5])
        let (_, request, result, queue) = try await run(plan, library: library)
        XCTAssertEqual(request.trackCount, 15)
        XCTAssertEqual(request.effectiveTrackCount, 15)
        XCTAssertEqual(result.tracks.count, 15)
        XCTAssertEqual(queue.tracks.count, 15)
        XCTAssertEqual(queue.tracks.filter { $0.provider == spotify }.count, 10)
        XCTAssertEqual(queue.tracks.filter { $0.provider == local }.count, 5)
    }

    func testArtistRuleAndProviderSelectionSurviveTheWholeChain() async throws {
        let library = syntheticTracks(spotify, count: 40) + syntheticTracks(local, count: 40)
        let plan = ScriptedTransport.plan(providers: ["spotify"], trackCount: 10, avoidDuplicateArtists: true)
        let (_, request, _, queue) = try await run(plan, library: library)
        XCTAssertEqual(request.providers, [spotify])
        XCTAssertTrue(queue.tracks.allSatisfy { $0.provider == spotify })
        XCTAssertEqual(queue.tracks.count, 10)
        XCTAssertEqual(Set(queue.tracks.map(\.artist)).count, 10)
    }

    func testUnsupportedRequirementsAreReportedAndNotFabricated() async throws {
        let library = syntheticTracks(spotify, count: 40)
        let plan = ScriptedTransport.plan(providers: ["spotify"], durationMinutes: 90, unsupported: ["Indonesian hip-hop genre", "underground", "2010s"])
        let (aiPlan, request, result, queue) = try await run(plan, library: library)
        XCTAssertEqual(aiPlan.unsupported, ["Indonesian hip-hop genre", "underground", "2010s"])
        XCTAssertEqual(request.providers, [spotify])
        XCTAssertEqual(result.tracks.count, 23)
        XCTAssertEqual(queue.tracks.count, 23)
        XCTAssertTrue(queue.tracks.allSatisfy { $0.metadata.isEmpty })
    }

    func testDistributionOverridesStatedTrackCount() async throws {
        let library = syntheticTracks(spotify, count: 40) + syntheticTracks(local, count: 40)
        let plan = ScriptedTransport.plan(providers: ["spotify", "local_music"], trackCount: 50, distribution: ["spotify": 6, "local_music": 2])
        let (_, request, _, queue) = try await run(plan, library: library)
        XCTAssertEqual(request.effectiveTrackCount, 8)
        XCTAssertEqual(queue.tracks.count, 8)
    }

    func testShortLibraryProducesShortMixNotAnError() async throws {
        let library = syntheticTracks(spotify, count: 4)
        let plan = ScriptedTransport.plan(providers: ["spotify"], trackCount: 10)
        let (_, _, result, queue) = try await run(plan, library: library)
        XCTAssertTrue(result.isShort)
        XCTAssertEqual(queue.tracks.count, 4)
    }
}
