import Foundation

@MainActor
protocol ProviderAdapter: AnyObject {
    var id: ProviderID { get }
    var displayName: String { get }
    var isConnected: Bool { get }
    var connectionDetail: String? { get }

    func connect() async throws
    func disconnect()
    func tracks() async throws -> [UnifiedTrack]
    func makePlayback() -> any TrackPlayback
}
