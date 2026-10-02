import XCTest
@testable import Bravune

@MainActor
final class PlayNextTests: XCTestCase {
    private func ids(_ queue: UnifiedQueue) -> [String] {
        queue.tracks.map(\.providerTrackId)
    }

    private func makeQueue(count: Int, current: Int?) -> (UnifiedQueue, [UnifiedTrack]) {
        let tracks = syntheticTracks(ProviderID(rawValue: "fake"), count: count + 3)
        let queue = UnifiedQueue()
        queue.add(contentsOf: Array(tracks[0..<count]))
        if let current { queue.select(at: current) }
        return (queue, Array(tracks[count...]))
    }

    func testInsertsRightAfterTheCurrentTrack() {
        let (queue, extra) = makeQueue(count: 4, current: 1)
        queue.insertNext([extra[0], extra[1]])
        XCTAssertEqual(queue.tracks.count, 6)
        XCTAssertEqual(queue.tracks[2].id, extra[0].id)
        XCTAssertEqual(queue.tracks[3].id, extra[1].id)
        XCTAssertEqual(queue.currentIndex, 1)
    }

    func testInsertsAtTheFrontWhenNothingIsCurrent() {
        let (queue, extra) = makeQueue(count: 3, current: nil)
        queue.insertNext([extra[0]])
        XCTAssertEqual(queue.tracks[0].id, extra[0].id)
        XCTAssertNil(queue.currentIndex)
    }

    func testInsertsAtTheEndWhenCurrentIsLast() {
        let (queue, extra) = makeQueue(count: 3, current: 2)
        queue.insertNext([extra[0]])
        XCTAssertEqual(queue.tracks.last?.id, extra[0].id)
        XCTAssertEqual(queue.currentIndex, 2)
    }

    func testInsertingIntoAnEmptyQueueWorks() {
        let (queue, extra) = makeQueue(count: 0, current: nil)
        queue.insertNext([extra[0], extra[1]])
        XCTAssertEqual(queue.tracks.map(\.id), [extra[0].id, extra[1].id])
    }

    func testInsertingNothingChangesNothing() {
        let (queue, _) = makeQueue(count: 3, current: 1)
        let before = queue.tracks
        queue.insertNext([])
        XCTAssertEqual(queue.tracks, before)
    }

    func testPlayNextTrackIsWhatNextPlays() async {
        let adapter = FakeAdapter(id: "fake", count: 4)
        let queue = UnifiedQueue()
        queue.add(contentsOf: adapter.library)
        let player = Player(queue: queue, adapters: [adapter.id: adapter])
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        let extra = syntheticTracks(ProviderID(rawValue: "fake"), count: 1)[0]
        queue.insertNext([extra])
        XCTAssertEqual(queue.tracks[1].id, extra.id)
        XCTAssertEqual(queue.currentIndex, 0)
    }
}
