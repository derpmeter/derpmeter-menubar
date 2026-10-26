import CoreGraphics
import Foundation

// Derp Smash: an optional desktop CRT you can smash. Hits stay local and never
// affect the Derp Score; only an explicitly chosen Smart / Meh / Dumb vote goes
// through the normal vote path. Each CRT that breaks is counted once (agent,
// model, Claude Code effort; no hit counts or timing) through `onBroken`.

public enum SmashWeapon: String, CaseIterable, Codable, Sendable, Identifiable {
    case hammer, bat
    public var id: String { rawValue }
    public var label: String { self == .hammer ? "Hammer" : "Baseball bat" }
}

/// How big the CRT is on the desktop. The vote prompt never shrinks below a
/// readable size.
public enum SmashSize: String, CaseIterable, Codable, Sendable, Identifiable {
    case small, medium, large
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    public var scale: CGFloat {
        switch self {
        case .small: return 0.6
        case .medium: return 0.8
        case .large: return 1
        }
    }
}

/// Window geometry for a size. Views are drawn at the base size and scaled.
public struct SmashLayout: Equatable, Sendable {
    public static let crtBase = CGSize(width: 220, height: 210)
    public static let promptBase = CGSize(width: 220, height: 176)
    public let crtScale: CGFloat
    public let promptScale: CGFloat
    public init(size: SmashSize) {
        crtScale = size.scale
        promptScale = max(size.scale, 0.85)
    }
    public var crt: CGSize { CGSize(width: Self.crtBase.width * crtScale, height: Self.crtBase.height * crtScale) }
    public var prompt: CGSize { CGSize(width: Self.promptBase.width * promptScale, height: Self.promptBase.height * promptScale) }
    /// The prompt hangs below the CRT; the window is as wide as the wider one.
    public func window(prompt visible: Bool) -> CGSize {
        visible ? CGSize(width: max(crt.width, prompt.width), height: crt.height + prompt.height) : crt
    }
}

/// Visual states. Hit reactions are a transient effect on top of these.
public enum SmashState: String, Equatable, Sendable {
    case idle, lightDamage, heavyDamage, broken
    /// Vote prompt open and a vote is allowed.
    case voting
    /// Vote prompt open while the vote cooldown is running.
    case cooldown
    case repairing
}

/// Result of an explicit vote from the prompt.
public enum SmashVoteResult: Equatable, Sendable {
    case accepted
    /// Saved in the offline queue (paused or offline); it is sent later.
    case queued(String)
    case limited(Date?)
    case failed(String)
}

/// Deterministic damage/vote state machine. Pure value type: no timers or I/O.
public struct SmashMachine: Equatable, Sendable {
    public static let promptAt = 5
    /// Faster clicks are ignored so animations never pile up.
    public static let minHitInterval: TimeInterval = 0.18
    static let maxHits = 99

    public private(set) var hits = 0
    public private(set) var state: SmashState = .idle
    public private(set) var cooldownUntil: Date?
    /// The user closed the prompt; more hits do not reopen it.
    public private(set) var promptDismissed = false
    private var lastHitAt: Date?

    public init() {}

    public var promptVisible: Bool { state == .voting || state == .cooldown }

    public static func damage(forHits hits: Int) -> SmashState {
        switch hits {
        case ..<1: return .idle
        case 1...2: return .lightDamage
        case 3...4: return .heavyDamage
        default: return .broken
        }
    }

    /// Registers a click. Returns false when ignored (rate limit or repairing).
    @discardableResult
    public mutating func hit(now: Date, cooldownUntil next: Date?) -> Bool {
        if state == .repairing { return false }
        if let lastHitAt, now.timeIntervalSince(lastHitAt) < Self.minHitInterval { return false }
        lastHitAt = now
        hits = min(hits + 1, Self.maxHits)
        if promptVisible { return true }
        state = Self.damage(forHits: hits)
        if hits >= Self.promptAt, !promptDismissed { openPrompt(now: now, cooldownUntil: next) }
        return true
    }

