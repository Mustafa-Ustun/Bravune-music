import XCTest
@testable import Bravune

@MainActor
final class FolderBookmarkTests: XCTestCase {
    private func makeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bookmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testBookmarkRoundTripsToTheSameFolder() throws {
        let dir = try makeFolder()
        let data = try XCTUnwrap(FolderBookmark.make(for: dir))
        let resolved = try XCTUnwrap(FolderBookmark.resolve(data))
        XCTAssertEqual(resolved.url.resolvingSymlinksInPath().path, dir.resolvingSymlinksInPath().path)
        XCTAssertFalse(resolved.isStale)
    }

    func testGarbageDataDoesNotResolve() {
        XCTAssertNil(FolderBookmark.resolve(Data([1, 2, 3])))
    }

    func testAdapterRestoresFolderFromBookmarkAndClearsItOnDisconnect() throws {
        let dir = try makeFolder()
        let defaults = UserDefaults.standard
        let previousPath = defaults.string(forKey: LocalMusicAdapter.folderDefaultsKey)
        let previousBookmark = defaults.data(forKey: LocalMusicAdapter.bookmarkDefaultsKey)
        addTeardownBlock {
            defaults.set(previousPath, forKey: LocalMusicAdapter.folderDefaultsKey)
            defaults.set(previousBookmark, forKey: LocalMusicAdapter.bookmarkDefaultsKey)
        }
        defaults.removeObject(forKey: LocalMusicAdapter.folderDefaultsKey)
        defaults.set(try XCTUnwrap(FolderBookmark.make(for: dir)), forKey: LocalMusicAdapter.bookmarkDefaultsKey)

        let adapter = LocalMusicAdapter()
        XCTAssertTrue(adapter.isConnected)
        XCTAssertEqual(adapter.folderURL?.resolvingSymlinksInPath().path, dir.resolvingSymlinksInPath().path)

        adapter.disconnect()
        XCTAssertNil(defaults.data(forKey: LocalMusicAdapter.bookmarkDefaultsKey))
        XCTAssertFalse(adapter.isConnected)
    }
}
