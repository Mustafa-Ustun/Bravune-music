import Foundation
import Observation

enum AIKey {
    static let account = "anthropic.apiKey"
}

@MainActor
@Observable
final class AppState {
    let queue: UnifiedQueue
    let player: Player
    let access: ProviderAccess
    let subscription: Subscription
    let savedMixes: SavedMixStore
    let adapterList: [any ProviderAdapter]

    private(set) var library: [UnifiedTrack] = []
    private(set) var isRefreshing = false
    var section: SidebarSection? = .library
    private(set) var errorMessage: String?
    private(set) var connectionErrors: [ProviderID: String] = [:]
    private(set) var connectingProviders: Set<ProviderID> = []
    private(set) var hasAIKey = Keychain.get(account: AIKey.account) != nil

    var visibleAdapters: [any ProviderAdapter] {
        adapterList.filter { access.isEnabled($0.id) }
    }

    var connectedAdapters: [any ProviderAdapter] {
        visibleAdapters.filter { $0.isConnected }
    }

    convenience init() {
        self.init(adapters: [LocalMusicAdapter(), SpotifyAdapter(), SubsonicAdapter(), JellyfinAdapter(), AppleMusicAdapter()])
    }

    init(
        adapters: [any ProviderAdapter],
        access: ProviderAccess? = nil,
        subscription: Subscription? = nil,
        savedMixes: SavedMixStore? = nil,
        refreshesOnLaunch: Bool = true
    ) {
        let queue = UnifiedQueue()
        self.adapterList = adapters
        self.queue = queue
        self.access = access ?? ProviderAccess()
        self.subscription = subscription ?? Subscription()
        self.savedMixes = savedMixes ?? SavedMixStore()
        self.player = Player(queue: queue, adapters: Dictionary(adapters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
        if refreshesOnLaunch {
            Task { await enforceAccess() }
        }
    }

    func refreshLibrary() async {
        isRefreshing = true
        errorMessage = nil
        var result: [UnifiedTrack] = []
        for adapter in connectedAdapters {
            do {
                result += try await adapter.tracks()
            } catch {
                errorMessage = "\(adapter.displayName): \(error.localizedDescription)"
            }
        }
        library = result
        isRefreshing = false
    }

    func connect(_ adapter: any ProviderAdapter) async {
        guard access.isEnabled(adapter.id), !connectingProviders.contains(adapter.id) else { return }
        connectionErrors[adapter.id] = nil
        connectingProviders.insert(adapter.id)
        do {
            try await adapter.connect()
        } catch {
            connectionErrors[adapter.id] = error.localizedDescription
        }
        connectingProviders.remove(adapter.id)
        await refreshLibrary()
    }

    func disconnect(_ adapter: any ProviderAdapter) async {
        if player.currentTrack?.provider == adapter.id {
            player.stop()
        }
        adapter.disconnect()
        connectionErrors[adapter.id] = nil
        for index in queue.tracks.indices.reversed() where queue.tracks[index].provider == adapter.id {
            queue.remove(at: index)
        }
        await refreshLibrary()
    }

    func setProvider(_ adapter: any ProviderAdapter, enabled: Bool) async {
        access.setEnabled(adapter.id, enabled)
        if !enabled {
            await disconnect(adapter)
        }
    }

    func play(_ track: UnifiedTrack, in list: [UnifiedTrack]) {
        let playable = list.filter { !$0.isUnplayable || $0.id == track.id }
        guard let index = playable.firstIndex(where: { $0.id == track.id }) else { return }
        player.stop()
        queue.clear()
        queue.add(contentsOf: playable)
        player.play(at: index)
    }

    func enqueue(_ tracks: [UnifiedTrack]) {
        queue.add(contentsOf: tracks.filter { !$0.isUnplayable })
    }

    func playNext(_ tracks: [UnifiedTrack]) {
        queue.insertNext(tracks.filter { !$0.isUnplayable })
    }

    func removeFromQueue(at index: Int) {
        guard queue.tracks.indices.contains(index) else { return }
        var continuePlaying = false
        if queue.currentIndex == index {
            continuePlaying = player.state == .playing || player.state == .loading
            player.stop()
        }
        queue.remove(at: index)
        if continuePlaying, queue.tracks.indices.contains(index) {
            player.play(at: index)
        }
    }

    func removeFromQueue(indices: Set<Int>) {
        for index in indices.sorted(by: >) {
            removeFromQueue(at: index)
        }
    }

    func clearQueue() {
        player.stop()
        queue.clear()
    }

    @discardableResult
    func generateMix(_ request: MixRequest) throws -> MixResult {
        try subscription.authorize(request)
        let result = try MixEngine().mix(request, from: library)
        guard !result.tracks.isEmpty else { throw MixError.noTracks }
        subscription.recordMix()
        player.stop()
        queue.clear()
        queue.add(contentsOf: result.tracks)
        player.play(at: 0)
        return result
    }

    @discardableResult
    func generateRandomMix() throws -> MixResult {
        try subscription.authorizeRandomMix()
        var generator = SystemRandomNumberGenerator()
        let request = MixRequest.random(from: connectedAdapters.map(\.id), using: &generator)
        return try generateMix(request)
    }

    func saveMix(named name: String, request: MixRequest) throws {
        try subscription.authorizeSavedMixes()
        guard !request.providers.isEmpty else { throw MixError.noProviders }
        guard request.effectiveTrackCount > 0 else { throw MixError.invalidTrackCount }
        try savedMixes.add(name: name, request: request)
    }

    func deleteSavedMix(_ mix: SavedMix) throws {
        try savedMixes.remove(mix.id)
    }

    @discardableResult
    func runSavedMix(_ mix: SavedMix) throws -> MixResult {
        try subscription.authorizeSavedMixes()
        var request = mix.request
        let available = Set(connectedAdapters.map(\.id))
        request.providers = request.providers.filter { available.contains($0) }
        return try generateMix(request)
    }

    func setAIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Keychain.set(trimmed, account: AIKey.account)
        hasAIKey = true
    }

    func clearAIKey() {
        Keychain.delete(account: AIKey.account)
        hasAIKey = false
    }

    func generateAIMix(_ text: String, transport: (any AITransport)? = nil) async throws -> (result: MixResult, plan: AIMixPlan) {
        try subscription.authorizeAI()
        let engine: AIEngine
        if let transport {
            engine = AIEngine(transport: transport)
        } else {
            guard let key = Keychain.get(account: AIKey.account) else { throw AIError.missingKey }
            engine = AIEngine(transport: AnthropicTransport(apiKey: key))
        }
        let connected = connectedAdapters
        let context = AIContext(providers: connected.map { adapter in
            AIContext.ProviderInfo(id: adapter.id, name: adapter.displayName, trackCount: library.filter { $0.provider == adapter.id }.count)
        })
        let plan = try await engine.plan(for: text, context: context)
        let durations = library.map(\.duration).filter { $0 > 0 }
        let average = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
        let request = plan.makeRequest(connected: connected.map(\.id), averageTrackLength: average)
        return (try generateMix(request), plan)
    }

    private func enforceAccess() async {
        for adapter in adapterList where !access.isEnabled(adapter.id) && adapter.isConnected {
            adapter.disconnect()
        }
        await refreshLibrary()
    }
}
