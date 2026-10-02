import XCTest
@testable import Bravune

@MainActor
final class PlayerFailureTests: XCTestCase {
    private func makePlayer(count: Int = 3, adapter: FakeAdapter? = nil) -> (Player, UnifiedQueue, FakeAdapter) {
        let adapter = adapter ?? FakeAdapter(id: "fake", count: count)
        let queue = UnifiedQueue()
        queue.add(contentsOf: adapter.library)
        return (Player(queue: queue, adapters: [adapter.id: adapter]), queue, adapter)
    }

    func testLoadFailureSetsFailedState() async {
        let (player, _, adapter) = makePlayer()
        adapter.failsLoads = true
        player.play(at: 0)
        let failed = await eventually { player.state == .failed("fake failure") }
        XCTAssertTrue(failed, "state was \(player.state)")
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(adapter.playCalls, 0)
    }

    func testRecoversAfterFailure() async {
        let (player, _, adapter) = makePlayer()
        adapter.failsLoads = true
        player.play(at: 0)
        _ = await eventually { player.state == .failed("fake failure") }
        adapter.failsLoads = false
        player.play()
        let playing = await eventually { player.state == .playing }
        XCTAssertTrue(playing, "state was \(player.state)")
    }

    func testUnknownProviderFails() {
        let queue = UnifiedQueue()
        queue.add(syntheticTracks(ProviderID(rawValue: "ghost"), count: 1)[0])
        let player = Player(queue: queue, adapters: [:])
        player.play(at: 0)
        XCTAssertEqual(player.state, .failed("ghost is unavailable"))
    }

    func testFinishAdvancesThenStopsAtQueueEnd() async throws {
        let (player, queue, adapter) = makePlayer(count: 2)
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        adapter.playbacks[0].finish()
        let advanced = await eventually { queue.currentIndex == 1 && player.state == .playing }
        XCTAssertTrue(advanced)
        adapter.playbacks[0].finish()
        XCTAssertEqual(player.state, .stopped)
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(queue.currentIndex, 1)
    }

    func testSupersededLoadNeverPlaysTheOldTrack() async {
        let (player, queue, adapter) = makePlayer(count: 3)
        adapter.loadDelays["0"] = 300_000_000
        player.play(at: 0)
        player.play(at: 1)
        let playing = await eventually { player.state == .playing }
        XCTAssertTrue(playing)
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(queue.currentIndex, 1)
        XCTAssertEqual(player.state, .playing)
        XCTAssertEqual(adapter.playCalls, 1)
    }

    func testPauseIsIgnoredWhenNotPlayingAndTogglePlayPauseWorks() async {
        let (player, _, adapter) = makePlayer()
        player.pause()
        XCTAssertEqual(player.state, .stopped)
        player.togglePlayPause()
        _ = await eventually { player.state == .playing }
        player.togglePlayPause()
        XCTAssertEqual(player.state, .paused)
        player.togglePlayPause()
        XCTAssertEqual(player.state, .playing)
        XCTAssertEqual(adapter.playCalls, 2)
    }

    func testPreviousRestartsWhenPastThreeSecondsOrAtFirstTrack() async {
        let (player, queue, adapter) = makePlayer()
        player.play(at: 1)
        _ = await eventually { player.state == .playing }
        player.seek(to: 5)
        player.previous()
        XCTAssertEqual(queue.currentIndex, 1)
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(adapter.playbacks[0].lastSeek, 0)
        player.previous()
        let moved = await eventually { queue.currentIndex == 0 && player.state == .playing }
        XCTAssertTrue(moved)
        player.previous()
        XCTAssertEqual(queue.currentIndex, 0)
    }

    func testVolumeReachesEnginesCreatedLater() async {
        let (player, _, adapter) = makePlayer()
        player.volume = 0.3
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        XCTAssertEqual(adapter.playbacks[0].volume, 0.3, accuracy: 0.001)
        player.volume = 0.6
        XCTAssertEqual(adapter.playbacks[0].volume, 0.6, accuracy: 0.001)
    }

    func testStopClearsPositionAndStopsEngine() async {
        let (player, _, adapter) = makePlayer()
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        player.stop()
        XCTAssertEqual(player.state, .stopped)
        XCTAssertEqual(player.position, 0)
        XCTAssertGreaterThanOrEqual(adapter.stopCalls, 1)
    }

    func testPlayOnEmptyQueueDoesNothing() {
        let player = Player(queue: UnifiedQueue(), adapters: [:])
        player.play()
        XCTAssertEqual(player.state, .stopped)
    }

    private func unplayableMessage(_ adapter: FakeAdapter, _ index: Int) -> String {
        TrackUnplayableError(title: adapter.library[index].title).localizedDescription
    }

