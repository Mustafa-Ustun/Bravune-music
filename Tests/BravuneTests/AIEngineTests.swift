import XCTest
@testable import Bravune

private final class FakeTransport: AITransport, @unchecked Sendable {
    let response: Data
    private(set) var lastBody: Data?

    init(response: Data) {
        self.response = response
    }

    func send(_ body: Data) async throws -> Data {
        lastBody = body
        return response
    }
}

final class AIEngineTests: XCTestCase {
    private let context = AIContext(providers: [
        AIContext.ProviderInfo(id: ProviderID(rawValue: "spotify"), name: "Spotify", trackCount: 500),
        AIContext.ProviderInfo(id: .localMusic, name: "Local Music", trackCount: 80)
    ])

    private func reply(planJSON: String, stopReason: String = "end_turn") -> Data {
        let escaped = try! String(data: JSONEncoder().encode(planJSON), encoding: .utf8)!
        return Data(#"{"type":"message","stop_reason":"\#(stopReason)","content":[{"type":"thinking","thinking":""},{"type":"text","text":\#(escaped)}]}"#.utf8)
    }

    private let planJSON = """
    {"providers":["spotify","local_music"],"trackCount":0,"durationMinutes":90,"distribution":[{"provider":"spotify","count":18},{"provider":"local_music","count":8}],"avoidDuplicateArtists":true,"randomize":true,"unsupported":["Indonesian hip-hop genre","underground"]}
    """

    func testPlanParsedFromResponse() async throws {
        let transport = FakeTransport(response: reply(planJSON: planJSON))
        let plan = try await AIEngine(transport: transport).plan(for: "90 minute mix", context: context)
        XCTAssertEqual(plan.durationMinutes, 90)
        XCTAssertEqual(plan.unsupported.count, 2)
        XCTAssertTrue(plan.avoidDuplicateArtists)
    }

    func testRequestBodyShape() async throws {
        let transport = FakeTransport(response: reply(planJSON: planJSON))
        _ = try await AIEngine(transport: transport).plan(for: "  chill mix  ", context: context)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(transport.lastBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["temperature"])
        let config = try XCTUnwrap(body["output_config"] as? [String: Any])
        let format = try XCTUnwrap(config["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(content.contains("spotify (Spotify): 500 tracks"))
        XCTAssertTrue(content.hasSuffix("Request: chill mix"))
    }

    func testRefusalTruncationAndGarbage() {
        XCTAssertThrowsError(try AIEngine.parse(reply(planJSON: planJSON, stopReason: "refusal"))) {
            XCTAssertEqual($0.localizedDescription, AIError.refused.localizedDescription)
        }
        XCTAssertThrowsError(try AIEngine.parse(reply(planJSON: planJSON, stopReason: "max_tokens"))) {
            XCTAssertEqual($0.localizedDescription, AIError.truncated.localizedDescription)
        }
        XCTAssertThrowsError(try AIEngine.parse(reply(planJSON: "not json")))
        XCTAssertThrowsError(try AIEngine.parse(Data("[]".utf8)))
    }

    func testEmptyRequestAndNoProviders() async {
        let engine = AIEngine(transport: FakeTransport(response: Data()))
        do {
            _ = try await engine.plan(for: "   ", context: context)
            XCTFail()
        } catch {
            XCTAssertEqual(error.localizedDescription, AIError.emptyRequest.localizedDescription)
        }
        do {
            _ = try await engine.plan(for: "mix", context: AIContext(providers: []))
            XCTFail()
        } catch {
            XCTAssertEqual(error.localizedDescription, AIError.noProviders.localizedDescription)
        }
    }

    func testErrorMessageExtraction() {
        let data = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        XCTAssertEqual(AIEngine.errorMessage(from: data), "invalid x-api-key")
        XCTAssertEqual(AIEngine.errorMessage(from: Data("oops".utf8)), "Request failed")
    }

    func testPlanBecomesMixRequestWithDurationConverted() throws {
        let plan = try JSONDecoder().decode(AIMixPlan.self, from: Data(planJSON.utf8))
        let request = plan.makeRequest(connected: [ProviderID(rawValue: "spotify"), .localMusic], averageTrackLength: 210)
        XCTAssertEqual(request.providers, [ProviderID(rawValue: "spotify"), .localMusic])
        XCTAssertEqual(request.providerDistribution, ["spotify": 18, "local_music": 8])
        XCTAssertEqual(request.effectiveTrackCount, 26)
        XCTAssertTrue(request.avoidDuplicateArtists)
    }

    func testUnknownAndDisconnectedProvidersAreDropped() {
        let plan = AIMixPlan(
            providers: ["tidal", "spotify"],
            trackCount: 10,
            durationMinutes: 0,
            distribution: [.init(provider: "tidal", count: 5)],
            avoidDuplicateArtists: false,
            randomize: true,
            unsupported: []
        )
        let request = plan.makeRequest(connected: [ProviderID(rawValue: "spotify"), .localMusic], averageTrackLength: 0)
        XCTAssertEqual(request.providers, [ProviderID(rawValue: "spotify")])
        XCTAssertTrue(request.providerDistribution.isEmpty)
        XCTAssertEqual(request.trackCount, 10)
    }

    func testEmptyProvidersFallsBackToAllConnectedAndDefaultSize() {
        let plan = AIMixPlan(providers: [], trackCount: 0, durationMinutes: 0, distribution: [], avoidDuplicateArtists: false, randomize: true, unsupported: [])
        let request = plan.makeRequest(connected: [.localMusic], averageTrackLength: 0)
        XCTAssertEqual(request.providers, [.localMusic])
        XCTAssertEqual(request.trackCount, 20)
    }

    @MainActor
    func testAIRequiresProPlus() {
        let subscription = Subscription(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        subscription.plan = .pro
        XCTAssertThrowsError(try subscription.authorizeAI())
        subscription.plan = .proPlus
        XCTAssertNoThrow(try subscription.authorizeAI())
    }
}
