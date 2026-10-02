import Foundation
import Network

private final class ReadyFlag: @unchecked Sendable {
    var done = false
}

final class MockSpotifyServer: @unchecked Sendable {
    struct Recorded {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data

        var bodyText: String {
            String(data: body, encoding: .utf8) ?? ""
        }
    }

    struct Device {
        let id: String
        let active: Bool
        let name: String
        let type: String
    }

    private let listener: NWListener
    private let lock = NSLock()
    private var recorded: [Recorded] = []
    private var issuedTokens: Set<String> = []
    private var tokenCounter = 0
    private var unauthorizedOnce: Set<String> = []
    private var rateLimitedOnce: Set<String> = []
    private(set) var port: UInt16 = 0

    var likedSongTotal = 0
    var localTrackIndexes: Set<Int> = []
    var nullTrackIndexes: Set<Int> = []
    var devices: [Device] = [Device(id: "device-mac", active: true, name: "This Mac", type: "Computer")]
    var playerStateJSON: String?
    var playFailure: (status: Int, body: String)?
    var tracksFailure: (status: Int, body: String)?
    var tokenFailure: (status: Int, body: String)?
    var tokenLifetime = 3600

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(connection, buffer: Data())
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let flag = ReadyFlag()
            listener.stateUpdateHandler = { [weak self] state in
                guard !flag.done else { return }
                switch state {
                case .ready:
                    flag.done = true
                    self?.port = self?.listener.port?.rawValue ?? 0
                    continuation.resume()
                case .failed(let error):
                    flag.done = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() {
        listener.cancel()
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    var requests: [Recorded] {
        lock.withLock { recorded }
    }

    func requests(_ method: String, _ path: String) -> [Recorded] {
        requests.filter { $0.method == method && $0.path == path }
    }

    func failOnce(unauthorized path: String) {
        lock.withLock { _ = unauthorizedOnce.insert(path) }
    }

    func failOnce(rateLimited path: String) {
        lock.withLock { _ = rateLimitedOnce.insert(path) }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        if buffer.isEmpty {
            connection.start(queue: .global())
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, let data else {
                connection.cancel()
                return
            }
            let all = buffer + data
            guard let split = all.range(of: Data("\r\n\r\n".utf8)) else {
                self.receive(connection, buffer: all)
                return
            }
            let head = String(data: all[..<split.lowerBound], encoding: .utf8) ?? ""
            let body = all[split.upperBound...]
            let length = head.components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
            if body.count < length {
                self.receive(connection, buffer: all)
                return
            }
            self.route(head: head, body: Data(body), on: connection)
        }
    }

    private func route(head: String, body: Data, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ").map(String.init) ?? []
        guard parts.count >= 2, let components = URLComponents(string: "http://127.0.0.1" + parts[1]) else {
            send(connection, status: 400, body: "")
            return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let query = Dictionary(components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { first, _ in first })
        let request = Recorded(method: parts[0], path: components.path, query: query, headers: headers, body: body)
        lock.withLock { recorded.append(request) }

        if request.path == "/api/token" {
            handleToken(request, connection)
            return
        }
        guard authorized(request) else {
            send(connection, status: 401, body: #"{"error":{"status":401,"message":"Invalid access token"}}"#)
            return
        }
        if let injected = injectedFailure(for: request.path) {
            send(connection, status: injected.status, body: injected.body, extra: injected.extra)
            return
        }
        switch (request.method, request.path) {
        case ("GET", "/v1/me"):
            send(connection, status: 200, body: #"{"display_name":"Test User","id":"tester"}"#)
        case ("GET", "/v1/me/tracks"):
            if let failure = tracksFailure {
                send(connection, status: failure.status, body: failure.body)
            } else {
                send(connection, status: 200, body: likedSongsPage(query))
            }
        case ("GET", "/v1/me/player/devices"):
            let list = devices.map { #"{"id":"\#($0.id)","is_active":\#($0.active),"name":"\#($0.name)","type":"\#($0.type)"}"# }
            send(connection, status: 200, body: #"{"devices":[\#(list.joined(separator: ","))]}"#)
        case ("GET", "/v1/me/player"):
            if let json = playerStateJSON {
                send(connection, status: 200, body: json)
            } else {
                send(connection, status: 204, body: "")
            }
        case ("PUT", "/v1/me/player/play"):
            if let failure = playFailure {
                send(connection, status: failure.status, body: failure.body)
            } else {
                send(connection, status: 204, body: "")
            }
        case ("PUT", "/v1/me/player/pause"), ("PUT", "/v1/me/player/seek"), ("PUT", "/v1/me/player/volume"):
            send(connection, status: 204, body: "")
        default:
            send(connection, status: 404, body: #"{"error":{"status":404,"message":"Not found"}}"#)
        }
    }

    private func handleToken(_ request: Recorded, _ connection: NWConnection) {
        if let failure = tokenFailure {
            send(connection, status: failure.status, body: failure.body)
            return
        }
        let fields = Dictionary(request.bodyText.split(separator: "&").compactMap { pair -> (String, String)? in
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return kv.count == 2 ? (kv[0], kv[1].removingPercentEncoding ?? kv[1]) : nil
        }, uniquingKeysWith: { first, _ in first })
        guard fields["grant_type"] == "refresh_token", fields["refresh_token"] == "refresh-1", fields["client_id"] == "client" else {
            send(connection, status: 400, body: #"{"error":"invalid_grant","error_description":"Invalid refresh token"}"#)
            return
        }
        let token: String = lock.withLock {
            tokenCounter += 1
            let value = "tok-\(tokenCounter)"
            issuedTokens.insert(value)
            return value
        }
        send(connection, status: 200, body: #"{"access_token":"\#(token)","token_type":"Bearer","expires_in":\#(tokenLifetime)}"#)
    }

    private func authorized(_ request: Recorded) -> Bool {
        guard let header = request.headers["authorization"], header.hasPrefix("Bearer ") else { return false }
        let token = String(header.dropFirst("Bearer ".count))
        return lock.withLock { issuedTokens.contains(token) }
    }

    private func injectedFailure(for path: String) -> (status: Int, body: String, extra: String)? {
        lock.withLock {
            if unauthorizedOnce.remove(path) != nil {
                return (401, #"{"error":{"status":401,"message":"The access token expired"}}"#, "")
            }
            if rateLimitedOnce.remove(path) != nil {
                return (429, #"{"error":{"status":429,"message":"Rate limited"}}"#, "Retry-After: 0\r\n")
            }
            return nil
        }
    }

    private func likedSongsPage(_ query: [String: String]) -> String {
        let limit = Int(query["limit"] ?? "20") ?? 20
        let offset = Int(query["offset"] ?? "0") ?? 0
        let end = min(offset + limit, likedSongTotal)
        let items = (offset..<max(offset, end)).map { index -> String in
            if nullTrackIndexes.contains(index) {
                return #"{"track":null}"#
            }
            if localTrackIndexes.contains(index) {
                return #"{"track":{"id":null,"name":"Local file \#(index)","artists":[{"name":"Nobody"}],"album":{"name":"Local","images":[]},"duration_ms":1000,"is_local":true}}"#
            }
            return #"{"track":{"id":"track\#(index)","name":"Song \#(index)","artists":[{"name":"Artist \#(index)"},{"name":"Guest"}],"album":{"name":"Album \#(index)","images":[{"url":"https://img/640/\#(index)","width":640},{"url":"https://img/300/\#(index)","width":300},{"url":"https://img/64/\#(index)","width":64}]},"duration_ms":200000,"is_local":false}}"#
        }
        let next = end < likedSongTotal ? #""https://api.spotify.com/v1/me/tracks?offset=\#(end)""# : "null"
        return #"{"total":\#(likedSongTotal),"next":\#(next),"items":[\#(items.joined(separator: ","))]}"#
    }

    private func send(_ connection: NWConnection, status: Int, body: String, extra: String = "") {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 429: "Too Many Requests", 500: "Internal Server Error"][status] ?? "Status"
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\n\(extra)Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