    /// Shows the prompt (automatically at five hits, or on request when broken).
    public mutating func openPrompt(now: Date, cooldownUntil next: Date?) {
        guard state != .repairing, hits >= Self.promptAt else { return }
        promptDismissed = false
        cooldownUntil = next.flatMap { $0 > now ? $0 : nil }
        state = cooldownUntil == nil ? .voting : .cooldown
    }

    /// Never traps the user: closing keeps the broken CRT, no vote.
    public mutating func dismissPrompt() {
        guard promptVisible else { return }
        promptDismissed = true
        cooldownUntil = nil
        state = Self.damage(forHits: hits)
    }

    /// A vote was refused because of the cooldown.
    public mutating func enterCooldown(until next: Date?, now: Date) {
        guard promptVisible else { return }
        cooldownUntil = next.flatMap { $0 > now ? $0 : nil }
        state = cooldownUntil == nil ? .voting : .cooldown
    }

    /// Called when the countdown ends while the prompt is open.
    public mutating func tick(now: Date) {
        if state == .cooldown, let cooldownUntil, cooldownUntil <= now {
            self.cooldownUntil = nil
            state = .voting
        }
    }

    public mutating func startRepair() {
        cooldownUntil = nil
        state = .repairing
    }

    /// Repair done: back to a pristine CRT with zero hits.
    public mutating func finishRepair() {
        guard state == .repairing else { return }
        self = SmashMachine()
    }

    /// Short screen caption for the current state.
    public var caption: String {
        switch state {
        case .idle: return "READY_"
        case .lightDamage: return "hmm. that hurt."
        case .heavyDamage: return "CRITICAL DERP DETECTED"
        case .broken:
            return hits > Self.promptAt ? "Rate your AI before smashing again?" : "SYSTEM ERROR: PATIENCE NOT FOUND"
        case .voting: return "AI.exe has stopped thinking"
        case .cooldown: return "AI.exe is cooling down"
        case .repairing: return "Have you tried turning the AI off and on again?"
        }
    }
}

/// Anything that can submit an explicit vote for the currently selected agent/model.
@MainActor
public protocol SmashVoter: AnyObject {
    /// When the next vote for the current agent/model is allowed (nil = now/unknown).
    func smashNextVoteAt() -> Date?
    func submitSmashVote(_ rating: Rating) async -> SmashVoteResult
}

/// Drives the machine and the vote prompt. One submission at a time.
@MainActor
public final class SmashController: ObservableObject {
    @Published public private(set) var machine = SmashMachine()
    @Published public private(set) var submitting = false
    @Published public private(set) var feedback: String?
    /// Increments on every accepted hit so views can play one impact animation.
    @Published public private(set) var impacts = 0

    public weak var voter: SmashVoter?
    /// Called once per CRT when it first breaks (the hit that opens the prompt).
    public var onBroken: (() -> Void)?
    /// Display language for the feedback this controller writes itself.
    public var language: Language = .en
    private let clock: () -> Date
    private let repairDuration: TimeInterval
    private var repairTask: Task<Void, Never>?
    private var cooldownTask: Task<Void, Never>?

    public init(voter: SmashVoter? = nil, repairDuration: TimeInterval = 0.9, clock: @escaping () -> Date = Date.init) {
        self.voter = voter
        self.repairDuration = repairDuration
        self.clock = clock
    }

    @discardableResult
    public func hit() -> Bool {
        let wasPrompt = machine.promptVisible
        // The cooldown is only read when the prompt is about to open: no polling.
        let opening = !wasPrompt && machine.hits + 1 >= SmashMachine.promptAt && !machine.promptDismissed
        let before = machine.hits
        guard machine.hit(now: clock(), cooldownUntil: opening ? voter?.smashNextVoteAt() : nil) else { return false }
        impacts &+= 1
        if before < SmashMachine.promptAt, machine.hits >= SmashMachine.promptAt { onBroken?() }
        if machine.promptVisible, !wasPrompt { feedback = nil; scheduleCooldownEnd() }
        return true
    }

    public func openPrompt() {
        machine.openPrompt(now: clock(), cooldownUntil: voter?.smashNextVoteAt())
        feedback = nil
        scheduleCooldownEnd()
    }

