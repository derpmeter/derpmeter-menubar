import Foundation
import XCTest
@testable import DerpCore

final class VoteBodyTests: XCTestCase {
    func testEncodesOnlyContractFieldsAndOmitsNil() throws {
        let key = UUID()
        let body = VoteBody(agent: .codex, rating: .dumb, reason: .hallucination, idempotencyKey: key)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as! [String: Any]
        XCTAssertEqual(Set(json.keys), ["agent", "score", "source", "failureReason", "idempotencyKey"])
        XCTAssertEqual(json["source"] as? String, "menu-bar")
        XCTAssertEqual(json["score"] as? Int, 100)
        XCTAssertEqual(json["idempotencyKey"] as? String, key.uuidString.lowercased())
    }

    func testSmartDropsReasonAndSessionFlagIsExplicit() throws {
        let body = VoteBody(agent: .claudeCode, rating: .smart, model: "claude-opus-5-5", reason: .other, sessionLinked: true)
        XCTAssertNil(body.failureReason)
        XCTAssertEqual(body.sessionLinked, true)
        XCTAssertNil(VoteBody(agent: .claudeCode, rating: .meh).sessionLinked)
    }
}

final class OutcomeTests: XCTestCase {
    func testClassification() {
        XCTAssertEqual(SendOutcome.classify(status: 201, message: nil), .accepted(replayed: false))
        XCTAssertEqual(SendOutcome.classify(status: 200, message: nil), .accepted(replayed: true))
        XCTAssertEqual(SendOutcome.classify(status: 401, message: nil), .unauthorized)
        XCTAssertEqual(SendOutcome.classify(status: 409, message: nil), .conflict)
        XCTAssertEqual(SendOutcome.classify(status: 429, message: nil), .limited)
        XCTAssertEqual(SendOutcome.classify(status: 503, message: nil), .retryable)
        XCTAssertEqual(SendOutcome.classify(status: 400, message: "bad"), .rejected("bad"))
    }
}

final class OfflineQueueTests: XCTestCase {
    let origin = "https://derp.example"
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testRetryReusesKeyWithBackoffThenRecordsReceipt() throws {
        var q = OfflineQueue()
        let body = VoteBody(agent: .codex, rating: .meh)
        try q.enqueue(body, origin: origin, now: t0)
        XCTAssertEqual(q.due(now: t0, origin: origin).map(\.id), [body.idempotencyKey])
        q.record(body.idempotencyKey, outcome: .retryable, now: t0)
        XCTAssertTrue(q.due(now: t0.addingTimeInterval(29), origin: origin).isEmpty)
        XCTAssertEqual(q.due(now: t0.addingTimeInterval(30), origin: origin).first?.body, body)
        q.record(body.idempotencyKey, outcome: .retryable, now: t0.addingTimeInterval(30))
        XCTAssertEqual(q.items[0].nextAttemptAt, t0.addingTimeInterval(90))
        q.record(body.idempotencyKey, outcome: .accepted(replayed: true), now: t0.addingTimeInterval(100))
        XCTAssertTrue(q.items.isEmpty)
        XCTAssertEqual(q.latestReceipt(agent: .codex, origin: origin, now: t0.addingTimeInterval(200))?.key, body.idempotencyKey)
        XCTAssertNil(q.latestReceipt(agent: .codex, origin: origin, now: t0.addingTimeInterval(86_500)))
    }

