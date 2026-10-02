import XCTest
@testable import Bravune

@MainActor
final class UnifiedQueueTests: XCTestCase {
    private func track(_ id: String, provider: ProviderID = .localMusic) -> UnifiedTrack {
        UnifiedTrack(provider: provider, providerTrackId: id, title: id, artist: "A", album: "B", duration: 10)
    }

    private func filled(_ count: Int) -> UnifiedQueue {
        let queue = UnifiedQueue()
        queue.add(contentsOf: (0..<count).map { track("\($0)") })
        return queue
    }

    func testTrackPreservesProviderIdentity() {
        let item = track("abc", provider: ProviderID(rawValue: "spotify"))
        XCTAssertEqual(item.providerTrackId, "abc")
        XCTAssertEqual(item.id, "spotify:abc")
    }

    func testNextAndPrevious() {
        let queue = filled(3)
        XCTAssertEqual(queue.next()?.providerTrackId, "0")
        XCTAssertEqual(queue.next()?.providerTrackId, "1")
        XCTAssertEqual(queue.previous()?.providerTrackId, "0")
        XCTAssertNil(queue.previous())
        queue.select(at: 2)
        XCTAssertNil(queue.next())
        XCTAssertEqual(queue.currentIndex, 2)
    }

    func testMixedProviders() {
        let queue = UnifiedQueue()
        queue.add(track("1", provider: ProviderID(rawValue: "spotify")))
        queue.add(track("2"))
        XCTAssertEqual(queue.tracks.map(\.provider.rawValue), ["spotify", "local_music"])
    }

    func testRemoveAdjustsCurrentIndex() {
        let queue = filled(4)
        queue.select(at: 2)
        queue.remove(at: 0)
        XCTAssertEqual(queue.currentTrack?.providerTrackId, "2")
        queue.remove(at: 2)
        XCTAssertEqual(queue.currentTrack?.providerTrackId, "2")
        queue.remove(at: 1)
        XCTAssertNil(queue.currentIndex)
    }

    func testMoveKeepsCurrentTrack() {
        let queue = filled(5)
        queue.select(at: 2)
        queue.move(from: 0, to: 4)
        XCTAssertEqual(queue.currentTrack?.providerTrackId, "2")
        queue.move(from: 4, to: 0)
        XCTAssertEqual(queue.currentTrack?.providerTrackId, "2")
        queue.move(from: 2, to: 0)
        XCTAssertEqual(queue.currentTrack?.providerTrackId, "2")
        XCTAssertEqual(queue.currentIndex, 0)
    }

    func testShuffleKeepsPlayedAndCurrentInPlace() {
        let queue = filled(20)
        queue.select(at: 3)
        let before = queue.tracks
        queue.shuffle()
        XCTAssertEqual(Array(queue.tracks[0...3]), Array(before[0...3]))
        XCTAssertEqual(Set(queue.tracks.map(\.id)), Set(before.map(\.id)))
        XCTAssertEqual(queue.currentTrack?.providerTrackId, "3")
    }

    func testClear() {
        let queue = filled(3)
        queue.select(at: 1)
        queue.clear()
        XCTAssertTrue(queue.tracks.isEmpty)
        XCTAssertNil(queue.currentIndex)
    }
}
