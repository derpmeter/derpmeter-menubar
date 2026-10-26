import Foundation

// Shared domain definitions. They mirror the server contract (/api/votes, /api/index, /api/models).
public enum Agent: String, CaseIterable, Codable, Sendable, Identifiable {
    case claudeCode = "claude-code"
    case codex
    case geminiCli = "gemini-cli"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "OpenAI Codex"
        case .geminiCli: return "Antigravity"
        }
    }
}

public enum Rating: String, CaseIterable, Codable, Sendable, Identifiable {
    case smart, meh, dumb
    public var id: String { rawValue }
    /// Smart = 0, Meh = 50, Dumb = 100.
    public var score: Int {
        switch self {
        case .smart: return 0
        case .meh: return 50
        case .dumb: return 100
        }
    }
    public var label: String { rawValue.capitalized }
}

public enum FailureReason: String, CaseIterable, Codable, Sendable, Identifiable {
    case instructionFailure = "instruction_failure"
    case hallucination
    case repeatedMistake = "repeated_mistake"
    case poorOutput = "poor_output"
    case tooSlow = "too_slow"
    case other
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .instructionFailure: return "Ignored instructions"
        case .hallucination: return "Hallucination"
        case .repeatedMistake: return "Repeated mistake"
        case .poorOutput: return "Poor output"
        case .tooSlow: return "Too slow"
        case .other: return "Other"
        }
    }
}

/// Exact request body for POST /api/votes from the Companion. Nothing else is sent.
public struct VoteBody: Codable, Equatable, Sendable {
    public let agent: String
    public let score: Int
    public let source: String
    public let model: String?
    public let failureReason: String?
    public let sessionLinked: Bool?
    public let idempotencyKey: String

    public init(
        agent: Agent, rating: Rating, model: String? = nil,
        reason: FailureReason? = nil, sessionLinked: Bool = false,
        idempotencyKey: UUID = UUID()
    ) {
        self.agent = agent.rawValue
        self.score = rating.score
        self.source = "menu-bar"
        self.model = model
        // The server accepts reasons only with Meh/Dumb.
        self.failureReason = rating == .smart ? nil : reason?.rawValue
        self.sessionLinked = sessionLinked ? true : nil
        self.idempotencyKey = idempotencyKey.uuidString.lowercased()
    }
}

public struct ScoreSummary: Codable, Equatable, Sendable {
    public let count: Int
    public let score: Double?
}

public struct AgentSnapshot: Codable, Equatable, Sendable {
    public let agent: String
    public let count: Int
    public let score: Double?
    public let models: [ModelSnapshot]
    public struct ModelSnapshot: Codable, Equatable, Sendable {
        public let model: String
        public let count: Int
        public let score: Double?
    }
}

/// GET /api/index (version 1). Extra fields are ignored.
public struct IndexSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let mode: String
    public let now: String
    public let agents: [AgentSnapshot]
    /// Optional: older servers and demo mode send none.
    public var radar: RadarSnapshot? = nil
    /// The blended Derp Score (votes + Radar, 7 days). Optional: older servers send none.
    public var score: BlendedScore? = nil

    public func agent(_ agent: Agent) -> AgentSnapshot? {
        agents.first { $0.agent == agent.rawValue }
    }
    /// The score shown big: the blended Derp Score (older servers: 24h votes).
    public func leadScore(_ agent: Agent) -> Double? {
        if let score { return score.agent(agent)?.score }
        return self.agent(agent)?.score
    }
    /// The sample behind `leadScore`: weighted votes + opinions, or 24h votes.
    public func leadSample(_ agent: Agent) -> Int {
        if let score { return Int(score.agent(agent)?.sample ?? 0) }
        return self.agent(agent)?.count ?? 0
    }
    public var isValid: Bool {
        let inRange = { (v: Double?) in v.map { (0...100).contains($0) } ?? true }
        return version == 1 && ["live", "demo"].contains(mode) && agents.allSatisfy {
            $0.count >= 0 && inRange($0.score)
        } && (radar?.agents.allSatisfy { $0.opinions >= 0 && inRange($0.score) } ?? true)
            && (score?.agents.allSatisfy {
                inRange($0.score) && $0.sample >= 0 && $0.votes.n >= 0 && inRange($0.votes.score)
                    && ($0.radar.map { $0.n >= 0 && inRange($0.score) } ?? true)
            } ?? true)
    }
}

