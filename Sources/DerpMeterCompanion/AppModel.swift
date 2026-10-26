import AppKit
import DerpCore
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    // Preferences (UserDefaults). The token is in the Keychain, never here.
    /// Built in and not shown in the UI. Development only: `defaults write
    /// com.derpmeter.companion endpoint <origin>` overrides it.
    static let defaultEndpoint = "https://derpmeter.com"
    @Published var endpoint: String {
        didSet {
            let value = endpoint.trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value == Self.defaultEndpoint { defaults.removeObject(forKey: "endpoint") }
            else { defaults.set(value, forKey: "endpoint") }
            refreshSoon()
        }
    }
    var usesDefaultEndpoint: Bool { endpoint == Self.defaultEndpoint }
    @Published var agent: Agent { didSet { defaults.set(agent.rawValue, forKey: "agent") } }
    @Published var showMascot: Bool { didSet { defaults.set(showMascot, forKey: "showMascot") } }
    @Published var notifyVotes: Bool { didSet { defaults.set(notifyVotes, forKey: "notifyVotes"); requestNotifications() } }
    @Published var notifyScoreJumps: Bool { didSet { defaults.set(notifyScoreJumps, forKey: "notifyScoreJumps"); requestNotifications() } }
    @Published var useLocalSession: Bool { didSet { defaults.set(useLocalSession, forKey: "useLocalSession") } }
    /// Opt-in: read the configured default model of Codex / Antigravity (one key each).
    @Published var detectConfiguredModels: Bool {
        didSet { defaults.set(detectConfiguredModels, forKey: "detectConfiguredModels"); reloadSession() }
    }
    /// Per agent: automatic, no model, or an explicit catalog model.
    @Published private(set) var modelChoices: [String: String]
    @Published var paused: Bool { didSet { defaults.set(paused, forKey: "paused") } }
    @Published var hotkeysEnabled: Bool { didSet { defaults.set(hotkeysEnabled, forKey: "hotkeys"); applyHotKeys() } }
    /// Display language: follows macOS by default; switching applies live.
    /// Status messages already shown are dropped so no mixed-language text remains.
    @Published var languagePreference: LanguagePreference {
        didSet {
            if languagePreference == .system { defaults.removeObject(forKey: "language") }
            else { defaults.set(languagePreference.rawValue, forKey: "language") }
            status = nil
        }
    }
    /// Derp Smash desktop pet (off by default). Stored separately from other prefs.
    @Published var smash: SmashPreferences { didSet { if smash != oldValue { SmashPreferencesStore(defaults: defaults).save(smash) } } }

    // State.
    @Published private(set) var snapshot: IndexSnapshot?
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var loading = false
    @Published private(set) var offline = false
    @Published private(set) var queue = OfflineQueue()
    @Published private(set) var session: ObservedSession?
    @Published private(set) var configuredModels: [Agent: String] = [:]
    @Published private(set) var configuredEffort: String?
    /// Claude Code is in use right now (opt-in observation only); the Derp
    /// Smash CRT plays scrolling output while it is.
    @Published private(set) var claudeActive = false
    @Published var status: String?
    @Published var hasToken = false
    @Published private(set) var tokenAccessPending = false
    @Published private(set) var voteStatus: VoteStatus?
    @Published private(set) var voteStatusAt: Date?
    /// A newer release advertised by /api/version (checked every 6 hours).
    @Published private(set) var update: UpdateNotice?
    private var versionCheckedAt: Date?
    /// Bundled builds only; `swift run` has no version and never prompts.
    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    private let defaults = UserDefaults.standard
    private let support: URL
    @Published private(set) var catalog: ModelCatalog?
    private var timer: Timer?
    private var hotKeys: HotKeys?
    private var lastNotifiedScore: Double?
    private var checkingVoteStatus = false
    private var flushing = false

    init() {
        // Older versions stored the default URL; drop it so the built-in one applies.
        if defaults.string(forKey: "endpoint") == Self.defaultEndpoint { defaults.removeObject(forKey: "endpoint") }
        endpoint = defaults.string(forKey: "endpoint") ?? Self.defaultEndpoint
        agent = Agent(rawValue: defaults.string(forKey: "agent") ?? "") ?? .claudeCode
        showMascot = defaults.object(forKey: "showMascot") as? Bool ?? false
        notifyVotes = defaults.bool(forKey: "notifyVotes")
        notifyScoreJumps = defaults.bool(forKey: "notifyScoreJumps")
        useLocalSession = defaults.bool(forKey: "useLocalSession")
        detectConfiguredModels = defaults.bool(forKey: "detectConfiguredModels")
        modelChoices = defaults.dictionary(forKey: "modelChoices") as? [String: String] ?? [:]
        paused = defaults.bool(forKey: "paused")
        hotkeysEnabled = defaults.bool(forKey: "hotkeys")
        smash = SmashPreferencesStore(defaults: UserDefaults.standard).load()
        languagePreference = LanguagePreference(rawValue: defaults.string(forKey: "language") ?? "") ?? .system
        support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DerpMeter", isDirectory: true)
        queue = queueStore.load() ?? OfflineQueue()
        if let cached = cacheStore.load() {
            snapshot = cached.snapshot
            fetchedAt = cached.fetchedAt
        }
        applyHotKeys()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    private struct Cache: Codable { let snapshot: IndexSnapshot; let fetchedAt: Date }
    private var cacheStore: JSONStore<Cache> { JSONStore(url: support.appendingPathComponent("index-cache.json")) }
    private var queueStore: JSONStore<OfflineQueue> { JSONStore(url: support.appendingPathComponent("queue.json")) }
    var client: APIClient? { APIClient(origin: endpoint.isEmpty ? Self.defaultEndpoint : endpoint) }

    var language: Language { languagePreference.resolve() }
    /// Strings in the current display language.
    var t: L10n { L10n(language) }

    var title: String { menuBarTitle(snapshot: snapshot, agent: agent) }
    var mood: DerpyMood { DerpyMood.from(score: snapshot?.leadScore(agent), loading: loading, offline: offline) }
    var pendingCount: Int { queue.items.filter { $0.state == .pending }.count }

    func refreshSoon() { Task { await refresh() } }

    func refresh() async {
        reloadSession()
        guard !paused, let client else { return }
        loading = true
        defer { loading = false }
        do {
            let next = try await client.fetchIndex()
            snapshot = next
            fetchedAt = Date()
            offline = false
            try? cacheStore.save(Cache(snapshot: next, fetchedAt: fetchedAt!))
            if catalog == nil { catalog = try? await client.fetchCatalog() }
            loading = false
            checkScoreJump()
            // Before the Keychain read below, which can wait on an access prompt.
            await checkForUpdate(client)
            await flush()
            await refreshVoteStatus()
        } catch {
            offline = true
        }
    }

    func refreshVoteStatus() async {
        guard !paused, !checkingVoteStatus, let client else { return }
        checkingVoteStatus = true
        tokenAccessPending = true
        defer { checkingVoteStatus = false; tokenAccessPending = false }
        guard let token = await Task.detached(operation: { TokenStore.read() }).value else { return }
        hasToken = true
        if let status = try? await client.fetchVoteStatus(token: token) {
            voteStatus = status
            voteStatusAt = Date()
        }
    }

    /// When the selected agent can be voted on again with the model a vote
    /// would carry (nil = now). The cooldown is per agent and model.
    func availableAt(_ agent: Agent) -> Date? {
        guard let voteStatus, let voteStatusAt,
              let at = voteStatus.availableAt(agent, model: voteModel(for: agent), fetchedAt: voteStatusAt),
              at > Date() else { return nil }
        return at
    }

    func modelChoice(for agent: Agent) -> ModelChoice { ModelChoice(storageValue: modelChoices[agent.rawValue]) }

    func setModelChoice(_ choice: ModelChoice, for agent: Agent) {
        modelChoices[agent.rawValue] = choice.storageValue
        defaults.set(modelChoices, forKey: "modelChoices")
    }

    /// Catalog models offered for an agent (current ones, as served by /api/models).
    func models(for agent: Agent) -> [ModelCatalog.Entry] {
        catalog?.models.filter { $0.agent == agent.rawValue } ?? []
    }

    func modelName(_ id: String, for agent: Agent) -> String { catalog?.name(of: id, for: agent) ?? id }

    /// Detected model: the agent's own configured default (opt-in), or the
    /// opt-in Claude Code session observation, which wins when fresh. `id` is
    /// the matching catalog model (nil when the value has no DerpMeter match).
    func detectedModel(for agent: Agent) -> (raw: String, id: String?, source: L10n.ModelSource)? {
        guard detectConfiguredModels else { return nil }
        let found: (String, L10n.ModelSource)?
        if let observed = session, observed.agent == agent, let raw = observed.model { found = (raw, .session) }
        else if let raw = configuredModels[agent] { found = (raw, .settings) }
        else { found = nil }
        guard let (raw, source) = found else { return nil }
        return (raw, LocalModelSettings.resolve(raw, agent: agent, catalog: catalog), source)
    }

    /// The model a vote for this agent would carry (catalog-listed only).
    func voteModel(for agent: Agent) -> String? {
        modelChoice(for: agent).resolve(detected: detectedModel(for: agent)?.raw, agent: agent, catalog: catalog)
    }

    /// Session-linked only when the vote's model really came from the observed session.
    private func sessionLinked(for agent: Agent, model: String?) -> Bool {
        guard detectConfiguredModels, modelChoice(for: agent) == .auto, let observed = session, observed.agent == agent else { return false }
        return LocalModelSettings.resolve(observed.model, agent: agent, catalog: catalog).map { $0 == model } ?? false
    }

    /// Display name of the model a vote would carry right now, if any.
    var voteModelName: String? {
        guard let id = voteModel(for: agent) else { return nil }
        return modelName(id, for: agent)
    }

    func reloadSession() {
        session = useLocalSession
            ? LocalIntegration.recentSession(data: try? Data(contentsOf: LocalIntegration.observationFile()), now: Date())
            : nil
        var configured: [Agent: String] = [:]
        if detectConfiguredModels {
            for agent in Agent.allCases { configured[agent] = LocalModelSettings.configuredModel(for: agent) }
        }
        if configured != configuredModels { configuredModels = configured }
        let effort = detectConfiguredModels ? LocalModelSettings.configuredClaudeEffort() : nil
        if effort != configuredEffort { configuredEffort = effort }
    }

    func refreshClaudeActivity() {
        let active = useLocalSession
            && LocalIntegration.claudeCodeActive(data: try? Data(contentsOf: LocalIntegration.observationFile()), now: Date())
        if active != claudeActive { claudeActive = active }
    }

    /// Claude Code effort, detected like the model: the opt-in session
    /// observation when it supplied the model, else the configured default.
    func detectedEffort(for agent: Agent) -> String? {
        guard agent == .claudeCode, let detected = detectedModel(for: agent) else { return nil }
        if detected.source == .session { return session?.effort ?? configuredEffort }
        return configuredEffort
    }

    /// One-click vote: queued first, then sent; retries reuse the same key.
    func vote(_ rating: Rating, reason: FailureReason? = nil) {
        guard let client else { status = t.invalidEndpoint; return }
        reloadSession()
        if let at = availableAt(agent) {
            status = t.nextAgentVote(agent, seconds: at.timeIntervalSinceNow)
            return
        }
        let model = voteModel(for: agent)
        let body = VoteBody(agent: agent, rating: rating, model: model, reason: reason, sessionLinked: sessionLinked(for: agent, model: model))
        do {
            try queue.enqueue(body, origin: client.origin.absoluteString, now: Date())
            persistQueue()
            status = paused ? t.pausedQueued : t.sending(rating)
        } catch {
            status = t.queueFull
            return
        }
        if !paused { Task { await flush() } }
    }

    /// First use: get a token automatically and keep it in the Keychain.
    @discardableResult
    func ensureToken(replace: Bool = false) async -> String? {
        if !replace {
            if let token = await Task.detached(operation: { TokenStore.read() }).value { return token }
            if await Task.detached(operation: { TokenStore.containsToken }).value {
                status = t.keychainUnavailableVote
                return nil
            }
        }
        guard let client else { return nil }
        do {
            let token = try await client.enroll()
            guard TokenStore.save(token) else { status = t.tokenSaveFailed; return nil }
            hasToken = true
            return token
        } catch APIClient.EnrollError.limited(let message) {
            status = message // server text, shown as sent
        } catch {
            status = t.enrollFailed
        }
        return nil
    }

    func flush() async {
        guard !paused, !flushing, let client else { return }
        flushing = true
        defer { flushing = false }
        let now = Date()
        queue.expire(now: now)
        let due = queue.due(now: now, origin: client.origin.absoluteString)
        guard !due.isEmpty else { persistQueue(); return }
        guard let initial = await ensureToken() else { return }
        var token = initial
        var reenrolled = false
        for item in due {
            var outcome = await client.submit(item.body, token: token)
            // Expired or revoked token: enroll a new one once and resend the same vote.
            if outcome == .unauthorized, !reenrolled, let fresh = await ensureToken(replace: true) {
                reenrolled = true
                token = fresh
                outcome = await client.submit(item.body, token: token)
            }
            queue.record(item.id, outcome: outcome, now: Date())
            report(outcome, agent: item.body.agent)
        }
        persistQueue()
        await refreshVoteStatus()
    }

    func cancelLastVote() {
        guard let client,
              let receipt = queue.latestReceipt(agent: agent, origin: client.origin.absoluteString, now: Date())
        else { status = t.noRecentVote; return }
        Task {
            guard let token = await Task.detached(operation: { TokenStore.read() }).value else {
                status = t.keychainUnavailable
                return
            }
            let outcome = await client.cancel(key: receipt.key, token: token)
            if case .accepted = outcome { queue.dropReceipt(receipt.key); status = t.voteCancelled }
            else if outcome == .cancelled { queue.dropReceipt(receipt.key); status = t.alreadyCancelled }
            else { status = t.cancelFailed(t.outcome(outcome)) }
            persistQueue()
        }
    }

    func discard(_ key: String) { queue.discard(key); persistQueue() }

    func setToken(_ token: String) -> Bool {
        guard TokenStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        hasToken = true
        queue.resumeUnauthorized(now: Date())
        persistQueue()
        Task { await flush() }
        return true
    }

    func removeToken() { TokenStore.delete(); hasToken = false }

    /// Clears local state only. Accepted votes on the server are unaffected.
    func clearLocalState() {
        queue = OfflineQueue()
        snapshot = nil
        fetchedAt = nil
        try? FileManager.default.removeItem(at: support)
        status = t.localCleared
    }

    private func persistQueue() { try? queueStore.save(queue) }

    private func report(_ outcome: SendOutcome, agent: String) {
        let text = t.outcome(outcome)
        status = text
        if notifyVotes, outcome != .retryable { notify(title: "DerpMeter", body: text) }
    }

    private func checkForUpdate(_ client: APIClient) async {
        if let at = versionCheckedAt, Date().timeIntervalSince(at) < 6 * 3600 { return }
        guard let versions = try? await client.fetchVersions() else { return }
        versionCheckedAt = Date()
        update = UpdateNotice.from(current: Self.appVersion, versions: versions)
        // One notification per release, and only when notifications are already on.
        guard let update, notifyVotes || notifyScoreJumps,
              defaults.string(forKey: "notifiedUpdate") != update.latest else { return }
        defaults.set(update.latest, forKey: "notifiedUpdate")
        notify(title: t.updateAvailable(update.latest), body: t.updateNotificationBody(Self.appVersion ?? ""))
    }

    func openUpdatePage() {
        NSWorkspace.shared.open((client?.origin ?? URL(string: Self.defaultEndpoint)!).appendingPathComponent("apps"))
    }

    private func checkScoreJump() {
        guard notifyScoreJumps, let score = snapshot?.leadScore(agent), (snapshot?.leadSample(agent) ?? 0) >= 30 else { return }
        if let last = lastNotifiedScore, score - last >= 10 {
            notify(title: t.scoreJumpTitle(Int(score - last)), body: t.scoreJumpBody(agent, score: Int(score)))
        }
        lastNotifiedScore = score
    }

    // Notifications and login items need a bundled, signed app; degrade gracefully otherwise.
    private var bundled: Bool { Bundle.main.bundleIdentifier != nil }

    private func requestNotifications() {
        guard bundled, notifyVotes || notifyScoreJumps else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        guard bundled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            guard bundled else { status = t.launchNeedsBundle; return }
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                status = t.launchFailed
            }
            objectWillChange.send()
        }
    }

    private func applyHotKeys() {
        if hotkeysEnabled {
            hotKeys = hotKeys ?? HotKeys { [weak self] index in
                self?.vote([Rating.smart, .meh, .dumb][index])
            }
            hotKeys?.register()
        } else {
            hotKeys?.unregister()
            hotKeys = nil
        }
    }
}

