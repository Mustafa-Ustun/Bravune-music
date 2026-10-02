import XCTest
@testable import Bravune

@MainActor
final class AppStateTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() async throws {
        files.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
        files = []
    }

    private func makeState(_ adapters: [FakeAdapter], plan: Plan = .pro, storeURL: URL? = nil) -> AppState {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let subscription = Subscription(defaults: defaults)
        subscription.plan = plan
        let file = storeURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("SavedMixes.json")
        files.append(file)
        return AppState(
            adapters: adapters,
            access: ProviderAccess(defaults: defaults),
            subscription: subscription,
            savedMixes: SavedMixStore(fileURL: file),
            refreshesOnLaunch: false
        )
    }

    private func aiTransport(_ plan: [String: Any], stopReason: String = "end_turn") -> ScriptedTransport {
        ScriptedTransport(response: ScriptedTransport.reply(plan: plan, stopReason: stopReason))
    }

    func testRefreshUsesConnectedAdaptersOnly() async {
        let a = FakeAdapter(id: "alpha", count: 3)
        let b = FakeAdapter(id: "beta", count: 3, connected: false)
        let state = makeState([a, b])
        await state.refreshLibrary()
        XCTAssertEqual(state.library.count, 3)
        XCTAssertTrue(state.library.allSatisfy { $0.provider == a.id })
        XCTAssertNil(state.errorMessage)
    }

    func testRefreshKeepsOtherProvidersWhenOneFails() async {
        let a = FakeAdapter(id: "alpha", count: 3)
        let b = FakeAdapter(id: "beta", count: 2)
        a.failsLibrary = true
        let state = makeState([a, b])
        await state.refreshLibrary()
        XCTAssertEqual(state.library.count, 2)
        XCTAssertEqual(state.errorMessage, "Alpha: fake failure")
    }

    func testGenerateMixFillsQueueAndStartsPlayback() async throws {
        let a = FakeAdapter(id: "alpha", count: 10)
        let b = FakeAdapter(id: "beta", count: 10)
        let state = makeState([a, b])
        await state.refreshLibrary()
        let result = try state.generateMix(MixRequest(providers: [a.id, b.id], trackCount: 6))
        XCTAssertEqual(result.tracks.count, 6)
        XCTAssertEqual(state.queue.tracks, result.tracks)
        XCTAssertEqual(state.queue.currentIndex, 0)
        XCTAssertEqual(state.subscription.mixesToday, 1)
        let playing = await eventually { state.player.state == .playing }
        XCTAssertTrue(playing)
        let first = state.queue.tracks[0]
        let owner = first.provider == a.id ? a : b
        XCTAssertEqual(owner.loaded.first, first.id)
    }

    func testFreePlanBlocksOversizedMixAndKeepsQueue() async throws {
        let a = FakeAdapter(id: "alpha", count: 40)
        let state = makeState([a], plan: .free)
        await state.refreshLibrary()
        state.enqueue([a.library[0]])
        XCTAssertThrowsError(try state.generateMix(MixRequest(providers: [a.id], trackCount: 26))) {
            XCTAssertEqual($0 as? MixDenial, .tooManyTracks(25))
        }
        XCTAssertEqual(state.queue.tracks, [a.library[0]])
        XCTAssertEqual(state.subscription.mixesToday, 0)
    }

    func testFreePlanDailyLimit() async throws {
        let a = FakeAdapter(id: "alpha", count: 40)
        let state = makeState([a], plan: .free)
        await state.refreshLibrary()
        for _ in 0..<3 {
            try state.generateMix(MixRequest(providers: [a.id], trackCount: 5))
        }
        XCTAssertThrowsError(try state.generateMix(MixRequest(providers: [a.id], trackCount: 5))) {
            XCTAssertEqual($0 as? MixDenial, .dailyLimitReached(3))
        }
    }

    func testMixWithoutTracksKeepsExistingQueueAndUsage() async {
        let a = FakeAdapter(id: "alpha", count: 0)
        let state = makeState([a])
        await state.refreshLibrary()
        state.enqueue(syntheticTracks(ProviderID(rawValue: "old"), count: 2))
        XCTAssertThrowsError(try state.generateMix(MixRequest(providers: [a.id], trackCount: 5))) {
            XCTAssertEqual($0.localizedDescription, MixError.noTracks.localizedDescription)
        }
        XCTAssertEqual(state.queue.tracks.count, 2)
        XCTAssertEqual(state.subscription.mixesToday, 0)
    }

    func testAIMixThroughFakeTransportFillsQueueAndReportsUnsupported() async throws {
        let a = FakeAdapter(id: "alpha", count: 20)
        let b = FakeAdapter(id: "beta", count: 20)
        let state = makeState([a, b], plan: .proPlus)
        await state.refreshLibrary()
        let transport = aiTransport(ScriptedTransport.plan(
            providers: ["alpha", "beta"],
            trackCount: 8,
            distribution: ["alpha": 6, "beta": 2],
            avoidDuplicateArtists: true,
            unsupported: ["genre"]
        ))
        let output = try await state.generateAIMix("mostly alpha, no genre", transport: transport)
        XCTAssertEqual(output.plan.unsupported, ["genre"])
        XCTAssertEqual(output.result.tracks.count, 8)
        XCTAssertEqual(state.queue.tracks.filter { $0.provider == a.id }.count, 6)
        XCTAssertEqual(state.queue.tracks.filter { $0.provider == b.id }.count, 2)
        XCTAssertEqual(transport.callCount, 1)
        let body = String(data: try XCTUnwrap(transport.lastBody), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("alpha (Alpha): 20 tracks"))
        let playing = await eventually { state.player.state == .playing }
        XCTAssertTrue(playing)
    }

    func testAIMixRequiresProPlusAndNeverCallsTheTransport() async {
        let a = FakeAdapter(id: "alpha", count: 5)
        let state = makeState([a], plan: .pro)
        await state.refreshLibrary()
        let transport = aiTransport(ScriptedTransport.plan(providers: ["alpha"]))
        do {
            _ = try await state.generateAIMix("mix", transport: transport)
            XCTFail("expected denial")
        } catch {
            XCTAssertEqual(error as? MixDenial, .requires(.proPlus, "AI Mix"))
        }
        XCTAssertEqual(transport.callCount, 0)
        XCTAssertTrue(state.queue.tracks.isEmpty)
    }

    func testAIPlanNamingDisconnectedProviderUsesConnectedOnly() async throws {
        let a = FakeAdapter(id: "alpha", count: 10)
        let b = FakeAdapter(id: "beta", count: 10, connected: false)
        let state = makeState([a, b], plan: .proPlus)
        await state.refreshLibrary()
        let transport = aiTransport(ScriptedTransport.plan(providers: ["alpha", "beta"], trackCount: 6))
        _ = try await state.generateAIMix("mix", transport: transport)
        XCTAssertEqual(state.queue.tracks.count, 6)
        XCTAssertTrue(state.queue.tracks.allSatisfy { $0.provider == a.id })
    }

    func testAIRefusalLeavesQueueAndUsageUntouched() async {
        let a = FakeAdapter(id: "alpha", count: 10)
        let state = makeState([a], plan: .proPlus)
        await state.refreshLibrary()
        state.enqueue([a.library[0]])
        let transport = aiTransport(ScriptedTransport.plan(providers: ["alpha"]), stopReason: "refusal")
        do {
            _ = try await state.generateAIMix("mix", transport: transport)
            XCTFail("expected refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, AIError.refused.localizedDescription)
        }
        XCTAssertEqual(state.queue.tracks, [a.library[0]])
        XCTAssertEqual(state.subscription.mixesToday, 0)
    }

    func testDisconnectRemovesProviderTracksAndStopsPlayer() async throws {
        let a = FakeAdapter(id: "alpha", count: 5)
        let b = FakeAdapter(id: "beta", count: 5)
        let state = makeState([a, b])
        await state.refreshLibrary()
        state.queue.add(contentsOf: a.library + b.library)
        state.player.play(at: 0)
        _ = await eventually { state.player.state == .playing }
        await state.disconnect(a)
        XCTAssertEqual(a.disconnectCalls, 1)
        XCTAssertEqual(state.player.state, .stopped)
        XCTAssertTrue(state.queue.tracks.allSatisfy { $0.provider == b.id })
        XCTAssertEqual(state.queue.tracks.count, 5)
        XCTAssertTrue(state.library.allSatisfy { $0.provider == b.id })
    }

    func testDisconnectKeepsPlayingWhenOtherProviderIsCurrent() async {
        let a = FakeAdapter(id: "alpha", count: 3)
        let b = FakeAdapter(id: "beta", count: 3)
        let state = makeState([a, b])
        await state.refreshLibrary()
        state.queue.add(contentsOf: b.library + a.library)
        state.player.play(at: 0)
        _ = await eventually { state.player.state == .playing }
        await state.disconnect(a)
        XCTAssertEqual(state.player.state, .playing)
        XCTAssertEqual(state.queue.currentIndex, 0)
        XCTAssertEqual(state.queue.tracks.count, 3)
    }

    func testDisablingProviderDisconnectsAndHidesIt() async {
        let a = FakeAdapter(id: "alpha", count: 3)
        let b = FakeAdapter(id: "beta", count: 3)
        let state = makeState([a, b])
        await state.refreshLibrary()
        await state.setProvider(a, enabled: false)
        XCTAssertEqual(a.disconnectCalls, 1)
        XCTAssertEqual(state.visibleAdapters.map(\.id), [b.id])
        XCTAssertEqual(state.connectedAdapters.map(\.id), [b.id])
        XCTAssertTrue(state.library.allSatisfy { $0.provider == b.id })
        await state.connect(a)
        XCTAssertEqual(a.connectCalls, 0)
        await state.setProvider(a, enabled: true)
        XCTAssertEqual(state.visibleAdapters.count, 2)
        XCTAssertFalse(a.isConnected)
        await state.connect(a)
        XCTAssertEqual(a.connectCalls, 1)
        XCTAssertEqual(state.library.count, 6)
    }

    func testSavedMixRoundTripPersistsAndPlays() async throws {
        let a = FakeAdapter(id: "alpha", count: 20)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("SavedMixes.json")
        let state = makeState([a], storeURL: file)
        await state.refreshLibrary()
        try state.saveMix(named: "Morning", request: MixRequest(providers: [a.id], trackCount: 7, avoidDuplicateArtists: true))
        XCTAssertEqual(SavedMixStore(fileURL: file).mixes.first?.name, "Morning")
        let mix = try XCTUnwrap(state.savedMixes.mixes.first)
        let result = try state.runSavedMix(mix)
        XCTAssertEqual(result.tracks.count, 7)
        XCTAssertEqual(state.queue.tracks.count, 7)
        let playing = await eventually { state.player.state == .playing }
        XCTAssertTrue(playing)
        try state.deleteSavedMix(mix)
        XCTAssertTrue(SavedMixStore(fileURL: file).mixes.isEmpty)
    }

    func testSavedMixesRequireProAtSaveAndAtRun() async throws {
        let a = FakeAdapter(id: "alpha", count: 10)
        let state = makeState([a], plan: .free)
        await state.refreshLibrary()
        XCTAssertThrowsError(try state.saveMix(named: "x", request: MixRequest(providers: [a.id], trackCount: 5))) {
            XCTAssertEqual($0 as? MixDenial, .requires(.pro, "Saved Mixes"))
        }
        let mix = try state.savedMixes.add(name: "old", request: MixRequest(providers: [a.id], trackCount: 5))
        XCTAssertThrowsError(try state.runSavedMix(mix))
        XCTAssertTrue(state.queue.tracks.isEmpty)
    }

    func testSavedMixSkipsProvidersThatAreNoLongerConnected() async throws {
        let a = FakeAdapter(id: "alpha", count: 10)
        let b = FakeAdapter(id: "beta", count: 10)
        let state = makeState([a, b])
        await state.refreshLibrary()
        try state.saveMix(named: "both", request: MixRequest(providers: [a.id, b.id], trackCount: 8))
        await state.disconnect(b)
        let result = try state.runSavedMix(try XCTUnwrap(state.savedMixes.mixes.first))
        XCTAssertTrue(result.tracks.allSatisfy { $0.provider == a.id })
        XCTAssertEqual(result.tracks.count, 8)
    }

    func testRandomMixGating() async throws {
        let a = FakeAdapter(id: "alpha", count: 30)
        let free = makeState([a], plan: .free)
        await free.refreshLibrary()
        XCTAssertThrowsError(try free.generateRandomMix()) {
            XCTAssertEqual($0 as? MixDenial, .requires(.pro, "Random Mix"))
        }
        let pro = makeState([a], plan: .pro)
        await pro.refreshLibrary()
        let result = try pro.generateRandomMix()
        XCTAssertFalse(result.tracks.isEmpty)
        XCTAssertTrue(pro.queue.tracks.allSatisfy { $0.provider == a.id })
    }

    func testPlayFromLibraryRemoveAndClear() async {
        let a = FakeAdapter(id: "alpha", count: 4)
        let state = makeState([a])
        await state.refreshLibrary()
        state.play(state.library[2], in: state.library)
        XCTAssertEqual(state.queue.tracks, state.library)
        XCTAssertEqual(state.queue.currentIndex, 2)
        _ = await eventually { state.player.state == .playing }
        state.removeFromQueue(at: 0)
        XCTAssertEqual(state.queue.currentIndex, 1)
        XCTAssertEqual(state.player.state, .playing)
        state.removeFromQueue(at: 1)
        let continued = await eventually { state.queue.currentIndex == 1 && state.player.state == .playing }
        XCTAssertTrue(continued)
        XCTAssertEqual(state.queue.currentTrack?.id, state.library[3].id)
        state.clearQueue()
        XCTAssertEqual(state.player.state, .stopped)
        XCTAssertTrue(state.queue.tracks.isEmpty)
    }

    func testUnplayableTracksStayOutOfTheQueue() async {
        var tracks = syntheticTracks(ProviderID(rawValue: "alpha"), count: 4)
        tracks[3].metadata[UnifiedTrack.unplayableKey] = "1"
        let a = FakeAdapter(id: "alpha", tracks: tracks)
        let state = makeState([a])
        await state.refreshLibrary()
        let broken = state.library.first { $0.isUnplayable }!
        let playable = state.library.filter { !$0.isUnplayable }

        state.play(playable[0], in: state.library)
        XCTAssertEqual(state.queue.tracks, playable)

        state.clearQueue()
        state.enqueue(state.library)
        XCTAssertEqual(state.queue.tracks, playable)

        state.playNext([broken])
        XCTAssertEqual(state.queue.tracks, playable)

        state.play(broken, in: state.library)
        XCTAssertTrue(state.queue.tracks.contains(broken))
    }
}
