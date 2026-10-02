import XCTest
@testable import Bravune

@MainActor
final class SpotifyMockIntegrationTests: XCTestCase {
    private var server: MockSpotifyServer!

    override func setUp() async throws {
        server = try MockSpotifyServer()
        try await server.start()
    }

    override func tearDown() async throws {
        server.stop()
    }

    private func makeAPI() -> SpotifyAPI {
        let session = SpotifySession(clientID: "client", refreshToken: "refresh-1", tokenURL: server.url("/api/token"))
        return SpotifyAPI(session: session, baseURL: server.url("/v1"))
    }

    private func makeAdapter() -> SpotifyAdapter {
        SpotifyAdapter(api: makeAPI(), accountName: "Test User")
    }

    private func makePlayer(tracks: [UnifiedTrack]) -> (Player, UnifiedQueue) {
        let adapter = makeAdapter()
        let queue = UnifiedQueue()
        queue.add(contentsOf: tracks)
        return (Player(queue: queue, adapters: [adapter.id: adapter]), queue)
    }

    private func spotifyTracks(_ count: Int) async throws -> [UnifiedTrack] {
        server.likedSongTotal = count
        return try await makeAdapter().tracks()
    }

    func testRefreshTokenIsExchangedAndUsedAsBearerToken() async throws {
        let api = makeAPI()
        let name = try await api.displayName()
        XCTAssertEqual(name, "Test User")
        let tokenCalls = server.requests("POST", "/api/token")
        XCTAssertEqual(tokenCalls.count, 1)
        XCTAssertTrue(tokenCalls[0].bodyText.contains("grant_type=refresh_token"))
        XCTAssertTrue(tokenCalls[0].bodyText.contains("client_id=client"))
        XCTAssertEqual(server.requests("GET", "/v1/me").first?.headers["authorization"], "Bearer tok-1")
        _ = try await api.displayName()
        XCTAssertEqual(server.requests("POST", "/api/token").count, 1)
    }

    func testExpiredAccessTokenIsRefreshedAgain() async throws {
        server.tokenLifetime = 30
        let api = makeAPI()
        _ = try await api.displayName()
        _ = try await api.displayName()
        XCTAssertEqual(server.requests("POST", "/api/token").count, 2)
        XCTAssertEqual(server.requests("GET", "/v1/me").map { $0.headers["authorization"] }, ["Bearer tok-1", "Bearer tok-2"])
    }

    func testUnauthorizedResponseTriggersOneRefreshAndRetry() async throws {
        server.failOnce(unauthorized: "/v1/me")
        let name = try await makeAPI().displayName()
        XCTAssertEqual(name, "Test User")
        XCTAssertEqual(server.requests("GET", "/v1/me").count, 2)
        XCTAssertEqual(server.requests("POST", "/api/token").count, 2)
    }

    func testRateLimitedResponseIsRetriedAfterTheAdvertisedDelay() async throws {
        server.likedSongTotal = 3
        server.failOnce(rateLimited: "/v1/me/tracks")
        let tracks = try await makeAdapter().tracks()
        XCTAssertEqual(tracks.count, 3)
        XCTAssertEqual(server.requests("GET", "/v1/me/tracks").count, 2)
    }

