import Foundation

struct SpotifyTrack: Decodable {
    struct Artist: Decodable {
        let name: String
    }

    struct Image: Decodable {
        let url: String
        let width: Int?
    }

    struct Album: Decodable {
        let name: String
        let images: [Image]
    }

    let id: String?
    let name: String
    let artists: [Artist]
    let album: Album
    let duration_ms: Int
    let is_local: Bool?
}

struct SpotifySavedPage: Decodable {
    struct Item: Decodable {
        let track: SpotifyTrack?
    }

    let items: [Item]
    let next: String?
}

struct SpotifyDevice: Decodable {
    let id: String?
    let is_active: Bool
    let name: String
    let type: String
}

struct SpotifyPlayerState: Decodable {
    struct Item: Decodable {
        let id: String?
    }

    let is_playing: Bool
    let progress_ms: Int?
    let item: Item?
}

@MainActor
final class SpotifyAPI {
    static let pageSize = 50
    nonisolated static let defaultBaseURL = URL(string: "https://api.spotify.com/v1")!

    let session: SpotifySession
    private let baseURL: URL

    init(session: SpotifySession, baseURL: URL = SpotifyAPI.defaultBaseURL) {
        self.session = session
        self.baseURL = baseURL
    }

    func displayName() async throws -> String? {
        struct Profile: Decodable {
            let display_name: String?
        }
        let (data, _) = try await send("GET", "/me")
        return try JSONDecoder().decode(Profile.self, from: data).display_name
    }

    func savedTracks() async throws -> [SpotifyTrack] {
        var tracks: [SpotifyTrack] = []
        var offset = 0
        while true {
            let (data, _) = try await send("GET", "/me/tracks", query: [
                URLQueryItem(name: "limit", value: String(Self.pageSize)),
                URLQueryItem(name: "offset", value: String(offset))
            ])
            let page = try JSONDecoder().decode(SpotifySavedPage.self, from: data)
            tracks += page.items.compactMap(\.track)
            if page.next == nil || page.items.isEmpty { break }
            offset += page.items.count
        }
        return tracks
    }

    func pickDevice() async throws -> String {
        struct Devices: Decodable {
            let devices: [SpotifyDevice]
        }
        let (data, _) = try await send("GET", "/me/player/devices")
        let devices = try JSONDecoder().decode(Devices.self, from: data).devices.filter { $0.id != nil }
        let chosen = devices.first { $0.is_active } ?? devices.first { $0.type == "Computer" } ?? devices.first
        guard let id = chosen?.id else { throw SpotifyError.noDevice }
        return id
    }

    func play(uri: String, deviceID: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["uris": [uri]])
        _ = try await send("PUT", "/me/player/play", query: [URLQueryItem(name: "device_id", value: deviceID)], body: body)
    }

    func resume(deviceID: String) async throws {
        _ = try await send("PUT", "/me/player/play", query: [URLQueryItem(name: "device_id", value: deviceID)])
    }

    func pause(deviceID: String) async throws {
        _ = try await send("PUT", "/me/player/pause", query: [URLQueryItem(name: "device_id", value: deviceID)])
    }

    func seek(to milliseconds: Int, deviceID: String) async throws {
        _ = try await send("PUT", "/me/player/seek", query: [
            URLQueryItem(name: "position_ms", value: String(milliseconds)),
            URLQueryItem(name: "device_id", value: deviceID)
        ])
    }

    func setVolume(percent: Int, deviceID: String) async throws {
        _ = try await send("PUT", "/me/player/volume", query: [
            URLQueryItem(name: "volume_percent", value: String(percent)),
            URLQueryItem(name: "device_id", value: deviceID)
        ])
    }

    func playerState() async throws -> SpotifyPlayerState? {
        let (data, response) = try await send("GET", "/me/player")
        if response.statusCode == 204 || data.isEmpty { return nil }
        return try JSONDecoder().decode(SpotifyPlayerState.self, from: data)
    }

    private func send(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        retry: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(string: baseURL.absoluteString + path)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(try await session.accessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpotifyError.api("Invalid answer from Spotify") }
        if retry, http.statusCode == 401 {
            session.invalidateAccessToken()
            return try await send(method, path, query: query, body: body, retry: false)
        }
        if retry, http.statusCode == 429 {
            let wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1
            try await Task.sleep(nanoseconds: UInt64(min(wait, 30) * 1_000_000_000))
            return try await send(method, path, query: query, body: body, retry: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SpotifyError.api(Self.failureMessage(data: data, status: http.statusCode))
        }
        return (data, http)
    }

    static func failureMessage(data: Data, status: Int) -> String {
        struct Failure: Decodable {
            struct Body: Decodable {
                let message: String?
                let reason: String?
            }
            let error: Body
        }
        guard let failure = try? JSONDecoder().decode(Failure.self, from: data) else {
            return "Spotify request failed (\(status))"
        }
        if failure.error.reason == "PREMIUM_REQUIRED" {
            return "Spotify Premium is required for playback"
        }
        return failure.error.message ?? "Spotify request failed (\(status))"
    }
}
