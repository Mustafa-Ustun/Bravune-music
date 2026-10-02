import XCTest
@testable import Bravune

@MainActor
final class LocalMetadataTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
    private var artworkDirectory: URL!

    override func setUp() async throws {
        artworkDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: artworkDirectory)
    }

    private func scan() async throws -> [UnifiedTrack] {
        let adapter = LocalMusicAdapter(folderURL: fixtures.appendingPathComponent("Music", isDirectory: true), artworkDirectory: artworkDirectory)
        return try await adapter.tracks()
    }

    private func track(_ title: String, in tracks: [UnifiedTrack]) throws -> UnifiedTrack {
        try XCTUnwrap(tracks.first { $0.title == title }, "no track titled \(title)")
    }

    func testScanFindsOnlyAudioFilesIncludingSubfolders() async throws {
        let tracks = try await scan()
        XCTAssertEqual(Set(tracks.map(\.title)), ["Fixture MP3", "Fixture M4A", "Fixture FLAC", "untagged", "broken"])
    }

    func testMP3TagsAreRead() async throws {
        let item = try track("Fixture MP3", in: await scan())
        XCTAssertEqual(item.artist, "Fixture Artist MP3")
        XCTAssertEqual(item.album, "Fixture Album MP3")
        XCTAssertEqual(item.duration, 1, accuracy: 0.2)
    }

    func testM4ATagsAreRead() async throws {
        let item = try track("Fixture M4A", in: await scan())
        XCTAssertEqual(item.artist, "Fixture Artist M4A")
        XCTAssertEqual(item.album, "Fixture Album M4A")
        XCTAssertEqual(item.duration, 1, accuracy: 0.2)
    }

    func testFLACTagsAreRead() async throws {
        let item = try track("Fixture FLAC", in: await scan())
        XCTAssertEqual(item.artist, "Fixture Artist FLAC")
        XCTAssertEqual(item.album, "Fixture Album FLAC")
        XCTAssertEqual(item.duration, 1, accuracy: 0.2)
    }

    func testUntaggedWAVFallsBackToFilenameAndUnknownValues() async throws {
        let item = try track("untagged", in: await scan())
        XCTAssertEqual(item.artist, "Unknown Artist")
        XCTAssertEqual(item.album, "Unknown Album")
        XCTAssertNil(item.artwork)
        XCTAssertEqual(item.duration, 1, accuracy: 0.2)
    }

    func testCorruptFileIsStillListedWithFallbacksAndNoArtwork() async throws {
        let item = try track("broken", in: await scan())
        XCTAssertEqual(item.artist, "Unknown Artist")
        XCTAssertNil(item.artwork)
        XCTAssertLessThan(item.duration, 1)
    }

    func testEveryGoodFixtureLoadsInTheRealLocalPlayerAndTheCorruptOneIsUnplayable() async throws {
        let tracks = try await scan()
        for title in ["Fixture MP3", "Fixture M4A", "Fixture FLAC", "untagged"] {
            let playback = LocalMusicPlayback()
            try await playback.load(try track(title, in: tracks))
            playback.stop()
        }
        let playback = LocalMusicPlayback()
        do {
            try await playback.load(try track("broken", in: tracks))
            XCTFail("expected the corrupt file to be unplayable")
        } catch {
            XCTAssertTrue(error is TrackUnplayableError, "\(error)")
            XCTAssertEqual(error.localizedDescription, "Couldn\u{2019}t play \u{201C}broken\u{201D}")
        }
    }

    func testEmbeddedArtworkIsExtractedForMP3M4AAndFLAC() async throws {
        let source = try Data(contentsOf: fixtures.appendingPathComponent("cover.png"))
        let tracks = try await scan()
        for title in ["Fixture MP3", "Fixture M4A", "Fixture FLAC"] {
            let url = try XCTUnwrap(try track(title, in: tracks).artwork, "\(title) has no artwork")
            XCTAssertTrue(url.isFileURL)
            XCTAssertTrue(url.path.hasPrefix(artworkDirectory.path))
            XCTAssertEqual(url.pathExtension, "png")
            XCTAssertEqual(try Data(contentsOf: url), source, "\(title) artwork bytes differ")
        }
    }

    func testIdenticalArtworkIsStoredOnceAndReusedAcrossScans() async throws {
        let first = try await scan()
        let second = try await scan()
        let urls = Set((first + second).compactMap(\.artwork))
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: artworkDirectory.path).count, 1)
    }

    func testMetadataFixesDoNotChangeTrackIdentity() async throws {
        let item = try track("Fixture FLAC", in: await scan())
        XCTAssertEqual(item.provider, .localMusic)
        XCTAssertTrue(item.providerTrackId.hasSuffix("Sub/tagged.flac"))
        XCTAssertEqual(item.id, "local_music:\(item.providerTrackId)")
    }
}