/// Derp Smash votes reuse the normal queue, flush and cooldown.
extension AppModel: SmashVoter {
    /// A CRT broke: count it with the current agent, model and effort. Only
    /// with an existing token and not paused; failures are dropped silently.
    func recordSmash() {
        guard !paused, let client else { return }
        reloadSession()
        let body = SmashBody(agent: agent, model: voteModel(for: agent), effort: detectedEffort(for: agent))
        Task.detached {
            guard let token = TokenStore.read() else { return }
            _ = await client.reportSmash(body, token: token)
        }
    }

    func smashNextVoteAt() -> Date? { availableAt(agent) }

    func submitSmashVote(_ rating: Rating) async -> SmashVoteResult {
        guard let client else { return .failed(t.invalidEndpoint) }
        reloadSession()
        if let at = availableAt(agent) { return .limited(at) }
        let model = voteModel(for: agent)
        let body = VoteBody(agent: agent, rating: rating, model: model, reason: nil, sessionLinked: sessionLinked(for: agent, model: model))
        let key = body.idempotencyKey
        do {
            try queue.enqueue(body, origin: client.origin.absoluteString, now: Date())
            persistQueue()
        } catch {
            return .failed(t.queueFull)
        }
        if paused {
            status = t.pausedQueued
            return .queued(t.smashPausedSaved)
        }
        await flush()
        if queue.receipts.contains(where: { $0.key == key }) { return .accepted }
        guard let item = queue.items.first(where: { $0.id == key }) else { return .accepted }
        switch item.state {
        case .pending: return .queued(t.smashOfflineQueued)
        case .limited: return .limited(availableAt(agent))
        case .unauthorized: return .failed(t.smashTokenRejected)
        case .conflict, .rejected, .expired: return .failed(item.message ?? t.smashNotAccepted)
        }
    }
}
