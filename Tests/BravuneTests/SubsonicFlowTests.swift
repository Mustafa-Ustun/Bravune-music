import XCTest
@testable import Bravune

@MainActor
final class SubsonicFlowTests: XCTestCase {
    private var server: MockSubsonicServer!
    private var localFolder: URL!
    private var previousFolder: String?

    override func setUp() async throws {
        localFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
        let remote = localFolder.appendingPathComponent("remote.wav")
        try makeToneFile(at: remote, seconds: 1.5, frequency: 523)
        server = try MockSubsonicServer(
            songs: [
                .init(id: "s1", title: "Remote One", artist: "Zed", album: "Net", duration: 2),
                .init(id: "s2", title: "Remote Two", artist: "Yan", album: "Net", duration: 2)
            ],
            audio: try Data(contentsOf: remote)
        )
        try await server.start()
        try FileManager.default.removeItem(at: remote)
        try makeToneFile(at: localFolder.appendingPathComponent("Local One.wav"), seconds: 1.5, frequency: 330)
        previousFolder = UserDefaults.standard.string(forKey: LocalMusicAdapter.folderDefaultsKey)
        UserDefaults.standard.set(localFolder.path, forKey: LocalMusicAdapter.folderDefaultsKey)
    }

    override func tearDown() async throws {
        server.stop()
        if let previousFolder {
            UserDefaults.standard.set(previousFolder, forKey: LocalMusicAdapter.folderDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LocalMusicAdapter.folderDefaultsKey)
        }
        try? FileManager.default.removeItem(at: localFolder)
    }

    private func credentials(password: String? = nil) -> SubsonicCredentials {
        SubsonicCredentials(serverURL: server.baseURL, username: server.user, password: password ?? server.password)
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    func testServerAcceptsTokenAndRejectsWrongPassword() async throws {
        try await SubsonicClient(credentials: credentials()).ping()
        do {
            try await SubsonicClient(credentials: credentials(password: "wrong")).ping()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Wrong username or password")
        }
    }

    func testLibraryBecomesUnifiedTracks() async throws {
        let adapter = SubsonicAdapter(credentials: credentials())
        XCTAssertTrue(adapter.isConnected)
        let tracks = try await adapter.tracks()
        XCTAssertEqual(tracks.map(\.title), ["Remote Two", "Remote One"])
        XCTAssertTrue(tracks.allSatisfy { $0.provider == .subsonic })
        XCTAssertEqual(Set(tracks.map(\.providerTrackId)), ["s1", "s2"])
        XCTAssertEqual(tracks.first?.duration, 2)
        let artwork = try XCTUnwrap(tracks.first?.artwork)
        XCTAssertTrue(artwork.path.hasSuffix("getCoverArt.view"))
        XCTAssertTrue(server.requests.contains { $0.contains("search3.view") })
    }

    func testProviderToQueueToPlayerOverHTTP() async throws {
        let adapter = SubsonicAdapter(credentials: credentials())
        let tracks = try await adapter.tracks()
        let queue = UnifiedQueue()
        queue.add(contentsOf: tracks)
        let player = Player(queue: queue, adapters: [adapter.id: adapter])
        player.volume = 0

        player.play(at: 0)
        var ready = await waitUntil { player.state == .playing }
        XCTAssertTrue(ready, "state was \(player.state)")
        XCTAssertTrue(server.requests.contains { $0.contains("stream.view") })

        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertGreaterThan(player.position, 0.3)

        player.pause()
        XCTAssertEqual(player.state, .paused)
        player.play()
        XCTAssertEqual(player.state, .playing)

        player.seek(to: 1.0)
        ready = await waitUntil { player.currentTrack?.title == "Remote One" && player.state == .playing }
        XCTAssertTrue(ready, "did not advance, state \(player.state)")

        player.seek(to: 1.0)
        let ended = await waitUntil { player.state == .stopped }
        XCTAssertTrue(ended, "state was \(player.state)")
    }

    func testMixedProvidersPlayThroughOneQueue() async throws {
        let subsonic = SubsonicAdapter(credentials: credentials())
        let local = LocalMusicAdapter()
        let remoteTracks = try await subsonic.tracks()
        let localTracks = try await local.tracks()
        XCTAssertEqual(localTracks.count, 1)

        let queue = UnifiedQueue()
        queue.add(remoteTracks[0])
        queue.add(localTracks[0])
        queue.add(remoteTracks[1])
        let player = Player(queue: queue, adapters: [subsonic.id: subsonic, local.id: local])
        player.volume = 0

        var order: [ProviderID] = []
        player.play(at: 0)
        for index in 0..<3 {
            let ready = await waitUntil { queue.currentIndex == index && player.state == .playing }
            XCTAssertTrue(ready, "track \(index) never played, state \(player.state)")
            order.append(try XCTUnwrap(player.currentTrack).provider)
            player.seek(to: 1.0)
        }
        XCTAssertEqual(order, [.subsonic, .localMusic, .subsonic])
        let ended = await waitUntil { player.state == .stopped }
        XCTAssertTrue(ended)
    }

    func testDisconnectedAdapterHasNoTracks() async throws {
        let adapter = SubsonicAdapter(credentials: nil)
        XCTAssertFalse(adapter.isConnected)
        let tracks = try await adapter.tracks()
        XCTAssertTrue(tracks.isEmpty)
    }
}
