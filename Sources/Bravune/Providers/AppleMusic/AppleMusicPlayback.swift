import Foundation
import MusicKit

@MainActor
final class AppleMusicPlayback: TrackPlayback {
    private let lookup: @MainActor (String) -> Song?
    private let player = ApplicationMusicPlayer.shared
    private var monitor: Timer?
    private var started = false
    private var endDetector = AppleMusicEndDetector()

    var onFinish: (() -> Void)?
    var volume: Float = 1

    var currentTime: TimeInterval {
        player.playbackTime
    }

    init(lookup: @escaping @MainActor (String) -> Song?) {
        self.lookup = lookup
    }

    func load(_ track: UnifiedTrack) async throws {
        stop()
        guard let song = lookup(track.providerTrackId) else {
            throw AppleMusicError.trackUnavailable
        }
        player.queue = [song]
        try await player.prepareToPlay()
    }

    func play() {
        endDetector.isPausedByUser = false
        Task {
            try? await player.play()
            started = true
            startMonitor()
        }
    }

    func pause() {
        endDetector.isPausedByUser = true
        player.pause()
    }

    func stop() {
        started = false
        endDetector.reset()
        stopMonitor()
        player.stop()
    }

    func seek(to time: TimeInterval) {
        player.playbackTime = max(time, 0)
    }

    private func startMonitor() {
        stopMonitor()
        monitor = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.started else { return }
                let status = Self.status(of: self.player.state.playbackStatus)
                guard self.endDetector.observe(status: status, position: self.player.playbackTime) else { return }
                self.started = false
                self.stopMonitor()
                self.onFinish?()
            }
        }
    }

    private static func status(of status: MusicPlayer.PlaybackStatus) -> AppleMusicEndDetector.Status {
        switch status {
        case .playing: .playing
        case .paused: .paused
        case .stopped: .stopped
        default: .other
        }
    }

    private func stopMonitor() {
        monitor?.invalidate()
        monitor = nil
    }
}