    func testStopsOnUnauthorizedConflictAndLimitUntilResolved() throws {
        var q = OfflineQueue()
        let a = VoteBody(agent: .codex, rating: .dumb), b = VoteBody(agent: .geminiCli, rating: .dumb)
        let c = VoteBody(agent: .claudeCode, rating: .dumb)
        try q.enqueue(a, origin: origin, now: t0)
        try q.enqueue(b, origin: origin, now: t0)
        try q.enqueue(c, origin: "https://other.example", now: t0)
        q.record(a.idempotencyKey, outcome: .unauthorized, now: t0)
        XCTAssertEqual(q.items.map(\.state), [.unauthorized, .unauthorized, .pending])
        XCTAssertTrue(q.due(now: t0, origin: origin).isEmpty)
        // Never sent to an origin other than the one it was queued for.
        XCTAssertEqual(q.due(now: t0, origin: origin).count, 0)
        q.resumeUnauthorized(now: t0)
        XCTAssertEqual(q.due(now: t0, origin: origin).count, 2)
        q.record(a.idempotencyKey, outcome: .conflict, now: t0)
        q.record(b.idempotencyKey, outcome: .limited, now: t0)
        XCTAssertEqual(q.items.prefix(2).map(\.state), [.conflict, .limited])
        q.discard(a.idempotencyKey)
        XCTAssertEqual(q.items.count, 2)
    }

    func testBoundsDuplicatesAndExpiry() throws {
        var q = OfflineQueue()
        let body = VoteBody(agent: .codex, rating: .meh)
        try q.enqueue(body, origin: origin, now: t0)
        XCTAssertThrowsError(try q.enqueue(body, origin: origin, now: t0)) { XCTAssertEqual($0 as? OfflineQueue.QueueError, .duplicate) }
        for _ in 1..<OfflineQueue.maxItems { try q.enqueue(VoteBody(agent: .codex, rating: .meh), origin: origin, now: t0) }
        XCTAssertThrowsError(try q.enqueue(VoteBody(agent: .codex, rating: .meh), origin: origin, now: t0)) {
            XCTAssertEqual($0 as? OfflineQueue.QueueError, .full)
        }
        q.expire(now: t0.addingTimeInterval(86_400))
        XCTAssertTrue(q.due(now: t0.addingTimeInterval(86_400), origin: origin).isEmpty)
        XCTAssertTrue(q.items.allSatisfy { $0.state == .expired })
        q.expire(now: t0.addingTimeInterval(2 * 86_400))
        XCTAssertTrue(q.items.isEmpty)
    }

    func testPersistsWithPrivatePermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONStore<OfflineQueue>(url: dir.appendingPathComponent("queue.json"))
        var q = OfflineQueue()
        try q.enqueue(VoteBody(agent: .codex, rating: .dumb), origin: origin, now: t0)
        try store.save(q)
        XCTAssertEqual(store.load(), q)
        let perms = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }
}

final class MascotAndTitleTests: XCTestCase {
    func testMoodThresholdsAndStates() {
        XCTAssertEqual(DerpyMood.from(score: 10, loading: false, offline: false), .smart)
        XCTAssertEqual(DerpyMood.from(score: 50, loading: false, offline: false), .neutral)
        XCTAssertEqual(DerpyMood.from(score: 80, loading: false, offline: false), .derpy)
        XCTAssertEqual(DerpyMood.from(score: nil, loading: true, offline: false), .loading)
        XCTAssertEqual(DerpyMood.from(score: 80, loading: false, offline: true), .offline)
    }

    func testStatuslineMoodBoundariesAndMissingData() {
        XCTAssertEqual(statuslineMoodFace(score: nil), "(·_·)")
        XCTAssertEqual(statuslineMoodFace(score: 0), "(•‿•)")
        XCTAssertEqual(statuslineMoodFace(score: 34.9), "(•‿•)")
        XCTAssertEqual(statuslineMoodFace(score: 35), "(•_•)")
        XCTAssertEqual(statuslineMoodFace(score: 64.9), "(•_•)")
        XCTAssertEqual(statuslineMoodFace(score: 65), "(⊙_☉)")
        XCTAssertEqual(statuslineMoodFace(score: 100), "(⊙_☉)")
    }

