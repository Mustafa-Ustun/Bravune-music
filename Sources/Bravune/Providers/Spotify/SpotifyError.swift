import Foundation

enum SpotifyError: LocalizedError {
    case notConnected
    case noDevice
    case timedOut
    case auth(String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to Spotify"
        case .noDevice: "Open the Spotify app on this Mac and try again"
        case .timedOut: "Spotify sign-in timed out"
        case .auth(let message), .api(let message): message
        }
    }
}
