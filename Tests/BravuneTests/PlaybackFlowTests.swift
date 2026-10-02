import AVFoundation
import XCTest
@testable import Bravune

@MainActor
final class PlaybackFlowTests: XCTestCase {
    private var folder: URL!
    private var previousFolder: String?

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeTone(named: "First Song.wav", seconds: 1.5, frequency: 440)
        try writeTone(named: "Second Song.wav", seconds: 1.5, frequency: 660)
        try Data("x".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        previousFolder = UserDefaults.standard.string(forKey: LocalMusicAdapter.folderDefaultsKey)
        UserDefaults.standard.set(folder.path, forKey: LocalMusicAdapter.folderDefaultsKey)
    }

    override func tearDown() async throws {
        if let previousFolder {
            UserDefaults.standard.set(previousFolder, forKey: LocalMusicAdapter.folderDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LocalMusicAdapter.folderDefaultsKey)
        }
        try? FileManager.default.removeItem(at: folder)
    }

    private func writeTone(named name: String, seconds: Double, frequency: Double) throws {
        let rate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = Float(sin(2 * Double.pi * frequency * Double(index) / rate)) * 0.2
        }
        let file = try AVAudioFile(forWriting: folder.appendingPathComponent(name), settings: format.settings)
        try file.write(from: buffer)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    func testLocalScanProducesUnifiedTracks() async throws {
        let adapter = LocalMusicAdapter()
        XCTAssertTrue(adapter.isConnected)
        let tracks = try await adapter.tracks()
        XCTAssertEqual(tracks.map(\.title), ["First Song", "Second Song"])
        XCTAssertTrue(tracks.allSatisfy { $0.provider == .localMusic })
        XCTAssertTrue(tracks.allSatisfy { abs($0.duration - 1.5) < 0.1 })
        XCTAssertTrue(tracks.allSatisfy { FileManager.default.fileExists(atPath: $0.providerTrackId) })
    }

    func testProviderToQueueToPlayer() async throws {
        let adapter = LocalMusicAdapter()
        let tracks = try await adapter.tracks()
        let queue = UnifiedQueue()
        queue.add(contentsOf: tracks)
        let player = Player(queue: queue, adapters: [adapter.id: adapter])
        player.volume = 0

        player.play(at: 0)
        var ready = await waitUntil { player.state == .playing }
        XCTAssertTrue(ready, "state was \(player.state)")
        XCTAssertEqual(player.currentTrack?.title, "First Song")

        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertGreaterThan(player.position, 0.3)

        player.pause()
        XCTAssertEqual(player.state, .paused)
        let frozen = player.position
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(player.position, frozen, accuracy: 0.01)

        player.play()
        XCTAssertEqual(player.state, .playing)

        player.seek(to: 1.0)
        XCTAssertEqual(player.position, 1.0, accuracy: 0.01)

        ready = await waitUntil { player.currentTrack?.title == "Second Song" && player.state == .playing }
        XCTAssertTrue(ready, "did not advance, state \(player.state), track \(String(describing: player.currentTrack?.title))")

        player.previous()
        ready = await waitUntil { player.currentTrack?.title == "First Song" && player.state == .playing }
        XCTAssertTrue(ready)

        player.next()
        _ = await waitUntil { player.currentTrack?.title == "Second Song" && player.state == .playing }
        player.seek(to: 1.0)
        let ended = await waitUntil { player.state == .stopped }
        XCTAssertTrue(ended, "state was \(player.state)")
        XCTAssertEqual(player.position, 0)
    }

    func testAdapterWithoutFolderIsDisconnected() async throws {
        UserDefaults.standard.removeObject(forKey: LocalMusicAdapter.folderDefaultsKey)
        let adapter = LocalMusicAdapter()
        XCTAssertFalse(adapter.isConnected)
        let tracks = try await adapter.tracks()
        XCTAssertTrue(tracks.isEmpty)
    }

    func testCorruptFileIsSkippedByTheRealLocalPlayer() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeToneFile(at: dir.appendingPathComponent("1 first.wav"), seconds: 1, frequency: 440)
        try Data((0..<2000).map { UInt8(($0 * 37 + 11) % 251) }).write(to: dir.appendingPathComponent("2 broken.mp3"))
        try makeToneFile(at: dir.appendingPathComponent("3 last.wav"), seconds: 1, frequency: 660)

        let adapter = LocalMusicAdapter(folderURL: dir, artworkDirectory: dir.appendingPathComponent("art"))
        let tracks = try await adapter.tracks()
        XCTAssertEqual(tracks.map(\.title), ["1 first", "2 broken", "3 last"])
        let queue = UnifiedQueue()
        queue.add(contentsOf: tracks)
        let player = Player(queue: queue, adapters: [adapter.id: adapter])
        player.volume = 0

        player.play(at: 0)
        var ready = await waitUntil { player.state == .playing && queue.currentIndex == 0 }
        XCTAssertTrue(ready)
        ready = await waitUntil(timeout: 8) { queue.currentIndex == 2 && player.state == .playing }
        XCTAssertTrue(ready, "index \(String(describing: queue.currentIndex)), state \(player.state)")
        let ended = await waitUntil(timeout: 8) { player.state == .stopped }
        XCTAssertTrue(ended, "state was \(player.state)")
        XCTAssertEqual(queue.currentIndex, 2)
    }
}
