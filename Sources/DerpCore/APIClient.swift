import Foundation

/// Outcome of one HTTP attempt, classified for the offline queue.
public enum SendOutcome: Equatable, Sendable {
    case accepted(replayed: Bool)
    /// Network failure, timeout or 5xx: retry later with the same body and key.
    case retryable
    /// 401: credential invalid or revoked. Stop until the user fixes it.
    case unauthorized
    /// 409: key reused with a different vote. Needs explicit user resolution.
    case conflict
    /// 429: daily limit. Never retried automatically.
    case limited
    /// 410: the vote was cancelled.
    case cancelled
    /// Other 4xx: the request itself is invalid.
    case rejected(String)

    public static func classify(status: Int, message: String?) -> SendOutcome {
        switch status {
        case 200: return .accepted(replayed: true)
        case 201: return .accepted(replayed: false)
        case 401: return .unauthorized
        case 409: return .conflict
        case 410: return .cancelled
        case 429: return .limited
        case 408, 500...599: return .retryable
        default: return .rejected(message ?? "HTTP \(status)")
        }
    }
}

/// One broken Derp Smash CRT: catalog model and Claude Code effort, if known.
public struct SmashBody: Codable, Equatable, Sendable {
    public let agent: String
    public let model: String?
    public let effort: String?
    public init(agent: Agent, model: String?, effort: String?) {
        self.agent = agent.rawValue
        self.model = model
        self.effort = agent == .claudeCode ? effort.flatMap { ClaudeEffort.valid($0) } : nil
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

/// URLSession transport that refuses redirects so credentials never follow to another origin.
public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    public override init() {}
    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}

public struct APIClient: Sendable {
    public let origin: URL
    let transport: HTTPTransport

    /// HTTPS only; plain HTTP is allowed for loopback development.
    public init?(origin: String, transport: HTTPTransport = URLSessionTransport()) {
        guard let url = URL(string: origin), let host = url.host, url.user == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil
        else { return nil }
        self.origin = URL(string: "\(url.scheme!)://\(url.host!)\(url.port.map { ":\($0)" } ?? "")")!
        self.transport = transport
    }

    private func request(_ path: String, method: String = "GET", token: String? = nil, body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: origin.appendingPathComponent(path), timeoutInterval: 10)
        r.httpMethod = method
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    public func fetchIndex() async throws -> IndexSnapshot {
        let (data, status) = try await transport.send(request("api/index"))
        guard status == 200 else { throw URLError(.badServerResponse) }
        let snapshot = try JSONDecoder().decode(IndexSnapshot.self, from: data)
        guard snapshot.isValid else { throw URLError(.cannotParseResponse) }
        return snapshot
    }

    public func fetchCatalog() async throws -> ModelCatalog {
        let (data, status) = try await transport.send(request("api/models"))
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(ModelCatalog.self, from: data)
    }

    public func fetchVersions() async throws -> ClientVersions {
        let (data, status) = try await transport.send(request("api/version"))
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(ClientVersions.self, from: data)
    }

    public enum EnrollError: Error, Equatable { case demo, limited(String), failed(String) }

    /// Self-enrollment: POST /api/clients {"channel":"menu-bar"} returns a new token once.
    public func enroll() async throws -> String {
        let body = try JSONEncoder().encode(["channel": "menu-bar"])
        let (data, status) = try await transport.send(request("api/clients", method: "POST", body: body))
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if json["demo"] as? Bool == true { throw EnrollError.demo }
        let message = json["error"] as? String ?? "HTTP \(status)"
        if status == 429 { throw EnrollError.limited(message) }
        guard status == 201, let token = json["token"] as? String,
              token.range(of: "^dm_menubar_[0-9a-f]{64}$", options: .regularExpression) != nil
        else { throw EnrollError.failed(message) }
        return token
    }

    public func fetchVoteStatus(token: String) async throws -> VoteStatus {
        let (data, status) = try await transport.send(request("api/votes/status", token: token))
        guard status == 200 else { throw URLError(status == 401 ? .userAuthenticationRequired : .badServerResponse) }
        return try JSONDecoder().decode(VoteStatus.self, from: data)
    }

    public func submit(_ vote: VoteBody, token: String) async -> SendOutcome {
        await perform(request("api/votes", method: "POST", token: token, body: try? JSONEncoder().encode(vote)))
    }

    /// Derp Smash: count one broken CRT (POST /api/smash). Best effort, never queued.
    public func reportSmash(_ body: SmashBody, token: String) async -> SendOutcome {
        await perform(request("api/smash", method: "POST", token: token, body: try? JSONEncoder().encode(body)))
    }

    /// Cancel your own vote within 24h (DELETE /api/votes with the receipt key).
    public func cancel(key: String, token: String) async -> SendOutcome {
        let body = try? JSONEncoder().encode(["source": "menu-bar", "idempotencyKey": key])
        return await perform(request("api/votes", method: "DELETE", token: token, body: body))
    }

    private func perform(_ request: URLRequest) async -> SendOutcome {
        do {
            let (data, status) = try await transport.send(request)
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            return .classify(status: status, message: message)
        } catch {
            return .retryable
        }
    }
}
