import XCTest
@testable import Bravune

final class SubsonicClientTests: XCTestCase {
    private let client = SubsonicClient(
        credentials: SubsonicCredentials(
            serverURL: URL(string: "https://music.example.com")!,
            username: "joe",
            password: "sesame"
        )
    )

    func testTokenAuthentication() throws {
        let url = try client.url("ping", salt: "c19b2d")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.path, "/rest/ping.view")
        XCTAssertEqual(items["u"], "joe")
        XCTAssertEqual(items["s"], "c19b2d")
        XCTAssertEqual(items["t"], "26719a1196d2a940705a59634eb18eab")
        XCTAssertNil(items["p"])
    }

    func testDecodesSongs() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{"song":[{"id":"42","title":"Song","artist":"Artist","album":"Album","duration":214,"coverArt":"al-1"}]}}}
        """
        let response = try SubsonicClient.decode(Data(json.utf8))
        XCTAssertEqual(response.searchResult3?.song?.first?.id, "42")
        XCTAssertEqual(response.searchResult3?.song?.first?.duration, 214)
    }

    func testEmptyResultHasNoSongs() throws {
        let json = #"{"subsonic-response":{"status":"ok","searchResult3":{}}}"#
        XCTAssertNil(try SubsonicClient.decode(Data(json.utf8)).searchResult3?.song)
    }

    func testServerErrorIsThrown() {
        let json = #"{"subsonic-response":{"status":"failed","error":{"code":40,"message":"Wrong username or password"}}}"#
        XCTAssertThrowsError(try SubsonicClient.decode(Data(json.utf8))) { error in
            XCTAssertEqual(error.localizedDescription, "Wrong username or password")
        }
    }
}
