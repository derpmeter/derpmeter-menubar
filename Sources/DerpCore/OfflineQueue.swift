import Foundation

/// A vote waiting to be sent. The exact body (and idempotency key) is reused on every retry.
public struct PendingVote: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case pending, unauthorized, conflict, limited, rejected, expired
    }
    public let body: VoteBody
    public let origin: String
    public let createdAt: Date
    public var attempts: Int
    public var nextAttemptAt: Date
    public var state: State
    public var message: String?
    public var id: String { body.idempotencyKey }
}

/// Accepted vote, kept locally for 24h so it can be cancelled (the server link also expires at 24h).
public struct Receipt: Codable, Equatable, Sendable {
    public let agent: String
    public let key: String
    public let origin: String
    public let at: Date
}

public struct OfflineQueue: Codable, Equatable, Sendable {
    public static let maxItems = 20
    public static let lifetime: TimeInterval = 86_400
    public private(set) var items: [PendingVote] = []
    public private(set) var receipts: [Receipt] = []
    public init() {}

    public enum QueueError: Error, Equatable { case full, duplicate }

    public mutating func enqueue(_ body: VoteBody, origin: String, now: Date) throws {
        expire(now: now)
        guard items.count < Self.maxItems else { throw QueueError.full }
        guard !items.contains(where: { $0.body.idempotencyKey == body.idempotencyKey }) else { throw QueueError.duplicate }
        items.append(PendingVote(body: body, origin: origin, createdAt: now, attempts: 0, nextAttemptAt: now, state: .pending))
    }

    /// Pending items older than 24h are never sent: the server would not recognize their receipt.
    public mutating func expire(now: Date) {
        for i in items.indices where items[i].state == .pending && now.timeIntervalSince(items[i].createdAt) >= Self.lifetime {
            items[i].state = .expired
        }
        items.removeAll { $0.state != .pending && now.timeIntervalSince($0.createdAt) >= 2 * Self.lifetime }
        receipts.removeAll { now.timeIntervalSince($0.at) >= Self.lifetime }
    }

    /// Items to send now, only for the configured origin (never redirected elsewhere).
    public func due(now: Date, origin: String) -> [PendingVote] {
        items.filter { $0.state == .pending && $0.origin == origin && $0.nextAttemptAt <= now }
    }

    public mutating func record(_ key: String, outcome: SendOutcome, now: Date) {
        guard let i = items.firstIndex(where: { $0.body.idempotencyKey == key }) else { return }
        switch outcome {
        case .accepted:
            let item = items.remove(at: i)
            receipts.append(Receipt(agent: item.body.agent, key: key, origin: item.origin, at: now))
        case .retryable:
            items[i].attempts += 1
            // Bounded exponential backoff: 30s, 60s, 120s ... capped at 1h.
            let delay = min(30 * pow(2, Double(items[i].attempts - 1)), 3600)
            items[i].nextAttemptAt = now.addingTimeInterval(delay)
        case .unauthorized:
            // Stop everything for this origin until the credential is fixed.
            for j in items.indices where items[j].state == .pending && items[j].origin == items[i].origin {
                items[j].state = .unauthorized
            }
        case .conflict: items[i].state = .conflict
        case .limited: items[i].state = .limited
        case .cancelled: items[i].state = .rejected; items[i].message = "Cancelled"
        case .rejected(let message): items[i].state = .rejected; items[i].message = message
        }
    }

    /// After the user fixes the credential, resume items that stopped on 401.
    public mutating func resumeUnauthorized(now: Date) {
        for i in items.indices where items[i].state == .unauthorized {
            items[i].state = .pending
            items[i].nextAttemptAt = now
        }
        expire(now: now)
    }

    /// Explicit user action: remove an unsent or failed item.
    public mutating func discard(_ key: String) {
        items.removeAll { $0.body.idempotencyKey == key }
    }

    public func latestReceipt(agent: Agent, origin: String, now: Date) -> Receipt? {
        receipts.last { $0.agent == agent.rawValue && $0.origin == origin && now.timeIntervalSince($0.at) < Self.lifetime }
    }

    public mutating func dropReceipt(_ key: String) {
        receipts.removeAll { $0.key == key }
    }
}

/// Atomic JSON persistence in the app's own Application Support directory.
public struct JSONStore<Value: Codable> {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(Value.self, from: data)
    }
    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Self.encoder.encode(value).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