    func testRevokedRefreshTokenSurfacesSpotifyMessage() async {
        server.tokenFailure = (400, #"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#)
        do {
            _ = try await makeAdapter().tracks()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Refresh token revoked")
        }
    }

    func testWrongClientCredentialsAreRejectedByTokenEndpoint() async {
        let session = SpotifySession(clientID: "other", refreshToken: "refresh-1", tokenURL: server.url("/api/token"))
        let api = SpotifyAPI(session: session, baseURL: server.url("/v1"))
        do {
            _ = try await api.displayName()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Invalid refresh token")
        }
    }

    func testLikedSongsArePagedAndMappedToUnifiedTracks() async throws {
        server.likedSongTotal = 120
        server.localTrackIndexes = [3, 77]
        server.nullTrackIndexes = [10]
        let adapter = makeAdapter()
        let tracks = try await adapter.tracks()
        XCTAssertEqual(tracks.count, 117)
        let pages = server.requests("GET", "/v1/me/tracks")
        XCTAssertEqual(pages.map { $0.query["offset"] }, ["0", "50", "100"])
        XCTAssertTrue(pages.allSatisfy { $0.query["limit"] == "50" })
        XCTAssertTrue(pages.allSatisfy { $0.headers["authorization"] == "Bearer tok-1" })
        XCTAssertEqual(server.requests("POST", "/api/token").count, 1)
        XCTAssertTrue(tracks.allSatisfy { $0.provider == .spotify })
        let track = try XCTUnwrap(tracks.first { $0.providerTrackId == "track5" })
        XCTAssertEqual(track.id, "spotify:track5")
        XCTAssertEqual(track.title, "Song 5")
        XCTAssertEqual(track.artist, "Artist 5, Guest")
        XCTAssertEqual(track.album, "Album 5")
        XCTAssertEqual(track.duration, 200)
        XCTAssertEqual(track.artwork?.absoluteString, "https://img/300/5")
        XCTAssertFalse(tracks.contains { $0.providerTrackId == "track3" || $0.providerTrackId == "track10" })
        XCTAssertEqual(Set(tracks.map(\.id)).count, tracks.count)
    }

    func testExactPageBoundaryStopsWithoutExtraRequest() async throws {
        server.likedSongTotal = 100
        let tracks = try await makeAdapter().tracks()
        XCTAssertEqual(tracks.count, 100)
        XCTAssertEqual(server.requests("GET", "/v1/me/tracks").count, 2)
    }

    func testEmptyLibraryReturnsNoTracks() async throws {
        server.likedSongTotal = 0
        let tracks = try await makeAdapter().tracks()
        XCTAssertTrue(tracks.isEmpty)
        XCTAssertEqual(server.requests("GET", "/v1/me/tracks").count, 1)
    }

    func testServerErrorsBecomeReadableMessages() async {
        server.tracksFailure = (500, "upstream exploded")
        do {
            _ = try await makeAdapter().tracks()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Spotify request failed (500)")
        }
        server.tracksFailure = (403, #"{"error":{"status":403,"message":"Insufficient client scope"}}"#)
        do {
            _ = try await makeAdapter().tracks()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Insufficient client scope")
        }
    }

    func testLibraryFailureIsReportedByAppStateWithoutLosingOtherProviders() async throws {
        server.tracksFailure = (500, "down")
        let other = FakeAdapter(id: "other", count: 2)
        let state = AppState(adapters: [makeAdapter(), other], refreshesOnLaunch: false)
        await state.refreshLibrary()
        XCTAssertEqual(state.library.count, 2)
        XCTAssertEqual(state.errorMessage, "Spotify: Spotify request failed (500)")
    }

    func testSpotifyTracksFlowThroughQueueAndPlayerToTheSpotifyApp() async throws {
        let tracks = try await spotifyTracks(3)
        let (player, queue) = makePlayer(tracks: tracks)
        player.play(at: 1)
        let playing = await eventually { player.state == .playing }
        XCTAssertTrue(playing, "state was \(player.state)")
        XCTAssertEqual(queue.currentTrack?.providerTrackId, "track1")

        let plays = server.requests("PUT", "/v1/me/player/play")
        XCTAssertEqual(plays.count, 1)
        XCTAssertEqual(plays[0].query["device_id"], "device-mac")
        XCTAssertEqual(plays[0].headers["authorization"]?.hasPrefix("Bearer tok-"), true)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: plays[0].body) as? [String: [String]])
        XCTAssertEqual(body["uris"], ["spotify:track:track1"])
        XCTAssertEqual(server.requests("GET", "/v1/me/player/devices").count, 1)
        player.stop()
    }

    func testPauseResumeSeekAndVolumeReachTheSpotifyApp() async throws {
        let tracks = try await spotifyTracks(2)
        let (player, _) = makePlayer(tracks: tracks)
        player.play(at: 0)
        _ = await eventually { player.state == .playing }

        player.pause()
        XCTAssertEqual(player.state, .paused)
        let paused = await eventually { self.server.requests("PUT", "/v1/me/player/pause").count == 1 }
        XCTAssertTrue(paused)
        XCTAssertEqual(server.requests("PUT", "/v1/me/player/pause")[0].query["device_id"], "device-mac")

        player.play()
        let resumed = await eventually { self.server.requests("PUT", "/v1/me/player/play").count == 2 }
        XCTAssertTrue(resumed)
        XCTAssertTrue(server.requests("PUT", "/v1/me/player/play")[1].body.isEmpty)

        player.seek(to: 10)
        player.seek(to: 20)
        player.seek(to: 30)
        let sought = await eventually { !self.server.requests("PUT", "/v1/me/player/seek").isEmpty }
        XCTAssertTrue(sought)
        try await Task.sleep(nanoseconds: 500_000_000)
        let seeks = server.requests("PUT", "/v1/me/player/seek")
        XCTAssertEqual(seeks.count, 1)
        XCTAssertEqual(seeks[0].query["position_ms"], "30000")
        XCTAssertEqual(seeks[0].query["device_id"], "device-mac")

        player.volume = 0.5
        let volumed = await eventually { !self.server.requests("PUT", "/v1/me/player/volume").isEmpty }
        XCTAssertTrue(volumed)
        XCTAssertEqual(server.requests("PUT", "/v1/me/player/volume").last?.query["volume_percent"], "50")
        player.stop()
    }

