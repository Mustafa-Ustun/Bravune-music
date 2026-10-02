import XCTest
@testable import Bravune

final class AppleMusicSummaryTests: XCTestCase {
    func testAuthorizedOnlyWhenNothingElseIsKnown() {
        XCTAssertEqual(AppleMusicConnectionSummary.text(songCount: nil, subscription: .unknown), "Authorized")
    }

    func testIncludesSubscriptionAndSongCount() {
        XCTAssertEqual(
            AppleMusicConnectionSummary.text(songCount: 1280, subscription: .active),
            "Authorized \u{00B7} subscription active \u{00B7} 1280 songs in library"
        )
    }

    func testInactiveSubscriptionAndEmptyLibraryAreStated() {
        XCTAssertEqual(
            AppleMusicConnectionSummary.text(songCount: 0, subscription: .inactive),
            "Authorized \u{00B7} no active subscription \u{00B7} 0 songs in library"
        )
    }

    func testSingularSong() {
        XCTAssertEqual(
            AppleMusicConnectionSummary.text(songCount: 1, subscription: .unknown),
            "Authorized \u{00B7} 1 song in library"
        )
    }
}
