import AVFoundation
import Foundation

@MainActor
final class SubsonicPlayback: TrackPlayback {
    private let streamURL: @MainActor (String) throws -> URL
    private let player = AVPlayer()
    private var finishObserver: NSObjectProtocol?

    var onFinish: (() -> Void)?

    var volume: Float = 1 {
        didSet { player.volume = volume }
    }

    var currentTime: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    init(streamURL: @escaping @MainActor (String) throws -> URL) {
        self.streamURL = streamURL
        player.volume = volume
    }

    func load(_ track: UnifiedTrack) async throws {
        stop()
        let asset = AVURLAsset(url: try streamURL(track.providerTrackId))
        guard try await asset.load(.isPlayable) else {
            throw TrackUnplayableError(title: track.title)
        }
        let item = AVPlayerItem(asset: asset)
        finishObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onFinish?()
            }
        }
        player.replaceCurrentItem(with: item)
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let finishObserver {
            NotificationCenter.default.removeObserver(finishObserver)
            self.finishObserver = nil
        }
    }

    func seek(to time: TimeInterval) {
        player.seek(to: CMTime(seconds: max(time, 0), preferredTimescale: 600))
    }
}
