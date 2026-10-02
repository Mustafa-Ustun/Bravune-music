import Foundation

struct AppleMusicEndDetector {
    enum Status: Equatable {
        case playing
        case paused
        case stopped
        case other
    }

    static let positionTolerance: TimeInterval = 0.05

    var isPausedByUser = false
    private var hasBeenPlaying = false

    mutating func reset() {
        hasBeenPlaying = false
        isPausedByUser = false
    }

    mutating func observe(status: Status, position: TimeInterval) -> Bool {
        switch status {
        case .playing:
            hasBeenPlaying = true
            return false
        case .paused:
            return hasBeenPlaying && !isPausedByUser && position < Self.positionTolerance
        case .stopped:
            return true
        case .other:
            return false
        }
    }
}
