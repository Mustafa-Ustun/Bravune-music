import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

@MainActor
final class SpotifySession {
    static let callbackScheme = "bravune"
    static let redirectURI = "\(callbackScheme)://callback"
    static let scopes = "user-library-read user-read-playback-state user-modify-playback-state"
    static let refreshAccount = "spotify.refreshToken"

    nonisolated static let defaultTokenURL = URL(string: "https://accounts.spotify.com/api/token")!

    let clientID: String
    private let tokenURL: URL
    private(set) var refreshToken: String?
    private var token: String?
    private var expiry = Date.distantPast
    private var signInSession: ASWebAuthenticationSession?
    private let anchor = WindowAnchor()

    init(clientID: String, refreshToken: String? = nil, tokenURL: URL = SpotifySession.defaultTokenURL) {
        self.clientID = clientID
        self.refreshToken = refreshToken
        self.tokenURL = tokenURL
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func formBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let text = fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return Data(text.utf8)
    }

    func authorize() async throws {
        let verifier = Self.randomString(length: 64)
        let state = Self.randomString(length: 16)
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier))
        ]
        guard let authorizeURL = components.url else { throw SpotifyError.auth("Could not build the sign-in address") }

        let callback = try await signIn(at: authorizeURL)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        if let error = value("error") { throw SpotifyError.auth("Spotify sign-in failed: \(error)") }
        guard value("state") == state, let code = value("code") else {
            throw SpotifyError.auth("Spotify sign-in returned an unexpected answer")
        }
        try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier
        ])
    }

    private func signIn(at url: URL) async throws -> URL {
        defer { signInSession = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.callbackScheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(throwing: SpotifyError.auth("Spotify sign-in was cancelled"))
                } else {
                    continuation.resume(throwing: SpotifyError.auth(error?.localizedDescription ?? "Spotify sign-in failed"))
                }
            }
            session.presentationContextProvider = anchor
            signInSession = session
            if !session.start() {
                continuation.resume(throwing: SpotifyError.auth("Could not open the Spotify sign-in window"))
            }
        }
    }

    func accessToken() async throws -> String {
        if let token, expiry > Date() { return token }
        guard let refreshToken else { throw SpotifyError.notConnected }
        try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ])
        guard let token else { throw SpotifyError.notConnected }
        return token
    }

    func invalidateAccessToken() {
        token = nil
        expiry = .distantPast
    }

    private func tokenRequest(_ fields: [String: String]) async throws {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(TokenFailure.self, from: data))?.error_description
            throw SpotifyError.auth(message ?? "Spotify rejected the sign-in")
        }
        let decoded = try JSONDecoder().decode(TokenSuccess.self, from: data)
        token = decoded.access_token
        expiry = Date().addingTimeInterval(TimeInterval(decoded.expires_in - 30))
        if let newRefresh = decoded.refresh_token {
            refreshToken = newRefresh
            Keychain.set(newRefresh, account: Self.refreshAccount)
        }
    }

    private static func randomString(length: Int) -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).map { _ in characters.randomElement()! })
    }

    private struct TokenSuccess: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
    }

    private struct TokenFailure: Decodable {
        let error_description: String?
    }
}

private final class WindowAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        }
    }
}
