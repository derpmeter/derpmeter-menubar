import Foundation

/// Optional follow-up questions after a vote. Same questions and bounded
/// choices as the web (src/lib/vote-details.ts) and the CLI; no free text.
/// Answers never change the Derp Score.
public enum FollowUpQuestion: String, CaseIterable, Codable, Sendable, Identifiable {
    case vsUsual = "vs_usual", task, session, languages, wentWell = "went_well", frequency

    public var id: String { rawValue }
    public var multi: Bool { self == .languages || self == .wentWell }
    public var choices: [String] {
        switch self {
        case .vsUsual: return ["much_better", "better", "same", "worse", "much_worse"]
        case .task: return ["feature", "bugfix", "refactor", "test", "docs", "explore"]
        case .session: return ["lt15m", "lt1h", "lt3h", "gte3h"]
        case .languages: return ["ts_js", "python", "go", "rust", "jvm", "swift", "c_cpp", "other"]
        case .wentWell: return ["followed", "one_shot", "fast", "quality"]
        case .frequency: return ["daily", "weekly", "sometimes"]
        }
    }

    /// vs_usual first; the rest rotate (went_well only after a Smart vote),
    /// three in all, like the web.
    public static func pick(score: Int, rotation: Int) -> [FollowUpQuestion] {
        var rest: [FollowUpQuestion] = [.task, .session, .languages, .frequency]
        if score == 0 { rest.insert(.wentWell, at: 2) }
        let start = ((rotation % rest.count) + rest.count) % rest.count
        let rotated = Array(rest[start...] + rest[..<start])
        return [.vsUsual] + rotated.prefix(2)
    }
}

/// POST /api/votes/details for one of this installation's own votes.
public struct DetailsBody: Encodable, Equatable, Sendable {
    public let agent: String
    public let source = "menu-bar"
    public let idempotencyKey: String
    public let answers: [String: Answer]

    public enum Answer: Encodable, Equatable, Sendable {
        case one(String), many([String])
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .one(let v): try c.encode(v)
            case .many(let v): try c.encode(v)
            }
        }
    }

    /// nil when nothing valid was picked.
    public init?(agent: String, key: String, question: FollowUpQuestion, values: [String]) {
        var seen = Set<String>()
        let picked = values.filter { question.choices.contains($0) && seen.insert($0).inserted }
        guard !picked.isEmpty, question.multi || picked.count == 1 else { return nil }
        self.agent = agent
        self.idempotencyKey = key
        self.answers = [question.rawValue: question.multi ? .many(picked) : .one(picked[0])]
    }
}

/// One follow-up round after an accepted vote, shown in the panel.
public struct FollowUpRound: Equatable, Sendable {
    public let agent: Agent
    public let key: String
    public let questions: [FollowUpQuestion]
    public var index = 0
    public var picked: [String] = []
    public var failed = false
    public let at: Date

    public init(agent: Agent, key: String, score: Int, rotation: Int, at: Date) {
        self.agent = agent
        self.key = key
        self.questions = FollowUpQuestion.pick(score: score, rotation: rotation)
        self.at = at
    }
    public var current: FollowUpQuestion? { questions.indices.contains(index) ? questions[index] : nil }
    public var finished: Bool { current == nil }
    public mutating func advance() { index += 1; picked = [] }
}
