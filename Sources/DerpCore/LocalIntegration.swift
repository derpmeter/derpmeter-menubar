import Foundation

/// Explicit local integration: reads only the opt-in observation file written by the
/// DerpMeter CLI statusline (`derp privacy session on`). No process, transcript or
/// screen scanning, and no other files are read.
public struct ObservedSession: Equatable, Sendable {
    public let agent: Agent
    public let model: String?
    public let seenAt: Date
}

public enum LocalIntegration {
    public static let freshness: TimeInterval = 15 * 60

    public static func observationFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = environment["DERPMETER_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".derpmeter").path
        return URL(fileURLWithPath: home).appendingPathComponent("observed.json")
    }

    /// Most recent fresh observation, if any. Malformed or stale data yields nil.
    public static func recentSession(data: Data?, now: Date) -> ObservedSession? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let modelPattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9.-]{1,79}$")
        var best: ObservedSession?
        for agent in Agent.allCases {
            guard let entry = json[agent.rawValue] as? [String: Any],
                  let ms = entry["seenAt"] as? Double else { continue }
            let seenAt = Date(timeIntervalSince1970: ms / 1000)
            let age = now.timeIntervalSince(seenAt)
            guard age >= 0, age < freshness else { continue }
            var model = entry["model"] as? String
            if let m = model, modelPattern.firstMatch(in: m, range: NSRange(m.startIndex..., in: m)) == nil { model = nil }
            if best == nil || seenAt > best!.seenAt { best = ObservedSession(agent: agent, model: model, seenAt: seenAt) }
        }
        return best
    }
}

/// Opt-in: each agent's *configured default* model, read from one documented
/// key (same rules as the CLI's agents.mjs). Not proof of the model used in a
/// session. Nothing else in these files is read, and nothing is sent except
/// the model id of an explicit vote.
public enum LocalModelSettings {
    private static let modelPattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9.-]{1,79}$")
    private static func valid(_ value: String?) -> String? {
        guard let value, modelPattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil else { return nil }
        return value
    }

    /// Codex: top-level `model = "…"` in config.toml; tables are ignored.
    public static func codexModel(toml: String) -> String? {
        for line in toml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard trimmed.hasPrefix("model"),
                  let regex = try? NSRegularExpression(pattern: #"^model\s*=\s*"([^"]+)"\s*(#.*)?$"#),
                  let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                  let range = Range(match.range(at: 1), in: trimmed) else { continue }
            return valid(String(trimmed[range]))
        }
        return nil
    }

    /// Antigravity CLI (and the retired Gemini CLI): `model.name` in
    /// ~/.gemini/settings.json (older releases used a string `model`).
    public static func antigravityModel(json data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let model = object["model"] as? String { return valid(model) }
        return valid((object["model"] as? [String: Any])?["name"] as? String)
    }

    /// Claude Code: `model` in its user settings (~/.claude/settings.json or
    /// $CLAUDE_CONFIG_DIR). May be a full id or an alias such as "opus".
    public static func claudeModel(json data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["model"] as? String,
              value.range(of: #"^[A-Za-z0-9.\[\]-]{1,80}$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    /// Maps a configured value to a catalog id for the agent (same rules as the
    /// CLI): exact ids win ("[1m]" and date suffixes ignored); a Claude alias
    /// maps to the single current catalog model of that family, else nothing.
    public static func resolve(_ raw: String?, agent: Agent, catalog: ModelCatalog?) -> String? {
        guard let raw, let catalog else { return nil }
        let ids = catalog.models.filter { $0.agent == agent.rawValue }.map(\.id)
        var id = raw.lowercased()
        if id.hasSuffix("[1m]") { id.removeLast(4) }
        if let range = id.range(of: #"-\d{8}$"#, options: .regularExpression) { id.removeSubrange(range) }
        if ids.contains(id) { return id }
        guard agent == .claudeCode else { return nil }
        let family = id == "opusplan" ? "opus" : id
        guard ["opus", "sonnet", "haiku", "fable"].contains(family) else { return nil }
        let matches = ids.filter { $0.hasPrefix("claude-\(family)-") }
        return matches.count == 1 ? matches[0] : nil
    }

    public static func configuredModel(for agent: Agent,
                                        environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch agent {
        case .codex:
            let dir = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
            return (try? String(contentsOf: dir.appendingPathComponent("config.toml"), encoding: .utf8)).flatMap { codexModel(toml: $0) }
        case .geminiCli:
            return (try? Data(contentsOf: home.appendingPathComponent(".gemini/settings.json"))).flatMap { antigravityModel(json: $0) }
        case .claudeCode:
            let dir = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
            return (try? Data(contentsOf: dir.appendingPathComponent("settings.json"))).flatMap { claudeModel(json: $0) }
        }
    }
}

/// Which model a vote carries for one agent: automatic (detected, if any),
/// explicitly none, or a catalog model.
public enum ModelChoice: Equatable, Sendable {
    case auto
    case none
    case model(String)

    public var storageValue: String {
        switch self {
        case .auto: return ""
        case .none: return "-"
        case .model(let id): return id
        }
    }

    public init(storageValue: String?) {
        switch storageValue {
        case nil, "": self = .auto
        case "-": self = .none
        case let id?: self = .model(id)
        }
    }

    /// The model id to send. Explicit models must still be in the catalog;
    /// automatic detection only counts when the catalog lists it for the agent.
    public func resolve(detected: String?, agent: Agent, catalog: ModelCatalog?) -> String? {
        switch self {
        case .none: return nil
        case .model(let id): return catalog?.contains(id, for: agent) == true ? id : nil
        case .auto:
            return LocalModelSettings.resolve(detected, agent: agent, catalog: catalog)
        }
    }
}
