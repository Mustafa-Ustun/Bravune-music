import AVFoundation
import Foundation

@MainActor
final class LocalMusicPlayback: NSObject, TrackPlayback, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?

    var onFinish: (() -> Void)?

    var volume: Float = 1 {
        didSet { player?.volume = volume }
    }

    var currentTime: TimeInterval {
        player?.currentTime ?? 0
    }

    func load(_ track: UnifiedTrack) async throws {
        player?.stop()
        let url = URL(fileURLWithPath: track.providerTrackId)
        let next: AVAudioPlayer
        do {
            next = try AVAudioPlayer(contentsOf: url)
        } catch {
            throw TrackUnplayableError(title: track.title)
        }
        next.delegate = self
        next.volume = volume
        next.prepareToPlay()
        player = next
    }

    func play() {
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func stop() {
        player?.stop()
        player = nil
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        if time >= player.duration {
            player.stop()
            Task { @MainActor [weak self] in
                self?.onFinish?()
            }
            return
        }
        player.currentTime = max(time, 0)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard flag else { return }
        Task { @MainActor [weak self] in
            self?.onFinish?()
        }
    }
}
