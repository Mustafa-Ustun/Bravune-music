import XCTest
@testable import Bravune

final class AppleMusicEndDetectorTests: XCTestCase {
    private typealias Sample = (AppleMusicEndDetector.Status, TimeInterval)

    private let recordedMusicKitRun: [Sample] = [
        (.paused, 0.00),
        (.playing, 0.69),
        (.playing, 1.73),
        (.playing, 2.80),
        (.playing, 24.15),
        (.playing, 24.68),
        (.playing, 25.05)
    ]

    private func feed(_ detector: inout AppleMusicEndDetector, _ samples: [Sample]) -> [Bool] {
        samples.map { detector.observe(status: $0.0, position: $0.1) }
    }

    func testRecordedMusicKitRunIsNotFinishedWhilePlayingAndFinishesOnPausedAtZero() {
        var detector = AppleMusicEndDetector()
        XCTAssertTrue(feed(&detector, recordedMusicKitRun).allSatisfy { !$0 })
        XCTAssertTrue(detector.observe(status: .paused, position: 0.00))
        XCTAssertTrue(detector.observe(status: .paused, position: 0.00))
    }

    func testPausedAtZeroBeforeAnythingHasPlayedIsNotAnEnd() {
        var detector = AppleMusicEndDetector()
        XCTAssertFalse(detector.observe(status: .paused, position: 0.00))
        XCTAssertFalse(detector.observe(status: .paused, position: 0.00))
    }

    func testManualPauseAtANonZeroPositionIsNotAnEnd() {
        var detector = AppleMusicEndDetector()
        _ = feed(&detector, recordedMusicKitRun.prefix(4).map { $0 })
        detector.isPausedByUser = true
        for _ in 0..<5 {
            XCTAssertFalse(detector.observe(status: .paused, position: 3.84))
        }
        detector.isPausedByUser = false
        XCTAssertFalse(detector.observe(status: .paused, position: 3.84))
    }

    func testManualPauseAtZeroAfterPlayingIsNotAnEnd() {
        var detector = AppleMusicEndDetector()
        _ = feed(&detector, recordedMusicKitRun.prefix(3).map { $0 })
        detector.isPausedByUser = true
        XCTAssertFalse(detector.observe(status: .paused, position: 0.00))
    }

    func testPauseResumeThenTheEndStillFinishes() {
        var detector = AppleMusicEndDetector()
        _ = feed(&detector, recordedMusicKitRun.prefix(4).map { $0 })
        detector.isPausedByUser = true
        XCTAssertFalse(detector.observe(status: .paused, position: 3.84))
        detector.isPausedByUser = false
        XCTAssertFalse(detector.observe(status: .playing, position: 4.91))
        XCTAssertFalse(detector.observe(status: .playing, position: 25.05))
        XCTAssertTrue(detector.observe(status: .paused, position: 0.00))
    }

    func testStoppedStillCountsAsFinished() {
        var detector = AppleMusicEndDetector()
        XCTAssertTrue(detector.observe(status: .stopped, position: 0))
    }

    func testOtherStatusesNeverFinish() {
        var detector = AppleMusicEndDetector()
        _ = feed(&detector, recordedMusicKitRun)
        XCTAssertFalse(detector.observe(status: .other, position: 0))
    }

    func testResetForgetsThatAnythingWasPlaying() {
        var detector = AppleMusicEndDetector()
        _ = feed(&detector, recordedMusicKitRun)
        detector.reset()
        XCTAssertFalse(detector.observe(status: .paused, position: 0.00))
        XCTAssertFalse(detector.isPausedByUser)
    }

    func testPositionToleranceSeparatesNoiseFromARealPosition() {
        var detector = AppleMusicEndDetector()
        _ = feed(&detector, recordedMusicKitRun)
        XCTAssertTrue(detector.observe(status: .paused, position: 0.02))
        XCTAssertFalse(detector.observe(status: .paused, position: 0.50))
    }
}

@MainActor
private final class DetectorDrivenPlayback: TrackPlayback {
    var onFinish: (() -> Void)?
    var volume: Float = 1
    private(set) var currentTime: TimeInterval = 0
    private var detector = AppleMusicEndDetector()
    private var finished = false

