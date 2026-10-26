import Foundation

// Display text only: English and Korean, switched live. An in-code table (not
// .lproj) because bundle.sh assembles the app by hand and the panel switches
// without relaunch. API payloads, ids and stored values never go through here.
// Brand names (DerpMeter, Derp Smash, agent and model names) are not translated.

/// A resolved display language.
public enum Language: String, CaseIterable, Sendable {
    case en, ko

    public var locale: Locale { Locale(identifier: self == .ko ? "ko_KR" : "en_US") }

    /// Korean when the first preferred language is Korean (`ko`, `ko-KR`, …), else English.
    public static func fromPreferred(_ preferred: [String]) -> Language {
        guard let first = preferred.first?.lowercased() else { return .en }
        return first == "ko" || first.hasPrefix("ko-") || first.hasPrefix("ko_") ? .ko : .en
    }
}

/// The user's choice in Settings (UserDefaults key `language`). Default: follow the device.
public enum LanguagePreference: String, CaseIterable, Codable, Sendable, Identifiable {
    case system, en, ko
    public var id: String { rawValue }

    /// An explicit choice wins; `system` follows macOS preferred languages.
    public func resolve(preferred: [String] = Locale.preferredLanguages) -> Language {
        switch self {
        case .system: return Language.fromPreferred(preferred)
        case .en: return .en
        case .ko: return .ko
        }
    }
}

/// All user-visible strings. `L10n(.ko).chooseAgent` → "에이전트 선택".
public struct L10n: Sendable {
    public let language: Language
    public init(_ language: Language) { self.language = language }

    private var ko: Bool { language == .ko }
    private func t(_ en: String, _ ko: String) -> String { self.ko ? ko : en }

    // MARK: Shared vocabulary

    public func rating(_ rating: Rating) -> String {
        switch rating {
        case .smart: return t("Smart", "똑똑함")
        case .meh: return t("Meh", "애매함")
        case .dumb: return t("Dumb", "멍청함")
        }
    }

    public func reason(_ reason: FailureReason) -> String {
        switch reason {
        case .instructionFailure: return t("Ignored instructions", "지시 무시")
        case .hallucination: return t("Hallucination", "환각")
        case .repeatedMistake: return t("Repeated mistake", "같은 실수 반복")
        case .poorOutput: return t("Poor output", "결과물 품질 낮음")
        case .tooSlow: return t("Too slow", "작업이 느림")
        case .other: return t("Other", "기타")
        }
    }

    public func weapon(_ weapon: SmashWeapon) -> String {
        weapon == .hammer ? t("Hammer", "망치") : t("Baseball bat", "야구 방망이")
    }

    public func size(_ size: SmashSize) -> String {
        switch size {
        case .small: return t("Small", "작게")
        case .medium: return t("Medium", "보통")
        case .large: return t("Large", "크게")
        }
    }

    public func languageOption(_ preference: LanguagePreference) -> String {
        switch preference {
        case .system: return t("System", "시스템")
        case .en: return "English"
        case .ko: return "한국어"
        }
    }

    /// "38 min" / "38분", "1 h 5 min" / "1시간 5분", "<1 min" / "1분 미만".
    public func wait(_ seconds: TimeInterval) -> String {
        guard ko else { return waitText(seconds) }
        if seconds < 60 { return "1분 미만" }
        let m = Int((seconds / 60).rounded(.up))
        return m < 60 ? "\(m)분" : "\(m / 60)시간" + (m % 60 > 0 ? " \(m % 60)분" : "")
    }

    public var derpScore: String { t("Derp Score", "멍청 지수") }
    public var sentimentNotBenchmark: String { t("Sentiment, not a benchmark.", "체감이며 벤치마크가 아니에요.") }

    // MARK: Menu bar item (tooltip and VoiceOver)

    public func statusSentiment(score: Double?) -> String {
        guard let score else { return noVotesYet }
        return rating(score < 35 ? .smart : score < 65 ? .meh : .dumb)
    }
    public var noVotesYet: String { t("No votes yet", "아직 투표 없음") }
    public var lowSampleDetail: String { t("Low sample (<30)", "표본 적음 (30 미만)") }
    public var pausedDetail: String { t("Paused", "일시 정지됨") }
    public var offlineDetail: String { t("Offline, cached index", "오프라인, 캐시된 지수") }

    // MARK: Panel

