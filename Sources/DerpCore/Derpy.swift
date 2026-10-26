import Foundation

/// Derpy, the optional mascot. Presentation only: it reflects the public Derp Score
/// and connection state, never code, screen contents or mood detection.
public enum DerpyMood: String, CaseIterable, Sendable {
    case smart, neutral, derpy, loading, offline

    public static func from(score: Double?, loading: Bool, offline: Bool) -> DerpyMood {
        if offline { return .offline }
        if loading && score == nil { return .loading }
        guard let score else { return .neutral }
        switch score {
        case ..<35: return .smart
        case ..<65: return .neutral
        default: return .derpy
        }
    }

    /// Text face, so no animated assets or extra permissions are needed.
    public var face: String {
        switch self {
        case .smart: return "(•‿•)"
        case .neutral: return "(•_•)"
        case .derpy: return "(⊙_☉)"
        case .loading: return "(·_·)"
        case .offline: return "(·_·)"
        }
    }

    public var caption: String {
        switch self {
        case .smart: return "Feeling smart today"
        case .neutral: return "Meh-ish"
        case .derpy: return "Derp levels elevated"
        case .loading: return "Checking the vibes…"
        case .offline: return "Offline: showing cached score"
        }
    }
}

/// Same faces and thresholds as CLI statusline.mjs mood mode (without its model field).
public func statuslineMoodFace(score: Double?) -> String {
    guard let score else { return "(·_·)" }
    return score < 35 ? "(•‿•)" : score < 65 ? "(•_•)" : "(⊙_☉)"
}

/// Low-sample, agent and connection details stay in the tooltip and panel.
public func menuBarTitle(snapshot: IndexSnapshot?, agent: Agent) -> String {
    let score = snapshot?.leadScore(agent)
    let value = score.map { String(Int($0.rounded())) } ?? "—"
    return "\(statuslineMoodFace(score: score)) · Derp \(value)"
}
