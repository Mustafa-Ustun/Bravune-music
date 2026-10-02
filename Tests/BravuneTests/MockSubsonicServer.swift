import AVFoundation
import CryptoKit
import Foundation
import Network

func makeToneFile(at url: URL, seconds: Double, frequency: Double) throws {
    let rate = 44_100.0
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for index in 0..<Int(frames) {
        buffer.floatChannelData![0][index] = Float(sin(2 * Double.pi * frequency * Double(index) / rate)) * 0.2
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

private final class ResumeFlag: @unchecked Sendable {
    var done = false
}

final class MockSubsonicServer: @unchecked Sendable {
    struct Song {
        let id: String
        let title: String
        let artist: String
        let album: String
        let duration: Int
    }

    let user = "joe"
    let password = "sesame"
    let songs: [Song]
    private let audio: Data
    private let listener: NWListener
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var recorded: [String] = []

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    init(songs: [Song], audio: Data) throws {
        self.songs = songs
        self.audio = audio
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = ResumeFlag()
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed.done else { return }
                switch state {
                case .ready:
                    resumed.done = true
                    self?.port = self?.listener.port?.rawValue ?? 0
                    continuation.resume()
                case .failed(let error):
                    resumed.done = true
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

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            self.respond(to: text, on: connection)
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        lock.lock()
        recorded.append(target)
        lock.unlock()
        guard let components = URLComponents(string: "http://127.0.0.1" + target) else {
            send(connection, status: "400 Bad Request", contentType: "text/plain", body: Data())
            return
        }
        let query = Dictionary(components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { first, _ in first })
        guard authorized(query) else {
            send(connection, status: "200 OK", contentType: "application/json", body: json(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":40,"message":"Wrong username or password"}}}"#))
            return
        }
        switch components.path {
        case "/rest/ping.view":
            send(connection, status: "200 OK", contentType: "application/json", body: json(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#))
        case "/rest/search3.view":
            let offset = Int(query["songOffset"] ?? "0") ?? 0
            let page = songs.dropFirst(offset).map { song in
                #"{"id":"\#(song.id)","title":"\#(song.title)","artist":"\#(song.artist)","album":"\#(song.album)","duration":\#(song.duration),"coverArt":"al-\#(song.id)"}"#
            }
            send(connection, status: "200 OK", contentType: "application/json", body: json(#"{"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{"song":[\#(page.joined(separator: ","))]}}}"#))
        case "/rest/stream.view":
            stream(connection, rangeHeader: lines.first { $0.lowercased().hasPrefix("range:") })
        default:
            send(connection, status: "404 Not Found", contentType: "text/plain", body: Data())
        }
    }

    private func authorized(_ query: [String: String]) -> Bool {
        guard query["u"] == user, let salt = query["s"], let token = query["t"] else { return false }
        let expected = Insecure.MD5.hash(data: Data((password + salt).utf8)).map { String(format: "%02x", $0) }.joined()
        return token == expected
    }

    private func stream(_ connection: NWConnection, rangeHeader: String?) {
        guard let rangeHeader, let spec = rangeHeader.split(separator: "=").last else {
            send(connection, status: "200 OK", contentType: "audio/wav", body: audio)
            return
        }
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        let start = Int(parts.first ?? "0") ?? 0
        let end = min(parts.count > 1 ? (Int(parts[1]) ?? audio.count - 1) : audio.count - 1, audio.count - 1)
        guard start <= end else {
            send(connection, status: "416 Range Not Satisfiable", contentType: "text/plain", body: Data())
            return
        }
        send(
            connection,
            status: "206 Partial Content",
            contentType: "audio/wav",
            body: audio.subdata(in: start..<(end + 1)),
            extra: "Content-Range: bytes \(start)-\(end)/\(audio.count)\r\n"
        )
    }

    private func json(_ text: String) -> Data {
        Data(text.utf8)
    }

    private func send(_ connection: NWConnection, status: String, contentType: String, body: Data, extra: String = "") {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nAccept-Ranges: bytes\r\n\(extra)Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