    public var connectionPaused: String { t("PAUSED", "일시 정지") }
    public var connectionSetup: String { t("SETUP NEEDED", "설정 필요") }
    public var connectionOffline: String { t("OFFLINE · CACHED", "오프라인 · 캐시") }
    public var connectionSyncing: String { t("SYNCING", "동기화 중") }
    public var connectionDemo: String { t("DEMO DATA", "데모 데이터") }
    public var connectionConnecting: String { t("CONNECTING", "연결 중") }
    public var connectionLive: String { t("COMMUNITY PULSE", "커뮤니티 체감") }

    /// The headline in three parts; the middle one is highlighted.
    public var headline: (String, String, String) {
        ko ? ("오늘 AI, 얼마나 ", "멍청한", "가요?") : ("How ", "derpy", " is your AI today?")
    }
    public var chooseAgent: String { t("Choose your agent", "에이전트 선택") }
    public var past24h: String { t("PAST 24H", "최근 24시간") }
    public var past7d: String { t("PAST 7 DAYS", "최근 7일") }
    public var faintDays: String { t("FAINT = SAMPLE UNDER 10", "흐린 막대 = 표본 10 미만") }
    /// Components of the blended score: "Votes 14.3 (7) · Radar 35.2 (685)".
    public func partsLine(votes: String, votesN: Int, radar: String?, radarN: Int) -> String {
        let v = t("Votes \(votes) (\(votesN))", "투표 \(votes) (\(votesN)표)")
        guard let radar else { return v + t(" · Radar unavailable", " · Radar 없음") }
        return v + t(" · Radar \(radar) (\(radarN))", " · Radar \(radar) (\(radarN)건)")
    }
    public func blendNote(_ weight: Int) -> String {
        t("Votes + Radar posts · 1 vote = \(weight) posts", "투표 + Radar 게시물 · 1표 = 게시물 \(weight)건")
    }
    public func agentHelp(_ agent: Agent, sample: Int) -> String {
        t("\(agent.displayName) · weighted sample \(sample) (votes and Radar posts)",
          "\(agent.displayName) · 가중 표본 \(sample) (투표와 Radar 게시물)")
    }
    public func selectAgentAccessibility(_ agent: Agent, score: String?, sample: Int) -> String {
        t("Select \(agent.displayName), Derp Score \(score ?? "unavailable"), sample \(sample)",
          "\(agent.displayName) 선택, 멍청 지수 \(score ?? "없음"), 표본 \(sample)")
    }
    public var derpScoreTag: String { t("/ DERP SCORE", "/ 멍청 지수") }
    public var noVotesYetTag: String { t("NO VOTES YET", "아직 투표 없음") }
    public var lowSampleTag: String { t("LOW SAMPLE", "표본 적음") }
    public func scoreAccessibility(_ score: String?) -> String {
        guard let score else { return t("No Derp Score yet", "아직 멍청 지수 없음") }
        return t("Derp Score \(score) out of 100", "멍청 지수 100점 중 \(score)점")
    }
    public var scaleSmart: String { t("SMART", "똑똑함") }
    public var scaleDumb: String { t("DUMB", "멍청함") }
    public var scaleHint: String { t("HIGHER = DERPIER", "높을수록 멍청함") }
    public var demoNotice: String { t("DEMO · Synthetic data, not real votes", "데모 · 실제 투표가 아닌 합성 데이터") }

    // Model step.
    public var whichModel: String { t("Which model?", "어떤 모델인가요?") }
    public var modelPickerLabel: String { t("Model", "모델") }
    public func autoModel(_ name: String?) -> String {
        name.map { t("Auto · \($0)", "자동 · \($0)") } ?? t("Auto · none detected", "자동 · 감지 안 됨")
    }
    public var noModel: String { t("No model", "모델 없음") }
    public func modelAccessibility(_ agent: Agent) -> String { t("Model for \(agent.displayName)", "\(agent.displayName) 모델") }
    /// Where a detected model came from.
    public enum ModelSource: Sendable { case session, settings }
    public func modelFrom(_ agent: Agent, source: ModelSource) -> String {
        switch source {
        case .session: return t("From your \(agent.displayName) current session", "\(agent.displayName) 현재 세션에서 가져옴")
        case .settings: return t("From your \(agent.displayName) settings", "\(agent.displayName) 설정에서 가져옴")
        }
    }
    public func modelUnlisted(_ raw: String, source: ModelSource) -> String {
        switch source {
        case .session: return t("Your current session says \(raw), which isn't a DerpMeter model; pick one.",
                                "현재 세션의 \(raw)은(는) DerpMeter 모델이 아니에요. 직접 골라 주세요.")
        case .settings: return t("Your settings say \(raw), which isn't a DerpMeter model; pick one.",
                                 "설정의 \(raw)은(는) DerpMeter 모델이 아니에요. 직접 골라 주세요.")
        }
    }
    public var noModelInSettings: String {
        t("No model set in this agent's settings; pick one.", "이 에이전트 설정에 모델이 없어요. 직접 골라 주세요.")
    }
    public var turnOnDetection: String {
        t("Turn on model detection in Settings, or pick one.", "설정에서 모델 감지를 켜거나 직접 골라 주세요.")
    }

