import Foundation

@MainActor
final class SpotifyPlayback: TrackPlayback {
    private let apiProvider: @MainActor () throws -> SpotifyAPI
    private var api: SpotifyAPI?
    private var deviceID: String?
    private var trackID: String?
    private var trackDuration: TimeInterval = 0
    private var playing = false
    private var basePosition: TimeInterval = 0
    private var baseDate = Date()
    private var startedAt = Date.distantPast
    private var pollTask: Task<Void, Never>?
    private var pendingPause: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?

    var onFinish: (() -> Void)?

    var volume: Float = 1 {
        didSet { scheduleVolume() }
    }

    var currentTime: TimeInterval {
        playing ? basePosition + Date().timeIntervalSince(baseDate) : basePosition
    }

    init(apiProvider: @escaping @MainActor () throws -> SpotifyAPI) {
        self.apiProvider = apiProvider
    }

    func load(_ track: UnifiedTrack) async throws {
        reset()
        await pendingPause?.value
        let api = try apiProvider()
        let device = try await api.pickDevice()
        try await api.play(uri: "spotify:track:\(track.providerTrackId)", deviceID: device)
        self.api = api
        deviceID = device
        trackID = track.providerTrackId
        trackDuration = track.duration
        basePosition = 0
        baseDate = Date()
        startedAt = Date()
        playing = true
        startPolling()
    }

    func play() {
        guard trackID != nil, !playing, let api, let deviceID else { return }
        baseDate = Date()
        playing = true
        Task { try? await api.resume(deviceID: deviceID) }
    }

    func pause() {
        guard playing, let api, let deviceID else { return }
        basePosition = currentTime
        playing = false
        Task { try? await api.pause(deviceID: deviceID) }
    }

    func stop() {
        let wasActive = trackID != nil
        reset()
        guard wasActive, let api, let deviceID else { return }
        pendingPause = Task { try? await api.pause(deviceID: deviceID) }
    }

    func seek(to time: TimeInterval) {
        guard trackID != nil, let api, let deviceID else { return }
        basePosition = max(time, 0)
        baseDate = Date()
        seekTask?.cancel()
        let target = Int(basePosition * 1000)
        seekTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            try? await api.seek(to: target, deviceID: deviceID)
        }
    }

    private func reset() {
        pollTask?.cancel()
        seekTask?.cancel()
        volumeTask?.cancel()
        trackID = nil
        playing = false
        basePosition = 0
    }

    private func scheduleVolume() {
        guard trackID != nil, let api, let deviceID else { return }
        volumeTask?.cancel()
        let percent = Int((volume * 100).rounded())
        volumeTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            try? await api.setVolume(percent: percent, deviceID: deviceID)
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.poll()
            }
        }
    }

    private func poll() async {
        guard playing, let api, let expected = trackID, Date().timeIntervalSince(startedAt) > 3 else { return }
        guard let state = try? await api.playerState() else {
            if trackID == expected { finish() }
            return
        }
        guard trackID == expected, playing else { return }
        let progress = TimeInterval(state.progress_ms ?? 0) / 1000
        if state.item?.id != expected {
            finish()
        } else if !state.is_playing && (progress < 1 || progress >= trackDuration - 1.5) {
            finish()
        } else if state.is_playing {
            basePosition = progress
            baseDate = Date()
        }
    }

    private func finish() {
        pollTask?.cancel()
        playing = false
        onFinish?()
    }
}
