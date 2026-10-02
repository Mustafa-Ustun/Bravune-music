import Foundation
import Observation

struct SavedMix: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var request: MixRequest
    let createdAt: Date
}

@MainActor
@Observable
final class SavedMixStore {
    private(set) var mixes: [SavedMix] = []

    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = SavedMixStore.defaultFileURL()) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([SavedMix].self, from: data) {
            mixes = decoded
        }
    }

    nonisolated static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Bravune", isDirectory: true).appendingPathComponent("SavedMixes.json")
    }

    @discardableResult
    func add(name: String, request: MixRequest) throws -> SavedMix {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let mix = SavedMix(id: UUID(), name: trimmed.isEmpty ? "Untitled Mix" : trimmed, request: request, createdAt: Date())
        mixes.append(mix)
        try persist()
        return mix
    }

    func rename(_ id: SavedMix.ID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = mixes.firstIndex(where: { $0.id == id }) else { return }
        mixes[index].name = trimmed
        try persist()
    }

    func remove(_ id: SavedMix.ID) throws {
        mixes.removeAll { $0.id == id }
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(mixes).write(to: fileURL, options: .atomic)
    }
}
