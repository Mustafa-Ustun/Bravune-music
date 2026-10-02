import XCTest
@testable import Bravune

@MainActor
final class SpotifyTests: XCTestCase {
    func testPKCEChallengeMatchesRFCExample() {
        let challenge = SpotifySession.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testFormBodyEncodesReservedCharacters() {
        let body = String(data: SpotifySession.formBody(["b": "a b+c", "a": "bravune://callback"]), encoding: .utf8)
        XCTAssertEqual(body, "a=bravune%3A%2F%2Fcallback&b=a%20b%2Bc")
    }

    func testDecodesSavedTracksAndSkipsLocalOrMissing() throws {
        let json = """
        {"next":null,"items":[
        {"track":{"id":"abc","name":"Song","artists":[{"name":"A"},{"name":"B"}],"album":{"name":"Album","images":[{"url":"https://i/640","width":640},{"url":"https://i/300","width":300},{"url":"https://i/64","width":64}]},"duration_ms":214000,"is_local":false}},
        {"track":null}]}
        """
        let page = try JSONDecoder().decode(SpotifySavedPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.items.compactMap(\.track).count, 1)
        let track = try XCTUnwrap(page.items.first?.track)
        XCTAssertEqual(track.duration_ms, 214000)
        XCTAssertEqual(SpotifyAdapter.artwork(from: track.album.images)?.absoluteString, "https://i/300")
    }

    func testPremiumRequiredMessage() {
        let json = #"{"error":{"status":403,"message":"Player command failed: Premium required","reason":"PREMIUM_REQUIRED"}}"#
        XCTAssertEqual(SpotifyAPI.failureMessage(data: Data(json.utf8), status: 403), "Spotify Premium is required for playback")
    }

    func testBare403MeansPremiumRequired() {
        XCTAssertEqual(SpotifyAPI.failureMessage(data: Data(), status: 403), "Spotify Premium is required")
        XCTAssertEqual(SpotifyAPI.failureMessage(data: Data("Forbidden".utf8), status: 403), "Spotify Premium is required")
        XCTAssertEqual(SpotifyAPI.failureMessage(data: Data(#"{"error":{"status":403}}"#.utf8), status: 403), "Spotify Premium is required")
        XCTAssertEqual(SpotifyAPI.failureMessage(data: Data(), status: 500), "Spotify request failed (500)")
    }
}