    public func dismissPrompt() {
        machine.dismissPrompt()
        cooldownTask?.cancel()
    }

    /// Explicit vote only. Ignored while one is in flight or during the cooldown.
    public func vote(_ rating: Rating) async {
        guard machine.state == .voting, !submitting, let voter else { return }
        submitting = true
        defer { submitting = false }
        let result = await voter.submitSmashVote(rating)
        switch result {
        case .accepted:
            feedback = L10n(language).smashVoteSent(rating)
            repair(keepFeedback: true)
        case .queued(let message):
            feedback = message
            repair(keepFeedback: true)
        case .limited(let next):
            machine.enterCooldown(until: next, now: clock())
            feedback = L10n(language).smashCooldown
            scheduleCooldownEnd()
        case .failed(let message):
            feedback = message
        }
    }

    public func repair(keepFeedback: Bool = false) {
        guard machine.state != .repairing else { return }
        if !keepFeedback { feedback = nil }
        cooldownTask?.cancel()
        machine.startRepair()
        repairTask?.cancel()
        let duration = repairDuration
        repairTask = Task { [weak self] in
            if duration > 0 { try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self?.machine.finishRepair()
        }
    }

    /// Disable: stop timers and forget local damage.
    public func reset() {
        repairTask?.cancel()
        cooldownTask?.cancel()
        machine = SmashMachine()
        feedback = nil
    }

    /// Await the pending repair (tests).
    public func waitForRepair() async { await repairTask?.value }

    private func scheduleCooldownEnd() {
        cooldownTask?.cancel()
        guard machine.state == .cooldown, let until = machine.cooldownUntil else { return }
        let delay = max(0, until.timeIntervalSince(clock()))
        cooldownTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.machine.tick(now: self.clock())
        }
    }
}

/// Local preferences. Default: off, so existing users see nothing new.
public struct SmashPreferences: Codable, Equatable, Sendable {
    public var enabled = false
    public var weapon: SmashWeapon = .hammer
    public var muted = false
    /// Off: the CRT sits just above the desktop; on: above other windows.
    public var keepOnTop = false
    public var size: SmashSize = .small
    /// Bottom-left of the CRT in global screen coordinates.
    public var origin: CGPoint?
    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled, weapon, muted, keepOnTop, size, origin }
    // Tolerant decoding: settings saved by older versions keep their values.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        weapon = (try? c.decodeIfPresent(SmashWeapon.self, forKey: .weapon)) ?? .hammer
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        keepOnTop = try c.decodeIfPresent(Bool.self, forKey: .keepOnTop) ?? false
        size = (try? c.decodeIfPresent(SmashSize.self, forKey: .size)) ?? .small
        origin = try c.decodeIfPresent(CGPoint.self, forKey: .origin)
    }
}

public struct SmashPreferencesStore {
    public static let key = "derpSmash"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> SmashPreferences {
        guard let data = defaults.data(forKey: Self.key),
              let prefs = try? JSONDecoder().decode(SmashPreferences.self, from: data) else { return SmashPreferences() }
        return prefs
    }
    public func save(_ prefs: SmashPreferences) {
        if let data = try? JSONEncoder().encode(prefs) { defaults.set(data, forKey: Self.key) }
    }
}

/// Window origin for the pet: the saved spot if it is still on a screen
/// (clamped fully inside that screen), else the bottom-right of the main screen.
public func smashPlacement(saved: CGPoint?, size: CGSize, screens: [CGRect], margin: CGFloat = 24) -> CGPoint {
    guard let main = screens.first else { return saved ?? .zero }
    func clamp(_ p: CGPoint, into r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), max(r.minX, r.maxX - size.width)),
                y: min(max(p.y, r.minY), max(r.minY, r.maxY - size.height)))
    }
    if let saved {
        let frame = CGRect(origin: saved, size: size)
        let best = screens.max { $0.intersection(frame).area < $1.intersection(frame).area }
        if let best, best.intersection(frame).area > 0 { return clamp(saved, into: best) }
    }
    return clamp(CGPoint(x: main.maxX - size.width - margin, y: main.minY + margin), into: main)
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
