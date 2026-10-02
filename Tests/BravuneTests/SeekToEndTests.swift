import AVFoundation
import XCTest
@testable import Bravune

@MainActor
final class SeekToEndTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeTone(named: "a.wav")
        try writeTone(named: "b.wav")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func writeTone(named name: String) throws {
        let rate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let frames = AVAudioFrameCount(10 * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = Float(sin(2 * Double.pi * 440 * Double(index) / rate)) * 0.2
        }
        let file = try AVAudioFile(forWriting: folder.appendingPathComponent(name), settings: format.settings)
        try file.write(from: buffer)
    }

    private func track(_ name: String) -> UnifiedTrack {
        UnifiedTrack(
            provider: .localMusic,
            providerTrackId: folder.appendingPathComponent(name).path,
            title: name,
            artist: "x",
            album: "y",
            duration: 10,
            artwork: nil
        )
    }

    func testSeekingToTheEndFinishesTheTrackInsteadOfWrappingToTheStart() async throws {
        let playback = LocalMusicPlayback()
        var finished = 0
        playback.onFinish = { finished += 1 }
        try await playback.load(track("a.wav"))
        playback.volume = 0
        playback.play()
        playback.seek(to: 10)
        let done = await eventually { finished == 1 }
        XCTAssertTrue(done)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(finished, 1)
        XCTAssertLessThan(playback.currentTime, 1)
    }

    func testSeekingPastTheEndFinishesTheTrack() async throws {
        let playback = LocalMusicPlayback()
        var finished = 0
        playback.onFinish = { finished += 1 }
        try await playback.load(track("a.wav"))
        playback.volume = 0
        playback.play()
        playback.seek(to: 999)
        let done = await eventually { finished == 1 }
        XCTAssertTrue(done)
    }

    func testSeekingInsideTheTrackDoesNotFinishIt() async throws {
        let playback = LocalMusicPlayback()
        var finished = 0
        playback.onFinish = { finished += 1 }
        try await playback.load(track("a.wav"))
        playback.volume = 0
        playback.play()
        playback.seek(to: 5)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(finished, 0)
        XCTAssertGreaterThanOrEqual(playback.currentTime, 5)
    }

    func testPlayerStopsWhenSeekedToTheEndOfTheLastTrack() async {
        let adapter = LocalMusicAdapter(folderURL: folder, artworkDirectory: folder.appendingPathComponent("art"))
        let queue = UnifiedQueue()
        queue.add(track("a.wav"))
        let player = Player(queue: queue, adapters: [adapter.id: adapter])
        player.volume = 0
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        player.seek(to: 10)
        let stopped = await eventually { player.state == .stopped }
        XCTAssertTrue(stopped, "state was \(player.state)")
        XCTAssertEqual(player.position, 0)
    }

    func testPlayerAdvancesWhenSeekedToTheEndOfANonLastTrack() async {
        let adapter = LocalMusicAdapter(folderURL: folder, artworkDirectory: folder.appendingPathComponent("art"))
        let queue = UnifiedQueue()
        queue.add(track("a.wav"))
        queue.add(track("b.wav"))
        let player = Player(queue: queue, adapters: [adapter.id: adapter])
        player.volume = 0
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        player.seek(to: 10)
        let advanced = await eventually { queue.currentIndex == 1 && player.state == .playing }
        XCTAssertTrue(advanced, "state was \(player.state)")
    }
}
