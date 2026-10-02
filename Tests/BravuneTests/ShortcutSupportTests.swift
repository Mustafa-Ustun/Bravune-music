import XCTest
@testable import Bravune

@MainActor
final class ShortcutSupportTests: XCTestCase {
    private func makeState(count: Int) async -> (AppState, FakeAdapter) {
        let adapter = FakeAdapter(id: "fake", count: count)
        let state = AppState(adapters: [adapter], refreshesOnLaunch: false)
        await state.refreshLibrary()
        state.queue.add(contentsOf: state.library)
        return (state, adapter)
    }

    func testVolumeStepsUpAndDownByTenPercent() {
        let player = Player(queue: UnifiedQueue(), adapters: [:])
        player.volume = 0.5
        player.changeVolume(by: Player.volumeStep)
        XCTAssertEqual(player.volume, 0.6, accuracy: 0.001)
        player.changeVolume(by: -Player.volumeStep)
        player.changeVolume(by: -Player.volumeStep)
        XCTAssertEqual(player.volume, 0.4, accuracy: 0.001)
    }

    func testVolumeNeverLeavesZeroToOne() {
        let player = Player(queue: UnifiedQueue(), adapters: [:])
        player.volume = 0.95
        player.changeVolume(by: Player.volumeStep)
        player.changeVolume(by: Player.volumeStep)
        XCTAssertEqual(player.volume, 1, accuracy: 0.001)
        player.volume = 0.05
        player.changeVolume(by: -Player.volumeStep)
        player.changeVolume(by: -Player.volumeStep)
        XCTAssertEqual(player.volume, 0, accuracy: 0.001)
    }

    func testVolumeChangeReachesTheActiveEngine() async {
        let (state, adapter) = await makeState(count: 2)
        state.player.play(at: 0)
        _ = await eventually { state.player.state == .playing }
        state.player.volume = 0.5
        state.player.changeVolume(by: Player.volumeStep)
        XCTAssertEqual(adapter.playbacks[0].volume, 0.6, accuracy: 0.001)
    }

    func testDeleteRemovesSeveralSelectedRowsWithoutShiftingTheOthers() async {
        let (state, adapter) = await makeState(count: 6)
        state.removeFromQueue(indices: [1, 3, 4])
        XCTAssertEqual(state.queue.tracks.map(\.id), [0, 2, 5].map { adapter.library[$0].id })
    }

    func testDeletingTheCurrentTrackWhilePlayingContinuesWithTheNextOne() async {
        let (state, adapter) = await makeState(count: 4)
        state.player.play(at: 2)
        _ = await eventually { state.player.state == .playing }
        state.removeFromQueue(indices: [2])
        let moved = await eventually { state.queue.currentTrack?.id == adapter.library[3].id && state.player.state == .playing }
        XCTAssertTrue(moved)
        XCTAssertEqual(state.queue.currentIndex, 2)
        XCTAssertEqual(state.queue.tracks.map(\.id), [0, 1, 3].map { adapter.library[$0].id })
    }

    func testDeletingTheLastTrackWhilePlayingStops() async {
        let (state, adapter) = await makeState(count: 3)
        state.player.play(at: 2)
        _ = await eventually { state.player.state == .playing }
        state.removeFromQueue(indices: [2])
        XCTAssertEqual(state.player.state, .stopped)
        XCTAssertNil(state.queue.currentIndex)
        XCTAssertEqual(state.queue.tracks.map(\.id), [0, 1].map { adapter.library[$0].id })
    }

    func testDeletingThePausedTrackStopsAndDoesNotAutoPlay() async {
        let (state, adapter) = await makeState(count: 4)
        state.player.play(at: 1)
        _ = await eventually { state.player.state == .playing }
        state.player.pause()
        state.removeFromQueue(indices: [1])
        XCTAssertEqual(state.player.state, .stopped)
        XCTAssertNil(state.queue.currentIndex)
        XCTAssertEqual(adapter.playCalls, 1)
    }

    func testDeletingTheCurrentTrackTogetherWithTheOnesAfterItStopsAtTheEnd() async {
        let (state, adapter) = await makeState(count: 4)
        state.player.play(at: 1)
        _ = await eventually { state.player.state == .playing }
        state.removeFromQueue(indices: [1, 2, 3])
        XCTAssertEqual(state.player.state, .stopped)
        XCTAssertEqual(state.queue.tracks.map(\.id), [adapter.library[0].id])
    }

    func testDeletingTheCurrentAndEarlierRowsContinuesWithTheRightTrack() async {
        let (state, adapter) = await makeState(count: 5)
        state.player.play(at: 2)
        _ = await eventually { state.player.state == .playing }
        state.removeFromQueue(indices: [0, 2])
        let moved = await eventually { state.queue.currentTrack?.id == adapter.library[3].id && state.player.state == .playing }
        XCTAssertTrue(moved)
        XCTAssertEqual(state.queue.tracks.map(\.id), [1, 3, 4].map { adapter.library[$0].id })
    }

    func testDeletingRowsAroundThePlayingTrackKeepsItPlaying() async {
        let (state, adapter) = await makeState(count: 5)
        state.player.play(at: 2)
        _ = await eventually { state.player.state == .playing }
        state.removeFromQueue(indices: [0, 4])
        XCTAssertEqual(state.player.state, .playing)
        XCTAssertEqual(state.queue.currentTrack?.id, adapter.library[2].id)
        XCTAssertEqual(state.queue.currentIndex, 1)
    }

    func testDeletingNothingOrOutOfRangeRowsChangesNothing() async {
        let (state, adapter) = await makeState(count: 3)
        state.removeFromQueue(indices: [])
        state.removeFromQueue(indices: [7, 9])
        XCTAssertEqual(state.queue.tracks.map(\.id), adapter.library.map(\.id))
    }
}

final class SpaceBarShortcutTests: XCTestCase {
    private func handles(
        keyCode: UInt16 = SpaceBarShortcut.spaceKeyCode,
        hasModifiers: Bool = false,
        isRepeat: Bool = false,
        isEditingText: Bool = false,
        hasModalWindow: Bool = false
    ) -> Bool {
        SpaceBarShortcut.shouldHandle(
            keyCode: keyCode,
            hasModifiers: hasModifiers,
            isRepeat: isRepeat,
            isEditingText: isEditingText,
            hasModalWindow: hasModalWindow
        )
    }

    func testPlainSpaceIsHandled() {
        XCTAssertTrue(handles())
    }

    func testOtherKeysAreNeverHandled() {
        XCTAssertFalse(handles(keyCode: 0))
        XCTAssertFalse(handles(keyCode: 36))
        XCTAssertFalse(handles(keyCode: 51))
    }

    func testSpaceWithAnyModifierIsLeftAlone() {
        XCTAssertFalse(handles(hasModifiers: true))
    }

    func testTypingASpaceInATextFieldIsNotStolen() {
        XCTAssertFalse(handles(isEditingText: true))
    }

    func testHeldDownSpaceDoesNotToggleRepeatedly() {
        XCTAssertFalse(handles(isRepeat: true))
    }

    func testSpaceInsideAModalAlertIsLeftAlone() {
        XCTAssertFalse(handles(hasModalWindow: true))
    }
}
