import Foundation
import Observation

@MainActor
@Observable
final class Player {
    enum State: Equatable {
        case stopped
        case loading
        case playing
        case paused
        case failed(String)
    }

    let queue: UnifiedQueue

    private(set) var state: State = .stopped
    private(set) var position: TimeInterval = 0
    private(set) var notice: String?

    var noticeDuration: TimeInterval = 6

    var volume: Float = 1 {
        didSet {
            for engine in engines.values {
                engine.volume = volume
            }
        }
    }

    var currentTrack: UnifiedTrack? {
        queue.currentTrack
    }

    var isPlaying: Bool {
        state == .playing
    }

    @ObservationIgnored private let adapters: [ProviderID: any ProviderAdapter]
    @ObservationIgnored private var engines: [ProviderID: any TrackPlayback] = [:]
    @ObservationIgnored private var active: (any TrackPlayback)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var loadToken = 0
    @ObservationIgnored private var skippedTitles: [String] = []
    @ObservationIgnored private var noticeToken = 0

    init(queue: UnifiedQueue, adapters: [ProviderID: any ProviderAdapter]) {
        self.queue = queue
        self.adapters = adapters
    }

    func play() {
        if state == .paused, let active {
            active.play()
            state = .playing
            startTimer()
            return
        }
        if queue.currentTrack == nil {
            guard queue.next() != nil else { return }
        }
        startCurrent()
    }

    func play(at index: Int) {
        queue.select(at: index)
        startCurrent()
    }

    func pause() {
        guard state == .playing else { return }
        active?.pause()
        stopTimer()
        state = .paused
    }

    func togglePlayPause() {
        if state == .playing {
            pause()
        } else {
            play()
        }
    }

    func stop() {
        skippedTitles.removeAll()
        clearNotice()
        loadToken += 1
        active?.stop()
        active = nil
        stopTimer()
        position = 0
        state = .stopped
    }

    func next() {
        if queue.next() != nil {
            startCurrent()
        } else {
            stop()
        }
    }

    func previous() {
        if position > 3 || queue.currentIndex == 0 {
            seek(to: 0)
        } else if queue.previous() != nil {
            startCurrent(direction: .backward)
        }
    }

    func seek(to time: TimeInterval) {
        let target = max(time, 0)
        active?.seek(to: target)
        position = target
    }

    private enum Direction {
        case forward
        case backward
    }

    private func startCurrent(direction: Direction = .forward, continuingSkip: Bool = false) {
        if !continuingSkip {
            skippedTitles.removeAll()
            clearNotice()
        }
        guard let track = queue.currentTrack else {
            stop()
            return
        }
        guard let adapter = adapters[track.provider] else {
            stop()
            state = .failed("\(track.provider.rawValue) is unavailable")
            return
        }
        loadToken += 1
        let token = loadToken
        active?.stop()
        stopTimer()
        position = 0
        state = .loading
        let engine = engine(for: adapter)
        active = engine
        Task {
            do {
                try await engine.load(track)
                guard token == loadToken else { return }
                engine.play()
                state = .playing
                startTimer()
                announceSkippedTracks()
            } catch {
                guard token == loadToken else { return }
                if error is TrackUnplayableError, skipUnplayable(track, direction: direction) {
                    return
                }
                skippedTitles.removeAll()
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func skipUnplayable(_ track: UnifiedTrack, direction: Direction) -> Bool {
        let step = direction == .forward ? queue.next() : queue.previous()
        guard step != nil else { return false }
        skippedTitles.append(track.title)
        startCurrent(direction: direction, continuingSkip: true)
        return true
    }

    private func announceSkippedTracks() {
        guard !skippedTitles.isEmpty else { return }
        notice = skippedTitles.count == 1
            ? "Skipped \u{201C}\(skippedTitles[0])\u{201D} (can\u{2019}t be played)"
            : "Skipped \(skippedTitles.count) tracks that can\u{2019}t be played"
        skippedTitles.removeAll()
        noticeToken += 1
        let token = noticeToken
        let duration = noticeDuration
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(duration, 0) * 1_000_000_000))
            if noticeToken == token {
                notice = nil
            }
        }
    }

    private func clearNotice() {
        notice = nil
        noticeToken += 1
    }

    private func engine(for adapter: any ProviderAdapter) -> any TrackPlayback {
        if let existing = engines[adapter.id] {
            return existing
        }
        let created = adapter.makePlayback()
        created.volume = volume
        created.onFinish = { [weak self] in
            self?.trackFinished()
        }
        engines[adapter.id] = created
        return created
    }

    private func trackFinished() {
        next()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .playing, let active = self.active else { return }
                self.position = active.currentTime
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