final class FlacPictureTests: XCTestCase {
    private func be32(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private func pictureBlock(type: Int, payload: [UInt8], mime: String = "image/png", description: String = "cover") -> [UInt8] {
        be32(type) + be32(mime.utf8.count) + Array(mime.utf8) + be32(description.utf8.count) + Array(description.utf8)
            + be32(64) + be32(64) + be32(24) + be32(0) + be32(payload.count) + payload
    }

    private func metadataBlock(type: UInt8, body: [UInt8], last: Bool) -> [UInt8] {
        [type | (last ? 0x80 : 0), UInt8((body.count >> 16) & 0xFF), UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)] + body
    }

    private func write(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".flac")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testParsePictureReturnsTypeAndData() {
        let block = Data(pictureBlock(type: 3, payload: [1, 2, 3, 4]))
        let parsed = FlacPicture.parsePicture(block)
        XCTAssertEqual(parsed?.type, 3)
        XCTAssertEqual(parsed?.data, Data([1, 2, 3, 4]))
    }

    func testParsePictureRejectsTruncatedAndEmptyBlocks() {
        let block = pictureBlock(type: 3, payload: [1, 2, 3, 4])
        XCTAssertNil(FlacPicture.parsePicture(Data(block.dropLast(2))))
        XCTAssertNil(FlacPicture.parsePicture(Data(block.prefix(10))))
        XCTAssertNil(FlacPicture.parsePicture(Data()))
        XCTAssertNil(FlacPicture.parsePicture(Data(pictureBlock(type: 3, payload: []))))
    }

    func testFrontCoverIsPreferredOverAnEarlierPicture() throws {
        let bytes = Array("fLaC".utf8)
            + metadataBlock(type: 0, body: [UInt8](repeating: 0, count: 34), last: false)
            + metadataBlock(type: 6, body: pictureBlock(type: 0, payload: [9, 9]), last: false)
            + metadataBlock(type: 6, body: pictureBlock(type: 3, payload: [7, 7, 7]), last: true)
        XCTAssertEqual(FlacPicture.extract(from: try write(bytes)), Data([7, 7, 7]))
    }

    func testAnyPictureIsUsedWhenThereIsNoFrontCover() throws {
        let bytes = Array("fLaC".utf8)
            + metadataBlock(type: 0, body: [UInt8](repeating: 0, count: 34), last: false)
            + metadataBlock(type: 6, body: pictureBlock(type: 0, payload: [5, 5]), last: true)
        XCTAssertEqual(FlacPicture.extract(from: try write(bytes)), Data([5, 5]))
    }

    func testFilesWithoutPicturesOrWithBadHeadersReturnNil() throws {
        let noPicture = Array("fLaC".utf8) + metadataBlock(type: 0, body: [UInt8](repeating: 0, count: 34), last: true)
        XCTAssertNil(FlacPicture.extract(from: try write(noPicture)))
        XCTAssertNil(FlacPicture.extract(from: try write(Array("RIFFxxxx".utf8))))
        XCTAssertNil(FlacPicture.extract(from: try write([])))
        XCTAssertNil(FlacPicture.extract(from: URL(fileURLWithPath: "/nonexistent/file.flac")))
    }

    func testDeclaredLengthBeyondTheFileDoesNotCrash() throws {
        let bytes = Array("fLaC".utf8) + [0x06, 0x7F, 0xFF, 0xFF] + [1, 2, 3]
        XCTAssertNil(FlacPicture.extract(from: try write(bytes)))
    }
}

@MainActor
final class UnplayableLibraryTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)

    private func scan() async throws -> [UnifiedTrack] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = LocalMusicAdapter(folderURL: fixtures.appendingPathComponent("Music", isDirectory: true), artworkDirectory: directory)
        return try await adapter.tracks()
    }

    func testOnlyTheCorruptFileIsMarkedUnplayable() async throws {
        let tracks = try await scan()
        XCTAssertEqual(Set(tracks.filter(\.isUnplayable).map(\.title)), ["broken"])
        XCTAssertEqual(tracks.filter { !$0.isUnplayable }.count, tracks.count - 1)
    }

    func testMarkingMatchesWhatTheRealPlayerCanOpen() async throws {
        for track in try await scan() {
            let playback = LocalMusicPlayback()
            var opened = true
            do { try await playback.load(track) } catch { opened = false }
            XCTAssertEqual(opened, !track.isUnplayable, "\(track.title)")
        }
    }

    func testMixNeverPicksAnUnplayableTrack() throws {
        let local = ProviderID.localMusic
        var tracks = (0..<20).map {
            UnifiedTrack(provider: local, providerTrackId: "\($0)", title: "t\($0)", artist: "a\($0 % 3)", album: "b", duration: 100)
        }
        for index in 0..<5 {
            tracks[index].metadata[UnifiedTrack.unplayableKey] = "1"
        }
        let bad = Set(tracks.filter(\.isUnplayable).map(\.id))
        let request = MixRequest(providers: [local], trackCount: 15)
        let result = try MixEngine().mix(request, from: tracks)
        XCTAssertFalse(result.tracks.isEmpty)
        XCTAssertTrue(result.tracks.allSatisfy { !bad.contains($0.id) })
    }
}
