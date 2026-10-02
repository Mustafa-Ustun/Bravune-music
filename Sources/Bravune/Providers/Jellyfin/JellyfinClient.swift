import Foundation

struct JellyfinSession: Equatable {
    var serverURL: URL
    var userId: String
    var username: String
    var accessToken: String
}

enum JellyfinError: LocalizedError {
    case invalidURL
    case notConnected
    case invalidLogin
    case sessionExpired
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The server address is not valid"
        case .notConnected: "Not connected to a server"
        case .invalidLogin: "Wrong username or password"
        case .sessionExpired: "The server no longer accepts this login. Connect again."
        case .badStatus(let code): "The server answered with status \(code)"
        }
    }
}

struct JellyfinItem: Decodable, Equatable {
    let id: String
    let name: String
    let artists: [String]?
    let albumArtist: String?
    let album: String?
    let runTimeTicks: Int64?
    let albumId: String?
    let imageTags: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case artists = "Artists"
        case albumArtist = "AlbumArtist"
        case album = "Album"
        case runTimeTicks = "RunTimeTicks"
        case albumId = "AlbumId"
        case imageTags = "ImageTags"
    }

    var duration: TimeInterval {
        TimeInterval(runTimeTicks ?? 0) / 10_000_000
    }

    var displayArtist: String {
        artists?.first ?? albumArtist ?? "Unknown Artist"
    }
}

struct JellyfinItemsPage: Decodable {
    let items: [JellyfinItem]
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

private struct JellyfinAuthResult: Decodable {
    struct User: Decodable {
        let id: String
        let name: String

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
        }
    }

    let accessToken: String
    let user: User

    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case user = "User"
    }
}

struct JellyfinClient {
    static let pageSize = 500

    let session: JellyfinSession
    let deviceId: String
    var urlSession: URLSession = .shared

    static func authorizationHeader(deviceId: String, token: String?) -> String {
        var value = "MediaBrowser Client=\"Bravune\", Device=\"Mac\", DeviceId=\"\(deviceId)\", Version=\"1.0\""
        if let token {
            value += ", Token=\"\(token)\""
        }
        return value
    }

    static func authenticate(
        serverURL: URL,
        username: String,
        password: String,
        deviceId: String,
        urlSession: URLSession = .shared
    ) async throws -> JellyfinSession {
        var request = URLRequest(url: serverURL.appendingPathComponent("Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorizationHeader(deviceId: deviceId, token: nil), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw JellyfinError.invalidLogin }
            if !(200..<300).contains(http.statusCode) { throw JellyfinError.badStatus(http.statusCode) }
        }
        let result = try JSONDecoder().decode(JellyfinAuthResult.self, from: data)
        return JellyfinSession(serverURL: serverURL, userId: result.user.id, username: result.user.name, accessToken: result.accessToken)
    }

    func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        let base = session.serverURL.appendingPathComponent(path)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw JellyfinError.invalidURL
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else { throw JellyfinError.invalidURL }
        return url
    }

    func streamURL(id: String) throws -> URL {
        try url("Audio/\(id)/universal", query: [
            URLQueryItem(name: "UserId", value: session.userId),
            URLQueryItem(name: "DeviceId", value: deviceId),
            URLQueryItem(name: "api_key", value: session.accessToken),
            URLQueryItem(name: "Container", value: "mp3,aac,m4a,m4b,flac,wav,aiff"),
            URLQueryItem(name: "AudioCodec", value: "mp3,aac,flac,alac"),
            URLQueryItem(name: "TranscodingContainer", value: "mp3"),
            URLQueryItem(name: "TranscodingProtocol", value: "http")
        ])
    }

    func imageURL(for item: JellyfinItem) -> URL? {
        let source = item.imageTags?["Primary"] != nil ? item.id : item.albumId
        guard let source else { return nil }
        return try? url("Items/\(source)/Images/Primary", query: [URLQueryItem(name: "maxWidth", value: "300")])
    }

    func allSongs() async throws -> [JellyfinItem] {
        var songs: [JellyfinItem] = []
        var start = 0
        while true {
            let page = try await request("Items", query: [
                URLQueryItem(name: "userId", value: session.userId),
                URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "StartIndex", value: String(start)),
                URLQueryItem(name: "Limit", value: String(Self.pageSize))
            ])
            songs += page.items
            start += page.items.count
            if page.items.isEmpty || page.items.count < Self.pageSize { break }
            if let total = page.totalRecordCount, start >= total { break }
        }
        return songs
    }

    static func decodePage(_ data: Data) throws -> JellyfinItemsPage {
        try JSONDecoder().decode(JellyfinItemsPage.self, from: data)
    }

    private func request(_ path: String, query: [URLQueryItem]) async throws -> JellyfinItemsPage {
        var request = URLRequest(url: try url(path, query: query))
        request.setValue(Self.authorizationHeader(deviceId: deviceId, token: session.accessToken), forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { throw JellyfinError.sessionExpired }
            if !(200..<300).contains(http.statusCode) { throw JellyfinError.badStatus(http.statusCode) }
        }
        return try Self.decodePage(data)
    }
}
