import XCTest
@testable import Bravune

private struct ReadableFailure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

@MainActor
final class ConnectErrorTests: XCTestCase {
    private func makeState(_ adapters: [FakeAdapter]) -> AppState {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return AppState(
            adapters: adapters,
            access: ProviderAccess(defaults: defaults),
            subscription: Subscription(defaults: defaults),
            savedMixes: SavedMixStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("m.json")),
            refreshesOnLaunch: false
        )
    }

    func testFailedConnectKeepsItsErrorAfterTheLibraryRefresh() async {
        let a = FakeAdapter(id: "alpha", connected: false)
        a.connectError = ReadableFailure(text: "Wrong username or password")
        let state = makeState([a])
        await state.connect(a)
        XCTAssertEqual(state.connectionErrors[a.id], "Wrong username or password")
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(a.isConnected)
    }

    func testAnErrorBelongsOnlyToTheProviderThatFailed() async {
        let a = FakeAdapter(id: "alpha", connected: false)
        let b = FakeAdapter(id: "beta", connected: false)
        a.connectError = FakeFailure()
        let state = makeState([a, b])
        await state.connect(a)
        await state.connect(b)
        XCTAssertEqual(state.connectionErrors[a.id], "fake failure")
        XCTAssertNil(state.connectionErrors[b.id])
        XCTAssertTrue(b.isConnected)
    }

    func testASuccessfulRetryClearsTheOldError() async {
        let a = FakeAdapter(id: "alpha", connected: false)
        a.connectError = FakeFailure()
        let state = makeState([a])
        await state.connect(a)
        XCTAssertNotNil(state.connectionErrors[a.id])
        a.connectError = nil
        await state.connect(a)
        XCTAssertNil(state.connectionErrors[a.id])
        XCTAssertTrue(a.isConnected)
        XCTAssertEqual(state.library.count, 5)
    }

    func testANewFailureReplacesTheOldMessage() async {
        let a = FakeAdapter(id: "alpha", connected: false)
        let state = makeState([a])
        a.connectError = ReadableFailure(text: "first")
        await state.connect(a)
        a.connectError = ReadableFailure(text: "second")
        await state.connect(a)
        XCTAssertEqual(state.connectionErrors[a.id], "second")
    }

    func testCancellingTheConnectDialogIsNotAnError() async {
        let a = FakeAdapter(id: "alpha", connected: false)
        a.cancelsConnect = true
        let state = makeState([a])
        await state.connect(a)
        XCTAssertTrue(state.connectionErrors.isEmpty)
        XCTAssertFalse(a.isConnected)
        XCTAssertTrue(state.connectingProviders.isEmpty)
    }

    func testCancellingAfterAFailureClearsTheStaleError() async {
        let a = FakeAdapter(id: "alpha", connected: false)
        a.connectError = FakeFailure()
        let state = makeState([a])
        await state.connect(a)
        a.connectError = nil
        a.cancelsConnect = true
        await state.connect(a)
        XCTAssertTrue(state.connectionErrors.isEmpty)
    }

    func testDisconnectClearsTheError() async {
        let a = FakeAdapter(id: "alpha", connected: false)
        a.connectError = FakeFailure()
        let state = makeState([a])
        await state.connect(a)
        await state.disconnect(a)
        XCTAssertTrue(state.connectionErrors.isEmpty)
    }

    func testConnectingStateIsVisibleDuringTheAttemptAndClearedAfterwards() async {
        let a = FakeAdapter(id: "alpha", connected: false)
        a.connectDelay = 300_000_000
        let state = makeState([a])
        let attempt = Task { await state.connect(a) }
        let started = await eventually { state.connectingProviders.contains(a.id) }
        XCTAssertTrue(started)
        await attempt.value
        XCTAssertTrue(state.connectingProviders.isEmpty)
        XCTAssertTrue(a.isConnected)
    }

    func testAFailedAttemptAlsoClearsTheConnectingState() async {
        let a = FakeAdapter(id: "alpha", connected: false)
        a.connectError = FakeFailure()
        a.connectDelay = 100_000_000
        let state = makeState([a])
        await state.connect(a)
        XCTAssertTrue(state.connectingProviders.isEmpty)
    }

    func testASecondConnectWhileOneIsRunningIsIgnored() async {
        let a = FakeAdapter(id: "alpha", connected: false)
        a.connectDelay = 300_000_000
        let state = makeState([a])
        let first = Task { await state.connect(a) }
        _ = await eventually { state.connectingProviders.contains(a.id) }
        await state.connect(a)
        await first.value
        XCTAssertEqual(a.connectCalls, 1)
    }

    func testALibraryFailureAfterAGoodConnectIsNotAConnectionError() async {
        let a = FakeAdapter(id: "alpha", connected: false)
        a.failsLibrary = true
        let state = makeState([a])
        await state.connect(a)
        XCTAssertTrue(state.connectionErrors.isEmpty)
        XCTAssertEqual(state.errorMessage, "Alpha: fake failure")
    }

    func testADisabledProviderNeverRecordsAnError() async {
        let a = FakeAdapter(id: "alpha", connected: false)
        a.connectError = FakeFailure()
        let state = makeState([a])
        await state.setProvider(a, enabled: false)
        await state.connect(a)
        XCTAssertTrue(state.connectionErrors.isEmpty)
        XCTAssertEqual(a.connectCalls, 0)
    }
}