    func testTitleMatchesStatuslineMoodWithoutModelOrFlags() {
        let snap = IndexSnapshot(version: 1, mode: "live", now: "2026-10-21T00:00:00Z", agents: [
            AgentSnapshot(agent: "codex", count: 3, score: 66.6, models: []),
            AgentSnapshot(agent: "claude-code", count: 120, score: 41.2, models: []),
        ])
        XCTAssertEqual(menuBarTitle(snapshot: snap, agent: .codex), "(⊙_☉) · Derp 67")
        XCTAssertEqual(menuBarTitle(snapshot: snap, agent: .claudeCode), "(•_•) · Derp 41")
        XCTAssertEqual(menuBarTitle(snapshot: nil, agent: .codex), "(·_·) · Derp —")
    }
}

final class LocalIntegrationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testReadsOnlyFreshValidObservations() {
        let fresh = now.addingTimeInterval(-60).timeIntervalSince1970 * 1000
        let stale = now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000
        let data = try! JSONSerialization.data(withJSONObject: [
            "claude-code": ["model": "claude-opus-5-5", "seenAt": fresh],
            "codex": ["model": "gpt-6-sol", "seenAt": stale],
        ])
        let s = LocalIntegration.recentSession(data: data, now: now)
        XCTAssertEqual(s?.agent, .claudeCode)
        XCTAssertEqual(s?.model, "claude-opus-5-5")
        let bad = try! JSONSerialization.data(withJSONObject: ["claude-code": ["model": "/etc/passwd", "seenAt": fresh]])
        XCTAssertNil(LocalIntegration.recentSession(data: bad, now: now)?.model)
        XCTAssertNil(LocalIntegration.recentSession(data: Data("nope".utf8), now: now))
        XCTAssertNil(LocalIntegration.recentSession(data: nil, now: now))
    }

    func testReadsClaudeEffortFromObservationAndSettings() {
        let fresh = now.addingTimeInterval(-60).timeIntervalSince1970 * 1000
        let data = try! JSONSerialization.data(withJSONObject: [
            "claude-code": ["model": "claude-opus-5-5", "effort": "xhigh", "seenAt": fresh],
        ])
        XCTAssertEqual(LocalIntegration.recentSession(data: data, now: now)?.effort, "xhigh")
        let odd = try! JSONSerialization.data(withJSONObject: [
            "claude-code": ["model": "claude-opus-5-5", "effort": "turbo", "seenAt": fresh],
        ])
        XCTAssertNil(LocalIntegration.recentSession(data: odd, now: now)?.effort)
        XCTAssertEqual(LocalModelSettings.claudeEffort(json: Data(#"{"effortLevel":"max"}"#.utf8)), "max")
        XCTAssertNil(LocalModelSettings.claudeEffort(json: Data(#"{"effortLevel":"11"}"#.utf8)))
        XCTAssertEqual(LocalModelSettings.configuredClaudeEffort(environment: ["CLAUDE_CODE_EFFORT_LEVEL": "low", "CLAUDE_CONFIG_DIR": "/nonexistent"]), "low")
        XCTAssertNil(LocalModelSettings.configuredClaudeEffort(environment: ["CLAUDE_CONFIG_DIR": "/nonexistent"]))
    }

    func testClaudeCodeIsActiveOnlyRightAfterAStatuslineRefresh() {
        func at(_ ago: TimeInterval) -> Data {
            try! JSONSerialization.data(withJSONObject: [
                "claude-code": ["model": "claude-opus-5-5", "seenAt": now.addingTimeInterval(-ago).timeIntervalSince1970 * 1000],
            ])
        }
        XCTAssertTrue(LocalIntegration.claudeCodeActive(data: at(30), now: now))
        XCTAssertFalse(LocalIntegration.claudeCodeActive(data: at(180), now: now))
        XCTAssertFalse(LocalIntegration.claudeCodeActive(data: at(-30), now: now), "future timestamps are ignored")
        XCTAssertFalse(LocalIntegration.claudeCodeActive(data: nil, now: now))
    }

    func testSmashBodyKeepsEffortForClaudeCodeOnly() throws {
        XCTAssertEqual(SmashBody(agent: .claudeCode, model: "claude-opus-5-5", effort: "high").effort, "high")
        XCTAssertNil(SmashBody(agent: .codex, model: nil, effort: "high").effort)
        XCTAssertNil(SmashBody(agent: .claudeCode, model: nil, effort: "turbo").effort)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SmashBody(agent: .codex, model: nil, effort: nil))) as? [String: Any]
        XCTAssertEqual(json?.keys.sorted(), ["agent"])
    }
}

final class APIClientTests: XCTestCase {
    final class Mock: HTTPTransport, @unchecked Sendable {
        var requests: [URLRequest] = []
        var response: (Data, Int) = (Data("{}".utf8), 201)
        var fail = false
        func send(_ request: URLRequest) async throws -> (Data, Int) {
            requests.append(request)
            if fail { throw URLError(.notConnectedToInternet) }
            return response
        }
    }

    func testOriginRules() {
        XCTAssertNotNil(APIClient(origin: "https://derp.example"))
        XCTAssertNotNil(APIClient(origin: "http://127.0.0.1:3000"))
        XCTAssertNil(APIClient(origin: "http://derp.example"))
        XCTAssertNil(APIClient(origin: "https://user:pw@derp.example"))
        XCTAssertNil(APIClient(origin: "https://derp.example/path"))
        XCTAssertNil(APIClient(origin: "https://"))
    }

    func testSubmitSendsBearerAndClassifiesFailures() async throws {
        let mock = Mock()
        let client = APIClient(origin: "https://derp.example", transport: mock)!
        let body = VoteBody(agent: .codex, rating: .dumb)
        let token = "dm_menubar_" + String(repeating: "a", count: 64)
        let outcome = await client.submit(body, token: token)
        XCTAssertEqual(outcome, .accepted(replayed: false))
        let r = mock.requests[0]
        XCTAssertEqual(r.url?.absoluteString, "https://derp.example/api/votes")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(try JSONDecoder().decode(VoteBody.self, from: r.httpBody!), body)
        mock.fail = true
        let offline = await client.submit(body, token: token)
        XCTAssertEqual(offline, .retryable)
    }

    func testInvalidSnapshotIsRejected() async {
        let mock = Mock()
        mock.response = (Data(#"{"version":2,"mode":"live","now":"x","agents":[]}"#.utf8), 200)
        let client = APIClient(origin: "https://derp.example", transport: mock)!
        do {
            _ = try await client.fetchIndex()
            XCTFail("expected rejection")
        } catch {}
    }
}

final class VoteStatusTests: XCTestCase {
    func testAvailabilityAndWaitText() throws {
        let json = #"{"cooldownSeconds":3600,"agents":[{"agent":"codex","canVote":false,"nextVoteAt":"2026-10-21T13:00:00.000Z","waitSeconds":2230},{"agent":"claude-code","canVote":true,"nextVoteAt":null,"waitSeconds":0}]}"#
        let status = try JSONDecoder().decode(VoteStatus.self, from: Data(json.utf8))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(status.availableAt(.codex, fetchedAt: t0), t0.addingTimeInterval(2230))
        XCTAssertNil(status.availableAt(.claudeCode, fetchedAt: t0))
        XCTAssertNil(status.availableAt(.geminiCli, fetchedAt: t0))
        // Per-model cooldown on top of the network-level wait.
        let perModel = #"{"cooldownSeconds":3600,"agents":[{"agent":"claude-code","canVote":true,"nextVoteAt":null,"waitSeconds":0,"models":[{"model":null,"waitSeconds":600},{"model":"claude-opus-5-5","waitSeconds":1200}]}]}"#
        let pm = try JSONDecoder().decode(VoteStatus.self, from: Data(perModel.utf8))
        XCTAssertEqual(pm.availableAt(.claudeCode, fetchedAt: t0), t0.addingTimeInterval(600))
        XCTAssertEqual(pm.availableAt(.claudeCode, model: "claude-opus-5-5", fetchedAt: t0), t0.addingTimeInterval(1200))
        XCTAssertNil(pm.availableAt(.claudeCode, model: "claude-sonnet-5-5", fetchedAt: t0))
        XCTAssertEqual(waitText(20), "<1 min")
        XCTAssertEqual(waitText(2230), "38 min")
        XCTAssertEqual(waitText(3900), "1 h 5 min")
        XCTAssertEqual(waitText(3600), "1 h")
    }
}

final class EnrollTests: XCTestCase {
    func testEnrollParsesTokenAndLimits() async throws {
        let mock = APIClientTests.Mock()
        let client = APIClient(origin: "https://derp.example", transport: mock)!
        let token = "dm_menubar_" + String(repeating: "b", count: 64)
        mock.response = (Data(#"{"token":"\#(token)","channel":"menu-bar"}"#.utf8), 201)
        let got = try await client.enroll()
        XCTAssertEqual(got, token)
        XCTAssertEqual(mock.requests[0].url?.path, "/api/clients")
        XCTAssertNil(mock.requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(String(data: mock.requests[0].httpBody!, encoding: .utf8), #"{"channel":"menu-bar"}"#)
        mock.response = (Data(#"{"error":"Too many new installations from this network today."}"#.utf8), 429)
        do { _ = try await client.enroll(); XCTFail() } catch let e as APIClient.EnrollError {
            XCTAssertEqual(e, .limited("Too many new installations from this network today."))
        }
        mock.response = (Data(#"{"token":"dm_cli_xyz"}"#.utf8), 201)
        do { _ = try await client.enroll(); XCTFail() } catch {}
    }
}

final class LocalModelSettingsTests: XCTestCase {
    func testCodexReadsOnlyTopLevelModel() {
        XCTAssertEqual(LocalModelSettings.codexModel(toml: "# c\nmodel = \"gpt-6.1-sol\"  # default\napproval = \"x\"\n"), "gpt-6.1-sol")
        XCTAssertNil(LocalModelSettings.codexModel(toml: "[profiles.fast]\nmodel = \"gpt-6-sol\"\n"))
        XCTAssertNil(LocalModelSettings.codexModel(toml: "model = \"../../etc/passwd\"\n"))
    }

    func testAntigravityModelName() {
        XCTAssertEqual(LocalModelSettings.antigravityModel(json: Data(#"{"model":{"name":"gemini-3.8-flash"}}"#.utf8)), "gemini-3.8-flash")
        XCTAssertEqual(LocalModelSettings.antigravityModel(json: Data(#"{"model":"gemini-4-argon"}"#.utf8)), "gemini-4-argon")
        XCTAssertNil(LocalModelSettings.antigravityModel(json: Data(#"{"model":{"name":"Claude Opus (Thinking)"}}"#.utf8)))
        XCTAssertNil(LocalModelSettings.antigravityModel(json: Data("not json".utf8)))
    }

    func testModelChoiceResolvesOnlyCatalogModels() throws {
        let catalog = try JSONDecoder().decode(ModelCatalog.self, from: Data(#"{"models":[{"id":"claude-opus-5-5","agent":"claude-code","name":"Claude Opus 5.5"},{"id":"gemini-3.8-flash","agent":"gemini-cli","name":"Gemini 3.8 Flash"}]}"#.utf8))
        XCTAssertEqual(ModelChoice.auto.resolve(detected: "claude-opus-5-5", agent: .claudeCode, catalog: catalog), "claude-opus-5-5")
        XCTAssertNil(ModelChoice.auto.resolve(detected: "claude-opus-5-5", agent: .codex, catalog: catalog), "not this agent's model")
        XCTAssertNil(ModelChoice.auto.resolve(detected: "unknown-1", agent: .geminiCli, catalog: catalog))
        XCTAssertNil(ModelChoice.none.resolve(detected: "gemini-3.8-flash", agent: .geminiCli, catalog: catalog))
        XCTAssertEqual(ModelChoice.model("gemini-3.8-flash").resolve(detected: nil, agent: .geminiCli, catalog: catalog), "gemini-3.8-flash")
        XCTAssertNil(ModelChoice.model("retired-model").resolve(detected: nil, agent: .geminiCli, catalog: catalog))
        for choice in [ModelChoice.auto, .none, .model("x-1")] {
            XCTAssertEqual(ModelChoice(storageValue: choice.storageValue), choice)
        }
        XCTAssertEqual(catalog.name(of: "gemini-3.8-flash", for: .geminiCli), "Gemini 3.8 Flash")
    }
}

final class ClaudeSettingsTests: XCTestCase {
    func testClaudeSettingsAndAliases() throws {
        XCTAssertEqual(LocalModelSettings.claudeModel(json: Data(#"{"model":"opus"}"#.utf8)), "opus")
        XCTAssertEqual(LocalModelSettings.claudeModel(json: Data(#"{"model":"claude-sonnet-5-5[1m]"}"#.utf8)), "claude-sonnet-5-5[1m]")
        XCTAssertNil(LocalModelSettings.claudeModel(json: Data(#"{"model":"../x y"}"#.utf8)))
        XCTAssertNil(LocalModelSettings.claudeModel(json: Data(#"{"theme":"dark"}"#.utf8)))
        let catalog = try JSONDecoder().decode(ModelCatalog.self, from: Data(#"{"models":[{"id":"claude-opus-5-5","agent":"claude-code"},{"id":"claude-sonnet-5-5","agent":"claude-code"},{"id":"claude-haiku-5-5","agent":"claude-code"},{"id":"agy-claude-opus-5-5","agent":"gemini-cli"}]}"#.utf8))
        let r = { (raw: String, agent: Agent) in LocalModelSettings.resolve(raw, agent: agent, catalog: catalog) }
        XCTAssertEqual(r("claude-opus-5-5", .claudeCode), "claude-opus-5-5")
        XCTAssertEqual(r("claude-sonnet-5-5[1m]", .claudeCode), "claude-sonnet-5-5")
        XCTAssertEqual(r("claude-haiku-5-5-20261001", .claudeCode), "claude-haiku-5-5")
        XCTAssertEqual(r("opus", .claudeCode), "claude-opus-5-5")
        XCTAssertEqual(r("opusplan", .claudeCode), "claude-opus-5-5")
        XCTAssertEqual(r("sonnet[1m]", .claudeCode), "claude-sonnet-5-5")
        XCTAssertNil(r("default", .claudeCode))
        XCTAssertNil(r("fable", .claudeCode), "no current fable model in this catalog")
        XCTAssertNil(r("opus", .geminiCli), "aliases are Claude Code only")
        XCTAssertEqual(ModelChoice.auto.resolve(detected: "opus", agent: .claudeCode, catalog: catalog), "claude-opus-5-5")
    }
}

final class BlendedScoreTests: XCTestCase {
    func testBlendedScoreLeadsAndOlderServersFallBackToVotes() throws {
        let json = """
        {"version":1,"mode":"live","now":"2026-10-23T00:00:00Z","window":"24h",
         "agents":[{"agent":"codex","count":8,"score":6.3,"models":[]}],
         "radar":{"lead":"radar","start":"2026-10-17","end":"2026-10-23",
          "agents":[{"agent":"codex","score":48.9,"opinions":236,"smart":1,"meh":2,"dumb":3,
                     "days":[{"day":"2026-10-23","score":null,"opinions":0}]}],
          "sources":[]},
         "score":{"start":"2026-10-17","end":"2026-10-23","voteWeight":3,
          "agents":[{"agent":"codex","score":47.1,"sample":260,"votes":{"n":8,"score":6.3},
                     "radar":{"n":236,"score":48.9},
                     "days":[{"day":"2026-10-23","score":null,"sample":0,"votes":0,"opinions":0}]}]}}
        """
        var snap = try JSONDecoder().decode(IndexSnapshot.self, from: Data(json.utf8))
        XCTAssertTrue(snap.isValid)
        XCTAssertEqual(snap.leadScore(.codex), 47.1)
        XCTAssertEqual(snap.leadSample(.codex), 260)
        XCTAssertEqual(snap.score?.agent(.codex)?.radar?.n, 236)
        XCTAssertEqual(menuBarTitle(snapshot: snap, agent: .codex), "(•_•) · Derp 47")
        // Older server: no blend, so the 24h votes (Radar no longer leads).
        snap.score = nil
        XCTAssertEqual(snap.leadScore(.codex), 6.3)
        XCTAssertEqual(snap.leadSample(.codex), 8)
        XCTAssertEqual(menuBarTitle(snapshot: snap, agent: .codex), "(•‿•) · Derp 6")
    }

    func testRejectsOutOfRangeBlend() throws {
        let json = """
        {"version":1,"mode":"live","now":"2026-10-23T00:00:00Z","agents":[],
         "score":{"start":"a","end":"b","voteWeight":3,
          "agents":[{"agent":"codex","score":140,"sample":1,"votes":{"n":1,"score":100},"radar":null,"days":[]}]}}
        """
        let snap = try JSONDecoder().decode(IndexSnapshot.self, from: Data(json.utf8))
        XCTAssertFalse(snap.isValid)
        XCTAssertNil(snap.score?.agents.first?.radar)
    }
}

final class UpdateNoticeTests: XCTestCase {
    func testComparesNumericallyAndIgnoresDevBuilds() {
        XCTAssertTrue(UpdateNotice.isOlder("0.1.9", than: "0.1.10"))
        XCTAssertFalse(UpdateNotice.isOlder("0.1.10", than: "0.1.9"))
        XCTAssertFalse(UpdateNotice.isOlder("0.1.9", than: "0.1.9"))
        XCTAssertFalse(UpdateNotice.isOlder("dev", than: "0.1.10"))
        XCTAssertFalse(UpdateNotice.isOlder("0.1", than: "0.1.10"))
    }

    func testNoticeFromServerVersions() async throws {
        let mock = APIClientTests.Mock()
        mock.response = (Data(#"{"version":1,"cli":{"latest":"0.5.8","minimum":"0.5.0"},"companion":{"latest":"0.1.10","minimum":"0.1.0"}}"#.utf8), 200)
        let versions = try await APIClient(origin: "https://derp.example", transport: mock)!.fetchVersions()
        XCTAssertEqual(mock.requests[0].url?.absoluteString, "https://derp.example/api/version")
        XCTAssertEqual(UpdateNotice.from(current: "0.1.9", versions: versions), UpdateNotice(latest: "0.1.10", unsupported: false))
        XCTAssertNil(UpdateNotice.from(current: "0.1.10", versions: versions))
        XCTAssertNil(UpdateNotice.from(current: nil, versions: versions))
        mock.response = (Data(#"{"companion":{"latest":"0.2.0","minimum":"0.1.10"}}"#.utf8), 200)
        let strict = try await APIClient(origin: "https://derp.example", transport: mock)!.fetchVersions()
        XCTAssertEqual(UpdateNotice.from(current: "0.1.9", versions: strict)?.unsupported, true)
        // Servers without a companion entry never prompt.
        mock.response = (Data(#"{"cli":{"latest":"0.5.8"}}"#.utf8), 200)
        let old = try await APIClient(origin: "https://derp.example", transport: mock)!.fetchVersions()
        XCTAssertNil(UpdateNotice.from(current: "0.0.1", versions: old))
    }
}
