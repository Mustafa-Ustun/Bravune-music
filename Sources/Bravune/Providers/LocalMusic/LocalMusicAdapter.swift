import AppKit
import AVFoundation
import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class LocalMusicAdapter: ProviderAdapter {
    nonisolated static let folderDefaultsKey = "bravune.localMusic.folder"
    nonisolated static let bookmarkDefaultsKey = "bravune.localMusic.folderBookmark"
    nonisolated static let supportedExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "caf"]

    let id = ProviderID.localMusic
    let displayName = "Local Music"

    private(set) var folderURL: URL?
    private let artworkDirectory: URL
    private var scopedURL: URL?

    var isConnected: Bool {
        folderURL != nil
    }

    var connectionDetail: String? {
        folderURL?.path
    }

    nonisolated static func defaultArtworkDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Bravune", isDirectory: true).appendingPathComponent("Artwork", isDirectory: true)
    }

    init(folderURL: URL?, artworkDirectory: URL = LocalMusicAdapter.defaultArtworkDirectory()) {
        self.folderURL = folderURL
        self.artworkDirectory = artworkDirectory
    }

    convenience init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.bookmarkDefaultsKey), let resolved = FolderBookmark.resolve(data) {
            self.init(folderURL: resolved.url)
            if resolved.url.startAccessingSecurityScopedResource() {
                scopedURL = resolved.url
            }
            if resolved.isStale, let fresh = FolderBookmark.make(for: resolved.url) {
                defaults.set(fresh, forKey: Self.bookmarkDefaultsKey)
            }
            return
        }
        let stored = defaults.string(forKey: Self.folderDefaultsKey)
        self.init(folderURL: stored.map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    func connect() async throws {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder that contains your music"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        if url.startAccessingSecurityScopedResource() {
            scopedURL = url
        }
        folderURL = url
        UserDefaults.standard.set(url.path, forKey: Self.folderDefaultsKey)
        if let data = FolderBookmark.make(for: url) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkDefaultsKey)
        }
    }

    func disconnect() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        folderURL = nil
        UserDefaults.standard.removeObject(forKey: Self.folderDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.bookmarkDefaultsKey)
        let directory = artworkDirectory
        Task.detached(priority: .utility) {
            Self.pruneArtwork(in: directory, keeping: [])
        }
    }

    func tracks() async throws -> [UnifiedTrack] {
        guard let folder = folderURL else { return [] }
        let artworkDirectory = artworkDirectory
        let files = await Task.detached(priority: .userInitiated) {
            Self.audioFiles(in: folder)
        }.value
        var result: [UnifiedTrack] = []
        result.reserveCapacity(files.count)
        for file in files {
            result.append(await Self.readTrack(at: file, artworkDirectory: artworkDirectory))
        }
        let kept = Set(result.compactMap(\.artwork).map(\.lastPathComponent))
        await Task.detached(priority: .utility) {
            Self.pruneArtwork(in: artworkDirectory, keeping: kept)
        }.value
        return result.sortedForLibrary()
    }

    func makePlayback() -> any TrackPlayback {
        LocalMusicPlayback()
    }

    nonisolated private static func audioFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where supportedExtensions.contains(url.pathExtension.lowercased()) {
            files.append(url)
        }
        return files
    }

    nonisolated private static func readTrack(at url: URL, artworkDirectory: URL) async -> UnifiedTrack {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let items = (try? await asset.load(.metadata)) ?? []
        let playable = (try? await asset.load(.isPlayable)) ?? false

        func item(_ key: AVMetadataKey) -> AVMetadataItem? {
            items.first { $0.commonKey == key }
        }

        func text(_ key: AVMetadataKey) async -> String? {
            guard let value = try? await item(key)?.load(.stringValue), !value.isEmpty else { return nil }
            return value
        }

        var artworkData = try? await item(.commonKeyArtwork)?.load(.dataValue)
        if artworkData == nil && url.pathExtension.lowercased() == "flac" {
            artworkData = FlacPicture.extract(from: url)
        }

        return UnifiedTrack(
            provider: .localMusic,
            providerTrackId: url.path,
            title: await text(.commonKeyTitle) ?? url.deletingPathExtension().lastPathComponent,
            artist: await text(.commonKeyArtist) ?? "Unknown Artist",
            album: await text(.commonKeyAlbumName) ?? "Unknown Album",
            duration: duration.isFinite ? duration : 0,
            artwork: artworkData.flatMap { storeArtwork($0, in: artworkDirectory) },
            metadata: playable ? [:] : [UnifiedTrack.unplayableKey: "1"]
        )
    }

    nonisolated static func pruneArtwork(in directory: URL, keeping names: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where !names.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    nonisolated private static func storeArtwork(_ data: Data, in directory: URL) -> URL? {
        guard !data.isEmpty else { return nil }
        let name = SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
        let bytes = [UInt8](data.prefix(4))
        let ext: String
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            ext = "png"
        } else if bytes.starts(with: [0xFF, 0xD8]) {
            ext = "jpg"
        } else {
            ext = "img"
        }
        let file = directory.appendingPathComponent("\(name).\(ext)")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }
}
