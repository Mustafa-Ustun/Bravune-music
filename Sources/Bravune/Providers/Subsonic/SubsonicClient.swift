import CryptoKit
import Foundation

struct SubsonicCredentials: Equatable {
    var serverURL: URL
    var username: String
    var password: String
}

enum SubsonicError: LocalizedError {
    case invalidURL
    case notConnected
    case badStatus(Int)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The server address is not valid"
        case .notConnected: "Not connected to a server"
        case .badStatus(let code): "The server answered with status \(code)"
        case .server(let message): message
        }
    }
}

struct SubsonicSong: Decodable, Equatable {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    let duration: Int?
    let coverArt: String?
}

struct SubsonicResponse: Decodable {
    struct ErrorBody: Decodable {
        let message: String?
    }

    struct SearchResult: Decodable {
        let song: [SubsonicSong]?
    }

    let status: String
    let error: ErrorBody?
    let searchResult3: SearchResult?
}

private struct SubsonicEnvelope: Decodable {
    let response: SubsonicResponse

    enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

struct SubsonicClient {
    static let pageSize = 500

    let credentials: SubsonicCredentials

    func url(_ endpoint: String, query: [URLQueryItem] = [], salt: String = Self.randomSalt()) throws -> URL {
        let token = Insecure.MD5.hash(data: Data((credentials.password + salt).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let base = credentials.serverURL.appendingPathComponent("rest/\(endpoint).view")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw SubsonicError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "u", value: credentials.username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "Bravune"),
            URLQueryItem(name: "f", value: "json")
        ] + query
        guard let url = components.url else { throw SubsonicError.invalidURL }
        return url
    }

    func streamURL(id: String) throws -> URL {
        try url("stream", query: [URLQueryItem(name: "id", value: id)])
    }

    func coverArtURL(id: String) -> URL? {
        try? url("getCoverArt", query: [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "size", value: "300")
        ])
    }

    func ping() async throws {
        _ = try await request("ping")
    }

    func allSongs() async throws -> [SubsonicSong] {
        var songs: [SubsonicSong] = []
        var offset = 0
        while true {
            let response = try await request("search3", query: [
                URLQueryItem(name: "query", value: ""),
                URLQueryItem(name: "artistCount", value: "0"),
                URLQueryItem(name: "albumCount", value: "0"),
                URLQueryItem(name: "songCount", value: String(Self.pageSize)),
                URLQueryItem(name: "songOffset", value: String(offset))
            ])
            let batch = response.searchResult3?.song ?? []
            songs += batch
            if batch.count < Self.pageSize { break }
            offset += batch.count
        }
        return songs
    }

    static func decode(_ data: Data) throws -> SubsonicResponse {
        let response = try JSONDecoder().decode(SubsonicEnvelope.self, from: data).response
        guard response.status == "ok" else {
            throw SubsonicError.server(response.error?.message ?? "The server rejected the request")
        }
        return response
    }

    private func request(_ endpoint: String, query: [URLQueryItem] = []) async throws -> SubsonicResponse {
        let (data, response) = try await URLSession.shared.data(from: url(endpoint, query: query))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SubsonicError.badStatus(http.statusCode)
        }
        return try Self.decode(data)
    }

    private static func randomSalt() -> String {
        String((0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    }
}
