import Foundation
import Observation

@MainActor
@Observable
final class UnifiedQueue {
    private(set) var tracks: [UnifiedTrack] = []
    private(set) var currentIndex: Int?

    var currentTrack: UnifiedTrack? {
        guard let currentIndex, tracks.indices.contains(currentIndex) else { return nil }
        return tracks[currentIndex]
    }

    func add(_ track: UnifiedTrack) {
        tracks.append(track)
    }

    func add(contentsOf newTracks: [UnifiedTrack]) {
        tracks.append(contentsOf: newTracks)
    }

    func insertNext(_ newTracks: [UnifiedTrack]) {
        guard !newTracks.isEmpty else { return }
        let position = min((currentIndex ?? -1) + 1, tracks.count)
        tracks.insert(contentsOf: newTracks, at: position)
    }

    func remove(at index: Int) {
        guard tracks.indices.contains(index) else { return }
        tracks.remove(at: index)
        guard let current = currentIndex else { return }
        if index < current {
            currentIndex = current - 1
        } else if index == current {
            currentIndex = nil
        }
    }

    func remove(_ track: UnifiedTrack) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        remove(at: index)
    }

    func move(from source: Int, to destination: Int) {
        guard tracks.indices.contains(source), tracks.indices.contains(destination), source != destination else { return }
        let track = tracks.remove(at: source)
        tracks.insert(track, at: destination)
        guard let current = currentIndex else { return }
        if current == source {
            currentIndex = destination
        } else if source < current && destination >= current {
            currentIndex = current - 1
        } else if source > current && destination <= current {
            currentIndex = current + 1
        }
    }

    func select(at index: Int) {
        guard tracks.indices.contains(index) else { return }
        currentIndex = index
    }

    @discardableResult
    func next() -> UnifiedTrack? {
        guard !tracks.isEmpty else { return nil }
        guard let current = currentIndex else {
            currentIndex = 0
            return tracks[0]
        }
        guard current + 1 < tracks.count else { return nil }
        currentIndex = current + 1
        return tracks[current + 1]
    }

    @discardableResult
    func previous() -> UnifiedTrack? {
        guard let current = currentIndex, current > 0 else { return nil }
        currentIndex = current - 1
        return tracks[current - 1]
    }

    func shuffle() {
        let start = (currentIndex ?? -1) + 1
        guard start < tracks.count else { return }
        tracks.replaceSubrange(start..., with: tracks[start...].shuffled())
    }

    func clear() {
        tracks.removeAll()
        currentIndex = nil
    }
}
