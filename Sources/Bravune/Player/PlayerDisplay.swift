import Foundation

extension Player {
    var displayTitle: String {
        currentTrack?.title ?? "Not Playing"
    }

    var visibleNotice: String? {
        guard let notice else { return nil }
        switch state {
        case .playing, .paused: return notice
        default: return nil
        }
    }

    func displaySubtitle(includeAlbum: Bool) -> String {
        if let visibleNotice { return visibleNotice }
        switch state {
        case .loading:
            return "Loading"
        case .failed(let message):
            return message
        default:
            guard let track = currentTrack else { return "" }
            return includeAlbum ? "\(track.artist) — \(track.album)" : track.artist
        }
    }
}

extension Player {
    static let volumeStep: Float = 0.1

    func changeVolume(by delta: Float) {
        volume = min(max(volume + delta, 0), 1)
    }
}