    func load(_ track: UnifiedTrack) async throws {
        stop()
    }

    func play() {
        detector.isPausedByUser = false
    }

    func pause() {
        detector.isPausedByUser = true
    }

    func stop() {
        detector.reset()
        finished = false
        currentTime = 0
    }

    func seek(to time: TimeInterval) {
        currentTime = time
    }

    func tick(_ status: AppleMusicEndDetector.Status, _ position: TimeInterval) {
        currentTime = position
        guard !finished, detector.observe(status: status, position: position) else { return }
        finished = true
        onFinish?()
    }
}

@MainActor
private final class DetectorAdapter: ProviderAdapter {
    let id = ProviderID(rawValue: "musickit_like")
    let displayName = "MusicKit Like"
    var isConnected = true
    var connectionDetail: String? { "test" }
    private(set) var engines: [DetectorDrivenPlayback] = []
    let library = syntheticTracks(ProviderID(rawValue: "musickit_like"), count: 2)

    func connect() async throws {}
    func disconnect() {}
    func tracks() async throws -> [UnifiedTrack] { library }

    func makePlayback() -> any TrackPlayback {
        let engine = DetectorDrivenPlayback()
        engines.append(engine)
        return engine
    }
}

@MainActor
final class AppleMusicEndOfTrackPlayerTests: XCTestCase {
    private func makeRig() -> (Player, UnifiedQueue, DetectorAdapter) {
        let adapter = DetectorAdapter()
        let queue = UnifiedQueue()
        queue.add(contentsOf: adapter.library)
        return (Player(queue: queue, adapters: [adapter.id: adapter]), queue, adapter)
    }

    private func startFirstTrack(_ player: Player, _ adapter: DetectorAdapter) async {
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        adapter.engines[0].tick(.paused, 0.00)
        adapter.engines[0].tick(.playing, 0.69)
        adapter.engines[0].tick(.playing, 1.73)
    }

    func testEndOfTrackAdvancesToTheNextQueuedTrackThenStopsAtTheQueueEnd() async {
        let (player, queue, adapter) = makeRig()
        await startFirstTrack(player, adapter)
        adapter.engines[0].tick(.playing, 24.68)
        adapter.engines[0].tick(.playing, 25.05)
        XCTAssertEqual(queue.currentIndex, 0)
        adapter.engines[0].tick(.paused, 0.00)
        let advanced = await eventually { queue.currentIndex == 1 && player.state == .playing }
        XCTAssertTrue(advanced, "index \(String(describing: queue.currentIndex)), state \(player.state)")

        adapter.engines[0].tick(.paused, 0.00)
        adapter.engines[0].tick(.playing, 0.69)
        adapter.engines[0].tick(.playing, 25.05)
        adapter.engines[0].tick(.paused, 0.00)
        XCTAssertEqual(player.state, .stopped)
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(queue.currentIndex, 1)
    }

    func testManualPauseInTheMiddleNeverAdvancesAndResumeContinues() async {
        let (player, queue, adapter) = makeRig()
        await startFirstTrack(player, adapter)
        adapter.engines[0].tick(.playing, 3.84)
        player.pause()
        XCTAssertEqual(player.state, .paused)
        for _ in 0..<6 {
            adapter.engines[0].tick(.paused, 3.84)
        }
        XCTAssertEqual(queue.currentIndex, 0)
        XCTAssertEqual(player.state, .paused)

        player.play()
        XCTAssertEqual(player.state, .playing)
        adapter.engines[0].tick(.playing, 4.91)
        XCTAssertEqual(queue.currentIndex, 0)
        XCTAssertEqual(player.state, .playing)
    }

    func testPausingAtPositionZeroAfterPlayingDoesNotSkipTheTrack() async {
        let (player, queue, adapter) = makeRig()
        await startFirstTrack(player, adapter)
        player.seek(to: 0)
        player.pause()
        adapter.engines[0].tick(.paused, 0.00)
        adapter.engines[0].tick(.paused, 0.00)
        XCTAssertEqual(queue.currentIndex, 0)
        XCTAssertEqual(player.state, .paused)
    }
}
