import Foundation

@MainActor
protocol TrackPlayback: AnyObject {
    var currentTime: TimeInterval { get }
    var volume: Float { get set }
    var onFinish: (() -> Void)? { get set }

    func load(_ track: UnifiedTrack) async throws
    func play()
    func pause()
    func stop()
    func seek(to time: TimeInterval)
}

struct TrackUnplayableError: LocalizedError {
    let title: String

    var errorDescription: String? {
        "Couldn\u{2019}t play \u{201C}\(title)\u{201D}"
    }
}
