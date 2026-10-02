import XCTest
@testable import Bravune

final class SidebarShortcutTests: XCTestCase {
    func testEverySectionHasItsOwnNumberKeyInSidebarOrder() {
        XCTAssertEqual(SidebarSection.allCases.map(\.shortcutKey), ["1", "2", "3", "4", "5"])
        XCTAssertEqual(SidebarSection.library.shortcutKey, "1")
        XCTAssertEqual(SidebarSection.settings.shortcutKey, "5")
    }
}

@MainActor
final class NavigationStateTests: XCTestCase {
    func testSectionStartsOnLibraryAndCanBeSwitched() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("SavedMixes.json")
        let state = AppState(
            adapters: [],
            access: ProviderAccess(defaults: defaults),
            subscription: Subscription(defaults: defaults),
            savedMixes: SavedMixStore(fileURL: file),
            refreshesOnLaunch: false
        )
        XCTAssertEqual(state.section, .library)
        state.section = .queue
        XCTAssertEqual(state.section, .queue)
    }
}

@MainActor
final class SubsonicUnplayableTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func track(_ id: String) -> UnifiedTrack {
        UnifiedTrack(provider: .subsonic, providerTrackId: id, title: "Remote \(id)", artist: "a", album: "b", duration: 1)
    }

    func testNonAudioResponseIsReportedAsUnplayableTrack() async throws {
        let bad = folder.appendingPathComponent("bad.mp3")
        try Data("this is not audio".utf8).write(to: bad)
        let playback = HTTPStreamPlayback { _ in bad }
        do {
            try await playback.load(track("x"))
            XCTFail("expected an error")
        } catch let error as TrackUnplayableError {
            XCTAssertEqual(error.localizedDescription, "Couldn\u{2019}t play \u{201C}Remote x\u{201D}")
        }
    }

    func testRealAudioLoadsWithoutError() async throws {
        let good = folder.appendingPathComponent("good.wav")
        try makeToneFile(at: good, seconds: 1, frequency: 440)
        let playback = HTTPStreamPlayback { _ in good }
        try await playback.load(track("y"))
    }

    func testStreamURLFailureStaysAProviderErrorAndIsNotTreatedAsUnplayable() async {
        struct Boom: Error {}
        let playback = HTTPStreamPlayback { _ in throw Boom() }
        do {
            try await playback.load(track("z"))
            XCTFail("expected an error")
        } catch {
            XCTAssertFalse(error is TrackUnplayableError)
        }
    }
}