    // Vote step.
    public var howDidItDo: String { t("How did it do?", "오늘 어땠나요?") }
    public var queuesOffline: String { t("QUEUES OFFLINE", "오프라인 대기") }
    public var oneClick: String { t("ONE CLICK TO VOTE", "클릭 한 번으로 투표") }
    public var votingUnavailable: String {
        t("Voting is unavailable: invalid developer endpoint override.", "투표할 수 없어요: 개발용 엔드포인트 설정이 잘못됐어요.")
    }
    public func voteAccessibility(_ rating: Rating, agent: Agent) -> String {
        t("Vote \(self.rating(rating)) for \(agent.displayName)", "\(agent.displayName)에 \(self.rating(rating)) 투표")
    }
    /// Cooldown line: "Next vote in 12 min" / "12분 후 다시 투표 가능".
    public func nextVoteIn(_ seconds: TimeInterval) -> String {
        t("Next vote in \(wait(seconds))", "\(wait(seconds)) 후 다시 투표 가능")
    }
    public var failureReason: String { t("Failure reason", "문제 유형") }
    public var noReason: String { t("No reason", "이유 없음") }
    public var reasonHint: String { t("Applies to Meh / Dumb votes only.", "애매함 / 멍청함 투표에만 적용돼요.") }
    public var addReason: String { t("Add a reason (optional)", "뭐가 문제였나요? (선택)") }
    public var privacyLine: String { t("No prompts. No code. Just your take.", "프롬프트도 코드도 보내지 않아요. 평가만 보내요.") }
    public func voteStatusAccessibility(_ status: String) -> String { t("Vote status: \(status)", "투표 상태: \(status)") }

    // Queue.
    public func queueTitle(_ count: Int) -> String { t("Queue · \(count)", "대기열 · \(count)") }
    public var discard: String { t("Discard", "삭제") }
    public func queueState(_ state: PendingVote.State) -> String {
        switch state {
        case .pending: return t("pending", "대기 중")
        case .unauthorized: return t("unauthorized", "인증 실패")
        case .conflict: return t("conflict", "충돌")
        case .limited: return t("limited", "대기 시간")
        case .rejected: return t("rejected", "거부됨")
        case .expired: return t("expired", "만료됨")
        }
    }

    // Footer.
    public var refresh: String { t("Refresh community index", "커뮤니티 지수 새로고침") }
    public var cached: String { t("Cached", "캐시") }
    public var updated: String { t("Updated", "업데이트") }
    public var openDashboard: String { t("Open dashboard", "대시보드 열기") }
    public var openDashboardAccessibility: String { t("Open DerpMeter dashboard", "DerpMeter 대시보드 열기") }
    public var settingsHelp: String { t("DerpMeter settings", "DerpMeter 설정") }
    public var undoLastVote: String { t("Undo last vote", "마지막 투표 취소") }
    public var pauseNetwork: String { t("Pause network", "네트워크 일시 정지") }
    public var smashMenuToggle: String { t("Derp Smash desktop CRT", "Derp Smash 데스크톱 CRT") }
    public var quit: String { t("Quit DerpMeter", "DerpMeter 종료") }
    public var moreActions: String { t("More actions", "더 보기") }

    // MARK: Settings

    public var settings: String { t("Settings", "설정") }
    public var back: String { t("Back", "뒤로") }
    public var backAccessibility: String { t("Back to DerpMeter", "DerpMeter로 돌아가기") }
    public var settingsFooter: String {
        t("DerpMeter shows community sentiment, not a benchmark.", "DerpMeter는 커뮤니티 체감이며 벤치마크가 아니에요.")
    }

