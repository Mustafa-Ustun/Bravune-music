import XCTest
@testable import Bravune

@MainActor
final class ArtworkCacheTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
    private var artworkDirectory: URL!

    override func setUp() async throws {
        artworkDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: artworkDirectory)
    }

    private func files() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: artworkDirectory.path))
    }

    private func adapter() -> LocalMusicAdapter {
        LocalMusicAdapter(folderURL: fixtures.appendingPathComponent("Music", isDirectory: true), artworkDirectory: artworkDirectory)
    }

    func testScanRemovesArtworkNoTrackUsesAnymore() async throws {
        try Data("stale".utf8).write(to: artworkDirectory.appendingPathComponent("stale-one.jpg"))
        try Data("stale".utf8).write(to: artworkDirectory.appendingPathComponent("stale-two.png"))
        let tracks = try await adapter().tracks()
        let used = Set(tracks.compactMap(\.artwork).map(\.lastPathComponent))
        XCTAssertFalse(used.isEmpty)
        XCTAssertEqual(try files(), used)
    }

    func testScanKeepsEveryArtworkFileTheLibraryStillShows() async throws {
        let first = try await adapter().tracks()
        let second = try await adapter().tracks()
        let used = Set(second.compactMap(\.artwork).map(\.lastPathComponent))
        XCTAssertEqual(Set(first.compactMap(\.artwork)), Set(second.compactMap(\.artwork)))
        XCTAssertEqual(try files(), used)
        for url in second.compactMap(\.artwork) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testScanOfAnEmptyFolderClearsTheCache() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        _ = try await adapter().tracks()
        XCTAssertFalse(try files().isEmpty)
        let other = LocalMusicAdapter(folderURL: empty, artworkDirectory: artworkDirectory)
        _ = try await other.tracks()
        XCTAssertTrue(try files().isEmpty)
    }

    func testDisconnectClearsTheCache() async throws {
        let local = adapter()
        _ = try await local.tracks()
        XCTAssertFalse(try files().isEmpty)
        local.disconnect()
        let cleared = await eventually { (try? self.files().isEmpty) == true }
        XCTAssertTrue(cleared)
    }

    func testPruningAMissingDirectoryDoesNotCrash() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        LocalMusicAdapter.pruneArtwork(in: missing, keeping: [])
    }
}
