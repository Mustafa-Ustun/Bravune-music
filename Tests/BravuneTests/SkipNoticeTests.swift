import XCTest
@testable import Bravune

@MainActor
final class SkipNoticeTests: XCTestCase {
    private func makePlayer(count: Int, unplayable: Set<String>) -> (Player, UnifiedQueue, FakeAdapter) {
        let adapter = FakeAdapter(id: "fake", count: count)
        adapter.unplayable = unplayable
        let queue = UnifiedQueue()
        queue.add(contentsOf: adapter.library)
        return (Player(queue: queue, adapters: [adapter.id: adapter]), queue, adapter)
    }

    func testSingleSkipProducesNoticeNamingTheTrack() async {
        let (player, queue, adapter) = makePlayer(count: 3, unplayable: ["1"])
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        XCTAssertNil(player.notice)
        adapter.playbacks[0].finish()
        let landed = await eventually { queue.currentIndex == 2 && player.state == .playing && player.notice != nil }
        XCTAssertTrue(landed)
        XCTAssertEqual(player.notice, "Skipped \u{201C}fake song 1\u{201D} (can\u{2019}t be played)")
        XCTAssertEqual(player.visibleNotice, player.notice)
        XCTAssertEqual(player.displaySubtitle(includeAlbum: true), player.notice)
    }

    func testSeveralSkipsAreSummarisedWithCount() async {
        let (player, queue, adapter) = makePlayer(count: 4, unplayable: ["1", "2"])
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        adapter.playbacks[0].finish()
        let landed = await eventually { queue.currentIndex == 3 && player.notice != nil }
        XCTAssertTrue(landed)
        XCTAssertEqual(player.notice, "Skipped 2 tracks that can\u{2019}t be played")
    }

    func testNoNoticeWhenNothingIsSkipped() async {
        let (player, _, adapter) = makePlayer(count: 3, unplayable: [])
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        adapter.playbacks[0].finish()
        _ = await eventually { adapter.playCalls == 2 }
        XCTAssertNil(player.notice)
        XCTAssertNil(player.visibleNotice)
    }

    func testNoticeExpiresAfterDuration() async {
        let (player, _, adapter) = makePlayer(count: 3, unplayable: ["1"])
        player.noticeDuration = 0.2
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        adapter.playbacks[0].finish()
        let shown = await eventually { player.notice != nil }
        XCTAssertTrue(shown)
        let gone = await eventually { player.notice == nil }
        XCTAssertTrue(gone)
    }

    func testUserActionClearsNotice() async {
        let (player, queue, adapter) = makePlayer(count: 4, unplayable: ["1"])
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        adapter.playbacks[0].finish()
        _ = await eventually { queue.currentIndex == 2 && player.notice != nil }
        player.next()
        _ = await eventually { queue.currentIndex == 3 && player.state == .playing }
        XCTAssertNil(player.notice)
    }

    func testStopClearsNotice() async {
        let (player, queue, adapter) = makePlayer(count: 3, unplayable: ["1"])
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        adapter.playbacks[0].finish()
        _ = await eventually { queue.currentIndex == 2 && player.notice != nil }
        player.stop()
        XCTAssertNil(player.notice)
    }

    func testEarlierSkipsDoNotLeakIntoALaterNotice() async {
        let (player, queue, adapter) = makePlayer(count: 6, unplayable: ["1", "4"])
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        adapter.playbacks[0].finish()
        _ = await eventually { queue.currentIndex == 2 && player.notice != nil }
        player.next()
        _ = await eventually { queue.currentIndex == 3 && player.state == .playing }
        player.next()
        _ = await eventually { queue.currentIndex == 5 && player.state == .playing && player.notice != nil }
        XCTAssertEqual(player.notice, "Skipped \u{201C}fake song 4\u{201D} (can\u{2019}t be played)")
    }

    func testFinalFailureShowsErrorAndNoNotice() async {
        let (player, _, adapter) = makePlayer(count: 3, unplayable: ["1", "2"])
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        adapter.playbacks[0].finish()
        let failed = await eventually { if case .failed = player.state { return true } else { return false } }
        XCTAssertTrue(failed)
        XCTAssertNil(player.notice)
        XCTAssertNil(player.visibleNotice)
    }

    func testNoticeStaysVisibleWhilePaused() async {
        let (player, queue, adapter) = makePlayer(count: 3, unplayable: ["1"])
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        adapter.playbacks[0].finish()
        _ = await eventually { queue.currentIndex == 2 && player.notice != nil }
        player.pause()
        XCTAssertNotNil(player.visibleNotice)
    }

    func testBackwardSkipProducesNotice() async {
        let (player, queue, _) = makePlayer(count: 3, unplayable: ["1"])
        player.play(at: 2)
        _ = await eventually { player.state == .playing }
        player.previous()
        let landed = await eventually { queue.currentIndex == 0 && player.notice != nil }
        XCTAssertTrue(landed)
        XCTAssertEqual(player.notice, "Skipped \u{201C}fake song 1\u{201D} (can\u{2019}t be played)")
    }

    func testOldExpiryDoesNotClearANewerNotice() async {
        let (player, queue, adapter) = makePlayer(count: 6, unplayable: ["1", "4"])
        player.noticeDuration = 0.5
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        adapter.playbacks[0].finish()
        _ = await eventually { queue.currentIndex == 2 && player.notice != nil }
        try? await Task.sleep(nanoseconds: 300_000_000)
        player.next()
        _ = await eventually { queue.currentIndex == 3 && player.state == .playing }
        player.next()
        _ = await eventually { queue.currentIndex == 5 && player.notice != nil }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(player.notice)
    }
}