    public var sectionVoting: String { t("Voting", "투표") }
    public var globalShortcuts: String { t("Global shortcuts", "전역 단축키") }
    public var globalShortcutsDetail: String {
        "⌥⌘1 \(rating(.smart)) · ⌥⌘2 \(rating(.meh)) · ⌥⌘3 \(rating(.dumb))" + t(", from any app.", ", 어느 앱에서든.")
    }
    public var detectModel: String { t("Detect the model", "모델 감지") }
    public var detectModelDetail: String {
        t("Fills in “Auto” from each agent’s own settings: the model setting of ~/.claude/settings.json, ~/.codex/config.toml and ~/.gemini/settings.json. Nothing else is read; you can always pick a model yourself.",
          "각 에이전트 설정에서 “자동” 모델을 채워요: ~/.claude/settings.json, ~/.codex/config.toml, ~/.gemini/settings.json의 모델 설정만 읽어요. 다른 건 읽지 않으며, 언제든 직접 고를 수 있어요.")
    }
    public var liveSession: String { t("Claude Code · live session model", "Claude Code · 현재 세션 모델") }
    public var liveSessionDetail: String {
        t("Optional, more precise: the model your current Claude Code session uses, as seen by the DerpMeter statusline (“derp privacy session on”). Such votes are marked session-linked.",
          "선택 사항이며 더 정확해요: DerpMeter 상태줄(“derp privacy session on”)이 본 현재 Claude Code 세션의 모델이에요. 이런 투표는 세션 연동으로 표시돼요.")
    }

    public var sectionNotifications: String { t("Notifications", "알림") }
    public var voteResults: String { t("Vote results", "투표 결과") }
    public var scoreJumps: String { t("Derp Score jumps 10+ points", "멍청 지수 10점 이상 상승") }
    public var scoreJumpsDetail: String {
        t("For the selected agent, once it has 30+ votes.", "선택한 에이전트의 투표가 30개 이상일 때.")
    }

    public var sectionDesktop: String { t("Desktop", "데스크톱") }
    public var mascot: String { t("Derpy mascot in the panel", "패널에 Derpy 마스코트 표시") }
    public var smashDetail: String {
        t("A desktop CRT you can smash. Hits stay on this Mac and never count as votes.",
          "부술 수 있는 데스크톱 CRT예요. 타격은 이 Mac에만 남고 투표로 세지 않아요.")
    }
    public var weaponLabel: String { t("Weapon", "무기") }
    public var sizeLabel: String { t("Size", "크기") }
    public var muteImpact: String { t("Mute impact sounds", "타격음 끄기") }
    public var keepAbove: String { t("Keep above other windows", "다른 창 위에 유지") }

    public var sectionApp: String { t("App", "앱") }
    public var languageLabel: String { t("Language", "언어") }
    public func languageDetail(current: Language) -> String {
        t("System follows macOS (now \(current == .ko ? "한국어" : "English")).",
          "시스템은 macOS 설정을 따라요 (현재 \(current == .ko ? "한국어" : "English")).")
    }
    public var launchAtLogin: String { t("Launch at login", "로그인 시 실행") }
    public var pauseNetworkDetail: String {
        t("Offline mode: nothing is sent; votes wait in the queue.", "오프라인 모드: 아무것도 보내지 않고, 투표는 대기열에서 기다려요.")
    }

    public var sectionConnection: String { t("Connection & data", "연결 및 데이터") }
    public var connection: String { t("Connection", "연결") }
    public var checkingToken: String { t("Checking saved token access…", "저장된 토큰 확인 중…") }
    public var connected: String { t("Connected · token in Keychain", "연결됨 · 토큰은 키체인에 있어요") }
    public var connectsOnFirstVote: String { t("Connects automatically on your first vote.", "첫 투표 때 자동으로 연결돼요.") }
    public var localCache: String { t("Local cache and queue", "로컬 캐시 및 대기열") }
    public var localCacheDetail: String {
        t("Votes the server already accepted stay; use Undo within 24 hours.",
          "서버에 이미 반영된 투표는 남아요. 24시간 안에 취소할 수 있어요.")
    }
    public var clear: String { t("Clear", "지우기") }
    public var ownToken: String { t("Own token", "직접 입력한 토큰") }
    public var save: String { t("Save", "저장") }
    public var removeToken: String { t("Remove token", "토큰 삭제") }
    public var tokenSaved: String { t("Saved to Keychain.", "키체인에 저장했어요.") }
    public var tokenInvalid: String { t("Invalid token format.", "토큰 형식이 올바르지 않아요.") }
    public var advanced: String { t("Advanced", "고급") }

