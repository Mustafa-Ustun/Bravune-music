import Foundation
import Network

final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let path: String
    private var continuation: CheckedContinuation<[URLQueryItem], Error>?

    init(port: UInt16, path: String) throws {
        guard let endpoint = NWEndpoint.Port(rawValue: port) else { throw SpotifyError.auth("Invalid port") }
        listener = try NWListener(using: .tcp, on: endpoint)
        self.path = path
    }

    func wait(timeout: TimeInterval, onReady: @escaping @Sendable () -> Void) async throws -> [URLQueryItem] {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: onReady()
                case .failed(let error): self?.finish(.failure(error))
                default: break
                }
            }
            listener.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(SpotifyError.timedOut))
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let components = URLComponents(string: "http://127.0.0.1" + target)
            let body = "<html><body style=\"font-family:-apple-system;text-align:center;margin-top:20vh\"><h2>Bravune is connected</h2><p>You can close this window.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            if components?.path == self.path {
                self.finish(.success(components?.queryItems ?? []))
            }
        }
    }

    private func finish(_ result: Result<[URLQueryItem], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        listener.cancel()
        continuation.resume(with: result)
    }
}