/// Derp Score in /api/index: direct votes (each counting `voteWeight` times)
/// blended with Radar opinions over the same 7 UTC days. Agent-level only.
public struct BlendedScore: Codable, Equatable, Sendable {
    public struct Part: Codable, Equatable, Sendable {
        public let n: Double
        public let score: Double?
    }
    public struct Day: Codable, Equatable, Sendable {
        public let day: String
        public let score: Double?
        public let sample: Double
        public let votes: Int
        public let opinions: Int
    }
    public struct AgentScore: Codable, Equatable, Sendable {
        public let agent: String
        public let score: Double?
        public let sample: Double
        public let votes: Part
        /// nil when Radar was unavailable: the score is then votes only.
        public let radar: Part?
        public let days: [Day]
    }
    public let start: String
    public let end: String
    public let voteWeight: Double
    public let agents: [AgentScore]

    public func agent(_ agent: Agent) -> AgentScore? {
        agents.first { $0.agent == agent.rawValue }
    }
}

/// Radar in /api/index: 7-day community sentiment from public posts, on the
/// Derp Score scale but counted apart from votes.
public struct RadarSnapshot: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable {
        public let day: String
        public let score: Double?
        public let opinions: Int
    }
    public struct AgentRadar: Codable, Equatable, Sendable {
        public let agent: String
        public let score: Double?
        public let opinions: Int
        public let days: [Day]
    }
    public let lead: String
    public let agents: [AgentRadar]

    public func agent(_ agent: Agent) -> AgentRadar? {
        agents.first { $0.agent == agent.rawValue }
    }
}

public struct ModelCatalog: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let id: String
        public let agent: String
        public let name: String?
    }
    public let models: [Entry]
    public func contains(_ model: String, for agent: Agent) -> Bool {
        models.contains { $0.id == model && $0.agent == agent.rawValue }
    }
    public func name(of model: String, for agent: Agent) -> String? {
        models.first { $0.id == model && $0.agent == agent.rawValue }?.name
    }
}

/// GET /api/votes/status: when this installation (and network) can vote next.
/// The cooldown is per agent and model; agent-level fields are the network cap.
public struct VoteStatus: Codable, Equatable, Sendable {
    public struct ModelWait: Codable, Equatable, Sendable {
        /// nil = a vote without a model.
        public let model: String?
        public let waitSeconds: Int
    }
    public struct Entry: Codable, Equatable, Sendable {
        public let agent: String
        public let canVote: Bool
        public let nextVoteAt: String?
        public let waitSeconds: Int
        public let models: [ModelWait]?
    }
    public let cooldownSeconds: Int?
    public let agents: [Entry]

    /// Absolute time a vote for this agent (and model; nil = none) becomes
    /// available, relative to when the status was fetched.
    public func availableAt(_ agent: Agent, model: String? = nil, fetchedAt: Date) -> Date? {
        guard let e = agents.first(where: { $0.agent == agent.rawValue }) else { return nil }
        let own = e.models?.first(where: { $0.model == model })?.waitSeconds ?? 0
        let wait = max(e.canVote ? 0 : e.waitSeconds, own)
        return wait > 0 ? fetchedAt.addingTimeInterval(TimeInterval(wait)) : nil
    }
}

/// "38 min", "1 h 5 min", "<1 min".
public func waitText(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return "<1 min" }
    let m = Int((seconds / 60).rounded(.up))
    return m < 60 ? "\(m) min" : "\(m / 60) h" + (m % 60 > 0 ? " \(m % 60) min" : "")
}

/// /api/version: the versions the server advertises to clients.
public struct ClientVersions: Decodable, Sendable {
    public struct Entry: Decodable, Sendable {
        public let latest: String
        public let minimum: String?
    }
    public let companion: Entry?
}

/// An update the menu bar should offer; nil when current or unknown.
public struct UpdateNotice: Equatable, Sendable {
    public let latest: String
    /// Below the server's minimum: older APIs may stop working.
    public let unsupported: Bool

    public init(latest: String, unsupported: Bool) {
        self.latest = latest
        self.unsupported = unsupported
    }

    /// x.y.z only; anything else is never older (development builds stay quiet).
    public static func isOlder(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int]? {
            let p = v.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            return p.count == 3 && !p.contains(nil) ? p.compactMap { $0 } : nil
        }
        guard let x = parts(a), let y = parts(b) else { return false }
        return x.lexicographicallyPrecedes(y)
    }

    public static func from(current: String?, versions: ClientVersions) -> UpdateNotice? {
        guard let current, let entry = versions.companion, isOlder(current, than: entry.latest) else { return nil }
        return UpdateNotice(latest: entry.latest, unsupported: entry.minimum.map { isOlder(current, than: $0) } ?? false)
    }
}
