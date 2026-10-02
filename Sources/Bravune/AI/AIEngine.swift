import Foundation

enum AIError: LocalizedError {
    case missingKey
    case emptyRequest
    case noProviders
    case refused
    case truncated
    case invalidResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingKey: "Add your Claude API key in Settings"
        case .emptyRequest: "Describe the mix you want"
        case .noProviders: "Connect a provider first"
        case .refused: "Claude declined this request"
        case .truncated: "The answer was cut off, try a shorter request"
        case .invalidResponse: "Claude returned an answer Bravune could not read"
        case .http(let status, let message): "Claude API error \(status): \(message)"
        }
    }
}

protocol AITransport: Sendable {
    func send(_ body: Data) async throws -> Data
}

struct AnthropicTransport: AITransport {
    let apiKey: String

    func send(_ body: Data) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.http(http.statusCode, AIEngine.errorMessage(from: data))
        }
        return data
    }
}

struct AIContext: Equatable {
    struct ProviderInfo: Equatable {
        let id: ProviderID
        let name: String
        let trackCount: Int
    }

    let providers: [ProviderInfo]
}

struct AIEngine {
    static let model = "claude-opus-5-5"
    static let maxRequestLength = 2000

    let transport: any AITransport

    func plan(for text: String, context: AIContext) async throws -> AIMixPlan {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIError.emptyRequest }
        guard !context.providers.isEmpty else { throw AIError.noProviders }
        let body = try Self.requestBody(for: String(trimmed.prefix(Self.maxRequestLength)), context: context)
        return try Self.parse(try await transport.send(body))
    }

    static func requestBody(for text: String, context: AIContext) throws -> Data {
        let listing = context.providers
            .map { "- \($0.id.rawValue) (\($0.name)): \($0.trackCount) tracks" }
            .joined(separator: "\n")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8000,
            "fallbacks": "default",
            "system": systemPrompt,
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": schema(providers: context.providers.map(\.id.rawValue))]
            ],
            "messages": [
                ["role": "user", "content": "Available providers:\n\(listing)\n\nRequest: \(text)"]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func parse(_ data: Data) throws -> AIMixPlan {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse
        }
        switch object["stop_reason"] as? String {
        case "refusal": throw AIError.refused
        case "max_tokens": throw AIError.truncated
        default: break
        }
        guard let blocks = object["content"] as? [[String: Any]],
              let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let json = text.data(using: .utf8),
              let plan = try? JSONDecoder().decode(AIMixPlan.self, from: json) else {
            throw AIError.invalidResponse
        }
        return plan
    }

    static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return "Request failed"
    }

    static func schema(providers: [String]) -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "providers": ["type": "array", "items": ["type": "string", "enum": providers]],
                "trackCount": ["type": "integer"],
                "durationMinutes": ["type": "integer"],
                "distribution": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "provider": ["type": "string", "enum": providers],
                            "count": ["type": "integer"]
                        ],
                        "required": ["provider", "count"],
                        "additionalProperties": false
                    ]
                ],
                "avoidDuplicateArtists": ["type": "boolean"],
                "randomize": ["type": "boolean"],
                "unsupported": ["type": "array", "items": ["type": "string"]]
            ],
            "required": ["providers", "trackCount", "durationMinutes", "distribution", "avoidDuplicateArtists", "randomize", "unsupported"],
            "additionalProperties": false
        ]
    }

    static let systemPrompt = """
    You turn a listener's request into a structured plan for Bravune's Mix Engine. Bravune combines tracks from several music providers into one queue. \
    The Mix Engine can only choose providers, set a track count or a duration in minutes, set how many tracks come from each provider, avoid repeating artists, and randomize the order. \
    Use only the providers listed. Set trackCount and durationMinutes to 0 when the listener did not state a size. \
    Leave distribution empty unless the listener gave per-provider amounts or proportions, and convert proportions into counts that add up to the track count. \
    Set avoidDuplicateArtists to true when the listener asks for no repeated artists or for variety. Set randomize to true unless the listener asks for an order. \
    Anything the Mix Engine cannot do, such as genre, mood, activity, language, era, popularity or named artists, must not be approximated. List each one briefly in unsupported.
    """
}
