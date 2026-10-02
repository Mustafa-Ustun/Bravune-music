import Foundation

struct ProviderID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let localMusic = ProviderID(rawValue: "local_music")
    static let spotify = ProviderID(rawValue: "spotify")
    static let subsonic = ProviderID(rawValue: "subsonic")
    static let appleMusic = ProviderID(rawValue: "apple_music")
}