    func testSwitchingTracksPausesBeforePlayingTheNext() async throws {
        let tracks = try await spotifyTracks(2)
        let (player, _) = makePlayer(tracks: tracks)
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        player.next()
        let second = await eventually { self.server.requests("PUT", "/v1/me/player/play").count == 2 && player.state == .playing }
        XCTAssertTrue(second)
        let order = server.requests.filter { $0.path == "/v1/me/player/pause" || $0.path == "/v1/me/player/play" }.map(\.path)
        XCTAssertEqual(order, ["/v1/me/player/play", "/v1/me/player/pause", "/v1/me/player/play"])
        player.stop()
    }

    func testNoSpotifyDeviceGivesActionableError() async throws {
        let tracks = try await spotifyTracks(1)
        server.devices = []
        let (player, _) = makePlayer(tracks: tracks)
        player.play(at: 0)
        let failed = await eventually { player.state == .failed("Open the Spotify app on this Mac and try again") }
        XCTAssertTrue(failed, "state was \(player.state)")
        XCTAssertTrue(server.requests("PUT", "/v1/me/player/play").isEmpty)
    }

    func testInactiveDeviceIsChosenWhenNoneIsActive() async throws {
        let tracks = try await spotifyTracks(1)
        server.devices = [
            .init(id: "phone", active: false, name: "Phone", type: "Smartphone"),
            .init(id: "laptop", active: false, name: "Laptop", type: "Computer")
        ]
        let (player, _) = makePlayer(tracks: tracks)
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        XCTAssertEqual(server.requests("PUT", "/v1/me/player/play").first?.query["device_id"], "laptop")
        player.stop()
    }

    func testPremiumRequiredIsShownByThePlayer() async throws {
        let tracks = try await spotifyTracks(1)
        server.playFailure = (403, #"{"error":{"status":403,"message":"Player command failed: Premium required","reason":"PREMIUM_REQUIRED"}}"#)
        let (player, _) = makePlayer(tracks: tracks)
        player.play(at: 0)
        let failed = await eventually { player.state == .failed("Spotify Premium is required for playback") }
        XCTAssertTrue(failed, "state was \(player.state)")
    }

    func testPositionSyncAndTrackEndAdvanceTheQueue() async throws {
        let tracks = try await spotifyTracks(2)
        server.playerStateJSON = #"{"is_playing":true,"progress_ms":42000,"item":{"id":"track0"}}"#
        let (player, queue) = makePlayer(tracks: tracks)
        player.play(at: 0)
        _ = await eventually { player.state == .playing }
        let synced = await eventually(timeout: 12) { player.position >= 41 }
        XCTAssertTrue(synced, "position was \(player.position)")
        XCTAssertEqual(queue.currentIndex, 0)

        server.playerStateJSON = #"{"is_playing":false,"progress_ms":0,"item":{"id":"track0"}}"#
        let advanced = await eventually(timeout: 12) { queue.currentIndex == 1 && player.state == .playing }
        XCTAssertTrue(advanced, "index \(String(describing: queue.currentIndex)), state \(player.state)")
        let plays = server.requests("PUT", "/v1/me/player/play")
        XCTAssertEqual(plays.count, 2)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: plays[1].body) as? [String: [String]])
        XCTAssertEqual(body["uris"], ["spotify:track:track1"])
        player.stop()
    }

    func testChangingTrackInTheSpotifyAppAdvancesTheQueue() async throws {
        let tracks = try await spotifyTracks(2)
        server.playerStateJSON = #"{"is_playing":true,"progress_ms":1000,"item":{"id":"someone-else"}}"#
        let (player, queue) = makePlayer(tracks: tracks)
        player.play(at: 0)
        let advanced = await eventually(timeout: 12) { queue.currentIndex == 1 }
        XCTAssertTrue(advanced)
        player.stop()
    }

    func testSpotifyLibraryToMixToQueueToPlayer() async throws {
        server.likedSongTotal = 30
        let state = AppState(
            adapters: [makeAdapter(), FakeAdapter(id: "other", count: 5)],
            subscription: freeProSubscription(),
            savedMixes: SavedMixStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("m.json")),
            refreshesOnLaunch: false
        )
        await state.refreshLibrary()
        XCTAssertEqual(state.library.filter { $0.provider == .spotify }.count, 30)
        let result = try state.generateMix(MixRequest(providers: [.spotify], trackCount: 6, avoidDuplicateArtists: true))
        XCTAssertEqual(result.tracks.count, 6)
        XCTAssertTrue(state.queue.tracks.allSatisfy { $0.provider == .spotify })
        let playing = await eventually { state.player.state == .playing }
        XCTAssertTrue(playing)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: server.requests("PUT", "/v1/me/player/play")[0].body) as? [String: [String]])
        XCTAssertEqual(body["uris"], ["spotify:track:\(state.queue.tracks[0].providerTrackId)"])
        state.player.stop()
    }

    private func freeProSubscription() -> Subscription {
        let subscription = Subscription(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        subscription.plan = .pro
        return subscription
    }
}