    // MARK: Status messages and notifications

    public var invalidEndpoint: String {
        t("Invalid developer endpoint override (defaults key `endpoint`).", "개발용 엔드포인트 설정이 잘못됐어요 (defaults 키 `endpoint`).")
    }
    public func nextAgentVote(_ agent: Agent, seconds: TimeInterval) -> String {
        t("Next \(agent.displayName) vote in \(wait(seconds)).", "\(agent.displayName): \(wait(seconds)) 후 다시 투표 가능")
    }
    public var pausedQueued: String { t("Paused: vote queued, not sent.", "일시 정지됨: 투표를 대기열에 넣었고 아직 보내지 않았어요.") }
    public func sending(_ rating: Rating) -> String { t("Sending \(self.rating(rating))…", "\(self.rating(rating)) 보내는 중…") }
    public var queueFull: String { t("Queue full. Resolve pending votes first.", "대기열이 가득 찼어요. 대기 중인 투표를 먼저 정리해 주세요.") }
    public var keychainUnavailableVote: String {
        t("Keychain access is unavailable. Your saved token has been kept. Check Keychain access before voting.",
          "키체인에 접근할 수 없어요. 저장된 토큰은 그대로 두었어요. 투표 전에 키체인 접근을 확인해 주세요.")
    }
    public var keychainUnavailable: String {
        t("Keychain access is unavailable. Your saved token has been kept.", "키체인에 접근할 수 없어요. 저장된 토큰은 그대로 두었어요.")
    }
    public var tokenSaveFailed: String { t("Could not save the token to the Keychain.", "토큰을 키체인에 저장하지 못했어요.") }
    public var enrollFailed: String { t("Could not connect this Mac yet. Votes stay queued.", "아직 이 Mac을 연결하지 못했어요. 투표는 대기열에 남아 있어요.") }
    public var noRecentVote: String { t("No vote from this Mac in the last 24 hours.", "최근 24시간 동안 이 Mac에서 한 투표가 없어요.") }
    public var voteCancelled: String { t("Vote cancelled. The 24h limit still applies.", "투표를 취소했어요. 24시간 제한은 그대로 적용돼요.") }
    public var alreadyCancelled: String { t("Already cancelled.", "이미 취소됐어요.") }
    public func cancelFailed(_ detail: String) -> String { t("Could not cancel: \(detail)", "취소하지 못했어요: \(detail)") }
    public var localCleared: String { t("Local cache and queue cleared.", "로컬 캐시와 대기열을 지웠어요.") }
    public var launchNeedsBundle: String {
        t("Launch at login needs the bundled app (see README).", "로그인 시 실행은 번들된 앱에서만 돼요 (README 참고).")
    }
    public var launchFailed: String { t("Could not change launch at login.", "로그인 시 실행 설정을 바꾸지 못했어요.") }

    /// Result of one send, shown as status and (optionally) a notification.
    public func outcome(_ outcome: SendOutcome) -> String {
        switch outcome {
        case .accepted(let replayed): return replayed ? t("Vote recovered.", "투표를 복구했어요.") : t("Vote accepted. Thanks!", "투표 완료. 고마워요!")
        case .retryable: return t("Offline: vote queued for retry.", "오프라인: 다시 보내려고 대기열에 넣었어요.")
        case .unauthorized: return t("Token rejected. Update it in Settings.", "토큰이 거부됐어요. 설정에서 바꿔 주세요.")
        case .conflict: return t("Vote conflict: resolve it in the queue.", "투표 충돌: 대기열에서 정리해 주세요.")
        case .limited: return t("Too soon: this agent and model are in their vote cooldown.", "너무 빨라요: 이 에이전트와 모델은 아직 투표 대기 시간이에요.")
        case .cancelled: return t("That vote was cancelled.", "취소된 투표예요.")
        case .rejected(let m): return t("Rejected: \(m)", "거부됨: \(m)")
        }
    }

    public func scoreJumpTitle(_ points: Int) -> String { t("Derp Score up \(points) points", "멍청 지수 \(points)점 상승") }
    public func scoreJumpBody(_ agent: Agent, score: Int) -> String {
        t("\(agent.displayName) is at \(score). Community sentiment, not a benchmark.",
          "\(agent.displayName) 현재 \(score)점. 커뮤니티 체감이며 벤치마크가 아니에요.")
    }

    // MARK: Derp Smash

