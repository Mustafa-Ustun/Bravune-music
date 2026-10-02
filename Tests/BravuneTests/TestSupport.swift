import Foundation
import XCTest
@testable import Bravune

@MainActor
func eventually(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

func syntheticTracks(_ provider: ProviderID, count: Int, duration: TimeInterval = 240, artistPrefix: String? = nil) -> [UnifiedTrack] {
    (0..<count).map { index in
        UnifiedTrack(
            provider: provider,
            providerTrackId: "\(index)",
            title: "\(provider.rawValue) song \(index)",
            artist: "\(artistPrefix ?? provider.rawValue) artist \(index)",
            album: "Album",
            duration: duration
        )
    }
}

struct FakeFailure: LocalizedError {
    var errorDescription: String? { "fake failure" }
}

@MainActor
final class FakeAdapter: ProviderAdapter {
    let id: ProviderID
    let displayName: String
    var isConnected: Bool
    var connectionDetail: String? { isConnected ? "fake" : nil }
    var library: [UnifiedTrack]
    var failsLibrary = false
    var failsLoads = false
    var connectError: Error?
    var connectDelay: UInt64 = 0
    var cancelsConnect = false
    var unplayable: Set<String> = []
    var loadDelays: [String: UInt64] = [:]
    private(set) var connectCalls = 0
    private(set) var disconnectCalls = 0
    private(set) var loaded: [String] = []
    private(set) var playCalls = 0
    private(set) var stopCalls = 0
    private(set) var playbacks: [FakePlayback] = []

    init(id: String, tracks: [UnifiedTrack]? = nil, count: Int = 5, connected: Bool = true) {
        let providerID = ProviderID(rawValue: id)
        self.id = providerID
        self.displayName = id.capitalized
        self.isConnected = connected
        self.library = tracks ?? syntheticTracks(providerID, count: count)
    }

    func connect() async throws {
        connectCalls += 1
        if connectDelay > 0 {
            try await Task.sleep(nanoseconds: connectDelay)
        }
        if let connectError { throw connectError }
        if cancelsConnect { return }
        isConnected = true
    }

    func disconnect() {
        disconnectCalls += 1
        isConnected = false
    }

    func tracks() async throws -> [UnifiedTrack] {
        if failsLibrary { throw FakeFailure() }
        return isConnected ? library : []
    }

    func makePlayback() -> any TrackPlayback {
        let playback = FakePlayback(owner: self)
        playbacks.append(playback)
        return playback
    }

    fileprivate func recordLoad(_ id: String) { loaded.append(id) }
    fileprivate func recordPlay() { playCalls += 1 }
    fileprivate func recordStop() { stopCalls += 1 }
}

@MainActor
final class FakePlayback: TrackPlayback {
    private unowned let owner: FakeAdapter
    var onFinish: (() -> Void)?
    var volume: Float = 1
    var currentTime: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var lastSeek: TimeInterval?

    init(owner: FakeAdapter) {
        self.owner = owner
    }

    func load(_ track: UnifiedTrack) async throws {
        owner.recordLoad(track.id)
        if let delay = owner.loadDelays[track.providerTrackId] {
            try await Task.sleep(nanoseconds: delay)
        }
        if owner.unplayable.contains(track.providerTrackId) { throw TrackUnplayableError(title: track.title) }
        if owner.failsLoads { throw FakeFailure() }
    }

    func play() {
        isPlaying = true
        owner.recordPlay()
    }

    func pause() {
        isPlaying = false
    }

    func stop() {
        isPlaying = false
        owner.recordStop()
    }

    func seek(to time: TimeInterval) {
        lastSeek = time
        currentTime = time
    }

    func finish() {
        onFinish?()
    }
}

final class ScriptedTransport: AITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    let response: Data

    init(response: Data) {
        self.response = response
    }

    var callCount: Int {
        lock.withLock { bodies.count }
    }

    var lastBody: Data? {
        lock.withLock { bodies.last }
    }

    func send(_ body: Data) async throws -> Data {
        lock.withLock { bodies.append(body) }
        return response
    }

    static func reply(plan: [String: Any], stopReason: String = "end_turn") -> Data {
        let planText = String(data: try! JSONSerialization.data(withJSONObject: plan), encoding: .utf8)!
        let object: [String: Any] = [
            "type": "message",
            "stop_reason": stopReason,
            "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": planText]]
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func plan(
        providers: [String],
        trackCount: Int = 0,
        durationMinutes: Int = 0,
        distribution: [String: Int] = [:],
        avoidDuplicateArtists: Bool = false,
        randomize: Bool = true,
        unsupported: [String] = []
    ) -> [String: Any] {
        [
            "providers": providers,
            "trackCount": trackCount,
            "durationMinutes": durationMinutes,
            "distribution": distribution.sorted { $0.key < $1.key }.map { ["provider": $0.key, "count": $0.value] },
            "avoidDuplicateArtists": avoidDuplicateArtists,
            "randomize": randomize,
            "unsupported": unsupported
        ]
    }
}
