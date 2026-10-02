import XCTest
@testable import Bravune

final class KeychainTests: XCTestCase {
    func testStoreOverwriteReadAndDeleteRoundTrip() {
        let account = "test.\(UUID().uuidString)"
        addTeardownBlock { Keychain.delete(account: account) }
        XCTAssertNil(Keychain.get(account: account))
        Keychain.set("first-value", account: account)
        XCTAssertEqual(Keychain.get(account: account), "first-value")
        Keychain.set("second-value", account: account)
        XCTAssertEqual(Keychain.get(account: account), "second-value")
        Keychain.delete(account: account)
        XCTAssertNil(Keychain.get(account: account))
    }

    func testDeletingAMissingItemDoesNotCrash() {
        Keychain.delete(account: "test.\(UUID().uuidString)")
    }
}