    public func smashCaption(_ machine: SmashMachine) -> String {
        guard ko else { return machine.caption }
        switch machine.state {
        case .idle: return "준비 완료_"
        case .lightDamage: return "음. 좀 아프네."
        case .heavyDamage: return "심각한 멍청함 감지"
        case .broken:
            return machine.hits > SmashMachine.promptAt ? "다시 부수기 전에 AI를 평가할까요?" : "시스템 오류: 인내심을 찾을 수 없음"
        case .voting: return "AI.exe가 생각을 멈췄어요"
        case .cooldown: return "AI.exe 식히는 중"
        case .repairing: return "AI를 껐다 켜 보셨나요?"
        }
    }
    public func smashVoteSent(_ rating: Rating) -> String {
        t("Vote sent: \(self.rating(rating)). Repairing…", "투표 완료: \(self.rating(rating)). 수리 중…")
    }
    public var smashCooldown: String { t("Cooldown: this agent and model need a break.", "대기 시간: 이 에이전트와 모델은 잠시 쉬어야 해요.") }
    public var smashPausedSaved: String { t("Paused: vote saved. It is sent when you resume.", "일시 정지됨: 투표를 저장했어요. 다시 켜면 보내요.") }
    public var smashOfflineQueued: String { t("Offline: vote queued. It retries automatically.", "오프라인: 투표를 대기열에 넣었어요. 자동으로 다시 보내요.") }
    public var smashTokenRejected: String { t("Token rejected. Check Settings.", "토큰이 거부됐어요. 설정을 확인해 주세요.") }
    public var smashNotAccepted: String { t("Vote was not accepted.", "투표가 반영되지 않았어요.") }
    public var smashHelp: String { t("Click to smash · drag to move · right-click for options", "클릭해서 부수기 · 드래그해서 이동 · 우클릭으로 옵션") }
    public func smashAccessibility(_ agent: Agent, caption: String) -> String {
        t("Derp Smash CRT showing \(agent.displayName). \(caption)", "\(agent.displayName)을(를) 보여 주는 Derp Smash CRT. \(caption)")
    }
    public var smashAction: String { t("Smash", "부수기") }
    public var repairAction: String { t("Repair", "수리") }
    public var changeWeapon: String { t("Change Weapon", "무기 바꾸기") }
    public var repairCRT: String { t("Repair CRT", "CRT 수리") }
    public var rateYourAI: String { t("Rate Your AI…", "AI 평가하기…") }
    public var changeAgent: String { t("Change Agent", "에이전트 바꾸기") }
    public var muteSounds: String { t("Mute Sounds", "소리 끄기") }
    public var keepAboveWindows: String { t("Keep Above Windows", "창 위에 유지") }
    public var hideSmash: String { t("Hide Derp Smash", "Derp Smash 숨기기") }
    public var openDerpMeter: String { t("Open DerpMeter", "DerpMeter 열기") }
    public var promptError: String { t("SYSTEM ERROR: PATIENCE NOT FOUND", "시스템 오류: 인내심을 찾을 수 없음") }
    public var promptQuestion: String { t("How derpy was your AI?", "AI, 얼마나 멍청했나요?") }
    /// Countdown around a live timer: "Next vote in 12:34" / "12:34 후 다시 투표 가능".
    public var countdownPrefix: String { t("Next vote in", "") }
    public var countdownSuffix: String { t("", "후 다시 투표 가능") }
    public var sendingPlain: String { t("Sending…", "보내는 중…") }
    public var notNow: String { t("Not now", "나중에") }

    // MARK: Updates

    public func updateAvailable(_ latest: String) -> String {
        t("DerpMeter \(latest) is available", "DerpMeter \(latest) 업데이트가 있어요")
    }
    public func updateUnsupported(_ latest: String) -> String {
        t("This version is no longer supported. Update to \(latest).", "더 이상 지원하지 않는 버전이에요. \(latest)(으)로 업데이트해 주세요.")
    }
    public var updateHow: String {
        t("Download from derpmeter.com/apps, or run\nbrew upgrade --cask derpmeter", "derpmeter.com/apps에서 받거나 실행하세요\nbrew upgrade --cask derpmeter")
    }
    public var updateAction: String { t("Download", "받기") }
    public func updateNotificationBody(_ current: String) -> String {
        t("You have \(current). Open the menu to update.", "지금 버전은 \(current)예요. 메뉴에서 업데이트하세요.")
    }
}
