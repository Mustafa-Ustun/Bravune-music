import XCTest
@testable import Bravune

@MainActor
final class NowPlayingDisplayTests: XCTestCase {
    private func makePlayer(count: Int = 2) -> (Player, FakeAdapter) {
        let adapter = FakeAdapter(id: "fake", count: count)
        let queue = UnifiedQueue()
        queue.add(contentsOf: adapter.library)
        return (Player(queue: queue, adapters: [adapter.id: adapter]), adapter)
    }

    func testIdlePlayerShowsNotPlayingAndNoSubtitle() {
        let (player, _) = makePlayer()
        XCTAssertEqual(player.displayTitle, "Not Playing")
        XCTAssertEqual(player.displaySubtitle(includeAlbum: false), "")
        XCTAssertEqual(player.displaySubtitle(includeAlbum: true), "")
    }

    func testPlayingTrackShowsTitleAndArtist() async {
        let (player, adapter) = makePlayer()
        player.play(at: 1)
        _ = await eventually { player.state == .playing }
        let track = adapter.library[1]
        XCTAssertEqual(player.displayTitle, track.title)
        XCTAssertEqual(player.displaySubtitle(includeAlbum: false), track.artist)
        XCTAssertEqual(player.displaySubtitle(includeAlbum: true), "\(track.artist) — \(track.album)")
    }

    func testLoadingShowsLoadingInBothLayouts() {
        let (player, _) = makePlayer()
        player.play(at: 0)
        XCTAssertEqual(player.state, .loading)
        XCTAssertEqual(player.displaySubtitle(includeAlbum: false), "Loading")
        XCTAssertEqual(player.displaySubtitle(includeAlbum: true), "Loading")
    }

    func testFailureMessageReplacesTheSubtitleButKeepsTheTitle() async {
        let (player, adapter) = makePlayer()
        adapter.failsLoads = true
        player.play(at: 0)
        _ = await eventually { player.state == .failed("fake failure") }
        XCTAssertEqual(player.displaySubtitle(includeAlbum: false), "fake failure")
        XCTAssertEqual(player.displayTitle, adapter.library[0].title)
    }

    func testPausedStillShowsTheCurrentTrack() async {
        let (player, adapter) = makePlayer()
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        player.pause()
        XCTAssertEqual(player.displayTitle, adapter.library[0].title)
        XCTAssertEqual(player.displaySubtitle(includeAlbum: false), adapter.library[0].artist)
    }

    func testTheMenuBarAndTheMainWindowControlTheSamePlayerAndQueue() async {
        let adapter = FakeAdapter(id: "fake", count: 3)
        let state = AppState(adapters: [adapter], refreshesOnLaunch: false)
        await state.refreshLibrary()
        state.queue.add(contentsOf: state.library)
        let menuBarPlayer = state.player
        menuBarPlayer.play(at: 0)
        _ = await eventually { menuBarPlayer.state == .playing }
        menuBarPlayer.next()
        _ = await eventually { state.queue.currentIndex == 1 && menuBarPlayer.state == .playing }
        XCTAssertEqual(state.player.displayTitle, state.library[1].title)
        XCTAssertTrue(menuBarPlayer === state.player)
        XCTAssertTrue(menuBarPlayer.queue === state.queue)
        menuBarPlayer.togglePlayPause()
        XCTAssertEqual(state.player.state, .paused)
        menuBarPlayer.volume = 0.4
        XCTAssertEqual(state.player.volume, 0.4, accuracy: 0.001)
    }
}
