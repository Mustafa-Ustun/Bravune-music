import XCTest
@testable import Bravune

private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            request.httpBody = data
        }
        Self.seen.append(request)
        let (status, body) = Self.handler?(request) ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class JellyfinClientTests: XCTestCase {
    private let server = URL(string: "https://jf.example.com")!
    private var urlSession: URLSession!

    override func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        urlSession = URLSession(configuration: configuration)
        StubProtocol.seen = []
        StubProtocol.handler = nil
    }

    private func session() -> JellyfinSession {
        JellyfinSession(serverURL: server, userId: "u1", username: "joe", accessToken: "tok")
    }

    private func client() -> JellyfinClient {
        JellyfinClient(session: session(), deviceId: "dev", urlSession: urlSession)
    }

    private func item(_ id: String) -> String {
        #"{"Id":"\#(id)","Name":"Song \#(id)","Artists":["A"],"Album":"B","RunTimeTicks":20000000,"AlbumId":"al1","ImageTags":{}}"#
    }

    func testAuthorizationHeaderCarriesClientDeviceAndToken() {
        let header = JellyfinClient.authorizationHeader(deviceId: "dev", token: "tok")
        XCTAssertTrue(header.hasPrefix("MediaBrowser "))
        XCTAssertTrue(header.contains(#"Client="Bravune""#))
        XCTAssertTrue(header.contains(#"DeviceId="dev""#))
        XCTAssertTrue(header.contains(#"Token="tok""#))
        XCTAssertFalse(JellyfinClient.authorizationHeader(deviceId: "dev", token: nil).contains("Token="))
    }

    func testDecodesItemsAndConvertsTicksToSeconds() throws {
        let json = #"{"Items":[\#(item("1"))],"TotalRecordCount":1}"#
        let page = try JellyfinClient.decodePage(Data(json.utf8))
        XCTAssertEqual(page.items.first?.name, "Song 1")
        XCTAssertEqual(page.items.first?.duration, 2)
        XCTAssertEqual(page.items.first?.displayArtist, "A")
    }

    func testArtistFallsBackToAlbumArtistThenUnknown() throws {
        let json = #"{"Items":[{"Id":"1","Name":"x","AlbumArtist":"AA"},{"Id":"2","Name":"y"}]}"#
        let items = try JellyfinClient.decodePage(Data(json.utf8)).items
        XCTAssertEqual(items[0].displayArtist, "AA")
        XCTAssertEqual(items[1].displayArtist, "Unknown Artist")
    }

    func testStreamURLUsesUniversalEndpointWithTokenAndTranscodingFallback() throws {
        let url = try client().streamURL(id: "abc")
        XCTAssertEqual(url.path, "/Audio/abc/universal")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["api_key"], "tok")
        XCTAssertEqual(items["UserId"], "u1")
        XCTAssertEqual(items["TranscodingContainer"], "mp3")
    }

    func testImageURLPrefersOwnPrimaryThenAlbum() throws {
        let own = JellyfinItem(id: "t1", name: "n", artists: nil, albumArtist: nil, album: nil, runTimeTicks: nil, albumId: "al1", imageTags: ["Primary": "x"])
        let viaAlbum = JellyfinItem(id: "t2", name: "n", artists: nil, albumArtist: nil, album: nil, runTimeTicks: nil, albumId: "al1", imageTags: [:])
        let none = JellyfinItem(id: "t3", name: "n", artists: nil, albumArtist: nil, album: nil, runTimeTicks: nil, albumId: nil, imageTags: nil)
        XCTAssertEqual(client().imageURL(for: own)?.path, "/Items/t1/Images/Primary")
        XCTAssertEqual(client().imageURL(for: viaAlbum)?.path, "/Items/al1/Images/Primary")
        XCTAssertNil(client().imageURL(for: none))
    }

    func testAuthenticateReturnsSessionAndSendsCredentials() async throws {
        StubProtocol.handler = { _ in
            (200, Data(#"{"AccessToken":"tok","User":{"Id":"u1","Name":"joe"}}"#.utf8))
        }
        let result = try await JellyfinClient.authenticate(serverURL: server, username: "joe", password: "pw", deviceId: "dev", urlSession: urlSession)
        XCTAssertEqual(result, session())
        let request = try XCTUnwrap(StubProtocol.seen.first)
        XCTAssertEqual(request.url?.path, "/Users/AuthenticateByName")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
        XCTAssertEqual(body, ["Username": "joe", "Pw": "pw"])
    }

    func testWrongPasswordIsReported() async {
        StubProtocol.handler = { _ in (401, Data()) }
        do {
            _ = try await JellyfinClient.authenticate(serverURL: server, username: "joe", password: "bad", deviceId: "dev", urlSession: urlSession)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Wrong username or password")
        }
    }

    func testAllSongsPagesUntilShortPage() async throws {
        let full = (0..<JellyfinClient.pageSize).map { item("\($0)") }.joined(separator: ",")
        StubProtocol.handler = { request in
            let start = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "StartIndex" }?.value
            if start == "0" {
                return (200, Data(#"{"Items":[\#(full)],"TotalRecordCount":501}"#.utf8))
            }
            return (200, Data(#"{"Items":[\#(self.item("last"))],"TotalRecordCount":501}"#.utf8))
        }
        let songs = try await client().allSongs()
        XCTAssertEqual(songs.count, JellyfinClient.pageSize + 1)
        XCTAssertEqual(StubProtocol.seen.count, 2)
        let header = StubProtocol.seen.first?.value(forHTTPHeaderField: "Authorization")
        XCTAssertTrue(header?.contains(#"Token="tok""#) ?? false)
    }

    func testExpiredTokenAsksToConnectAgain() async {
        StubProtocol.handler = { _ in (401, Data()) }
        do {
            _ = try await client().allSongs()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The server no longer accepts this login. Connect again.")
        }
    }

    @MainActor
    func testAdapterConnectionStateAndEmptyLibraryAfterDisconnect() async throws {
        let adapter = JellyfinAdapter(session: session(), deviceId: "dev")
        XCTAssertTrue(adapter.isConnected)
        XCTAssertEqual(adapter.id, .jellyfin)
        adapter.disconnect()
        XCTAssertFalse(adapter.isConnected)
        let tracks = try await adapter.tracks()
        XCTAssertTrue(tracks.isEmpty)
    }
}