    func testUnplayableTrackInTheMiddleIsSkippedOnAutoAdvance() async {
        let (player, queue, adapter) = makePlayer(count: 3)
        adapter.unplayable = ["1"]
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        adapter.playbacks[0].finish()
        let landed = await eventually { queue.currentIndex == 2 && player.state == .playing }
        XCTAssertTrue(landed, "index \(String(describing: queue.currentIndex)), state \(player.state)")
        XCTAssertEqual(adapter.loaded, ["fake:0", "fake:1", "fake:2"])
        XCTAssertEqual(adapter.playCalls, 2)
    }

    func testSeveralUnplayableTracksInARowAreAllSkipped() async {
        let (player, queue, adapter) = makePlayer(count: 4)
        adapter.unplayable = ["1", "2"]
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        adapter.playbacks[0].finish()
        let landed = await eventually { queue.currentIndex == 3 && player.state == .playing }
        XCTAssertTrue(landed)
        XCTAssertEqual(adapter.playCalls, 2)
    }

    func testUnplayableLastTrackEndsWithFriendlyMessageNotRawError() async {
        let (player, queue, adapter) = makePlayer(count: 2)
        adapter.unplayable = ["1"]
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        adapter.playbacks[0].finish()
        let failed = await eventually { player.state == .failed(self.unplayableMessage(adapter, 1)) }
        XCTAssertTrue(failed, "state was \(player.state)")
        XCTAssertEqual(queue.currentIndex, 1)
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(unplayableMessage(adapter, 1), "Couldn\u{2019}t play \u{201C}fake song 1\u{201D}")
    }

    func testEverythingAfterAnUnplayableTrackBeingBadEndsAtQueueEnd() async {
        let (player, queue, adapter) = makePlayer(count: 3)
        adapter.unplayable = ["1", "2"]
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        adapter.playbacks[0].finish()
        let failed = await eventually { player.state == .failed(self.unplayableMessage(adapter, 2)) }
        XCTAssertTrue(failed, "state was \(player.state)")
        XCTAssertEqual(queue.currentIndex, 2)
        XCTAssertEqual(adapter.loaded, ["fake:0", "fake:1", "fake:2"])
    }

    func testSelectingAnUnplayableTrackSkipsForward() async {
        let (player, queue, adapter) = makePlayer(count: 3)
        adapter.unplayable = ["0"]
        player.play(at: 0)
        let landed = await eventually { queue.currentIndex == 1 && player.state == .playing }
        XCTAssertTrue(landed)
        XCTAssertEqual(adapter.playCalls, 1)
    }

    func testNextOntoAnUnplayableTrackSkipsForward() async {
        let (player, queue, adapter) = makePlayer(count: 3)
        adapter.unplayable = ["1"]
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        player.next()
        let landed = await eventually { queue.currentIndex == 2 && player.state == .playing }
        XCTAssertTrue(landed)
    }

    func testPreviousOntoAnUnplayableTrackSkipsBackward() async {
        let (player, queue, adapter) = makePlayer(count: 3)
        adapter.unplayable = ["1"]
        player.play(at: 2)
        _ = await eventually { player.state == .playing }
        player.previous()
        let landed = await eventually { queue.currentIndex == 0 && player.state == .playing }
        XCTAssertTrue(landed, "index \(String(describing: queue.currentIndex)), state \(player.state)")
    }

    func testPreviousWithNothingPlayableBeforeFailsAtTheStart() async {
        let (player, queue, adapter) = makePlayer(count: 3)
        adapter.unplayable = ["0", "1"]
        player.play(at: 2)
        _ = await eventually { player.state == .playing }
        player.previous()
        let failed = await eventually { player.state == .failed(self.unplayableMessage(adapter, 0)) }
        XCTAssertTrue(failed, "state was \(player.state)")
        XCTAssertEqual(queue.currentIndex, 0)
    }

    func testProviderLevelFailuresDoNotSkipAnything() async {
        let (player, queue, adapter) = makePlayer(count: 3)
        adapter.failsLoads = true
        player.play(at: 0)
        let failed = await eventually { player.state == .failed("fake failure") }
        XCTAssertTrue(failed)
        XCTAssertEqual(queue.currentIndex, 0)
        XCTAssertEqual(adapter.loaded, ["fake:0"])
    }

    func testQueueEndStillStopsAfterSkippingToTheLastPlayableTrack() async {
        let (player, queue, adapter) = makePlayer(count: 3)
        adapter.unplayable = ["1"]
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        adapter.playbacks[0].finish()
        _ = await eventually { queue.currentIndex == 2 && player.state == .playing }
        adapter.playbacks[0].finish()
        XCTAssertEqual(player.state, .stopped)
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(queue.currentIndex, 2)
    }
}
