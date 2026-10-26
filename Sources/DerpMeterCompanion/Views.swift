import AppKit
import CoreText
import DerpCore
import SwiftUI

private enum PanelStyle {
    static let accent = Color(red: 0.725, green: 0.678, blue: 1)
    static let green = Color(red: 0.714, green: 0.929, blue: 0.525)
    static let amber = Color(red: 0.918, green: 0.761, blue: 0.522)
    static let coral = Color(red: 0.941, green: 0.502, blue: 0.412)
    static let background = Color(red: 0.059, green: 0.078, blue: 0.082)
    static let surface = Color(red: 0.067, green: 0.090, blue: 0.090)
    static let text = Color(red: 0.898, green: 0.918, blue: 0.882)
    static let muted = Color(red: 0.596, green: 0.651, blue: 0.608)
    static let border = Color.white.opacity(0.10)
}

enum BrandAssets {
    static func url(_ path: String) -> URL {
        let resource = Bundle.main.resourceURL?.appendingPathComponent(path)
        if let resource, FileManager.default.fileExists(atPath: resource.path) { return resource }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources").appendingPathComponent(path)
    }
    static func registerFonts() {
        for name in ["Geist-Regular", "Geist-Bold"] {
            CTFontManagerRegisterFontsForURL(url("Fonts/\(name).ttf") as CFURL, .process, nil)
        }
    }
}

struct ProviderMark: View {
    let agent: Agent
    private var image: NSImage? {
        let name = agent == .claudeCode ? "claude" : agent == .codex ? "openai" : "antigravity"
        return NSImage(contentsOf: BrandAssets.url("Providers/\(name).png"))
    }
    var body: some View {
        if let image { Image(nsImage: image).resizable().interpolation(.high).scaledToFit().accessibilityHidden(true) }
    }
}

/// Index illustration; independent from the static DerpMeter brand mark.
struct MeterGlyph: View {
    var score: Double?
    var mascot = false
    var body: some View {
        Canvas { context, size in
            let width = size.width
            let center = CGPoint(x: width / 2, y: size.height * 0.72)
            let radius = min(width * 0.39, size.height * 0.58)
            var arc = Path()
            arc.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            context.stroke(arc, with: .foreground, style: StrokeStyle(lineWidth: width * 0.09, lineCap: .round))
            if mascot {
                for x in [0.37, 0.63] {
                    let eye = CGRect(x: width * x - width * 0.035, y: size.height * 0.49, width: width * 0.07, height: width * 0.07)
                    context.fill(Path(ellipseIn: eye), with: .foreground)
                }
            } else {
                if let score {
                    let angle = Double.pi + (min(100, max(0, score)) / 100) * Double.pi
                    var needle = Path()
                    needle.move(to: center)
                    needle.addLine(to: CGPoint(x: center.x + cos(angle) * radius * 0.73, y: center.y + sin(angle) * radius * 0.73))
                    context.stroke(needle, with: .foreground, style: StrokeStyle(lineWidth: width * 0.09, lineCap: .round))
                }
                context.fill(Path(ellipseIn: CGRect(x: center.x - width * 0.055, y: center.y - width * 0.055, width: width * 0.11, height: width * 0.11)), with: .foreground)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Uses the approved raster logo in app bundles and local Swift development runs.
private struct BrandLogo: View {
    private static let artwork: NSImage? = {
        let resource = Bundle.main.url(forResource: "DerpMeter", withExtension: "png")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/DerpMeter.png")
        return NSImage(contentsOf: resource)
    }()
    var body: some View {
        if let image = Self.artwork {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit().accessibilityHidden(true)
        } else {
            Image(systemName: "terminal").accessibilityHidden(true)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    // `--open-settings` starts on Settings (UI QA with --open-panel --capture-panel).
    @State private var showingSettings = CommandLine.arguments.contains("--open-settings")
    @State private var reason: FailureReason?
    @State private var showReason = false
    @State private var showQueue = false

    /// The blended Derp Score for the selected agent (nil on older servers).
    private var blended: BlendedScore.AgentScore? { model.snapshot?.score?.agent(model.agent) }
    private var shownScore: Double? { model.snapshot?.leadScore(model.agent) }
    private var shownSample: Int { model.snapshot?.leadSample(model.agent) ?? 0 }
    private var t: L10n { model.t }
    private var connection: String {
        if model.paused { return t.connectionPaused }
        if model.client == nil { return t.connectionSetup }
        if model.offline { return t.connectionOffline }
        if model.loading { return t.connectionSyncing }
        return model.snapshot?.mode == "demo" ? t.connectionDemo : model.snapshot == nil ? t.connectionConnecting : t.connectionLive
    }
    private var stateColor: Color {
        model.paused || model.offline || model.client == nil ? PanelStyle.amber : PanelStyle.green
    }
    private func scoreColor(_ value: Double?) -> Color {
        guard let value else { return PanelStyle.muted }
        return value < 35 ? PanelStyle.green : value < 65 ? PanelStyle.amber : PanelStyle.coral
    }

    var body: some View {
        Group {
            if showingSettings {
                SettingsView(model: model, onBack: { showingSettings = false })
                    .frame(height: min(640, max(420, (NSScreen.main?.visibleFrame.height ?? 800) - 80)))
            } else {
                panel
            }
        }
        .frame(width: 400)
        // Relative times and countdowns follow the display language.
        .environment(\.locale, model.language.locale)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let update = model.update { updateBanner(update) }
                    intro
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("01").foregroundStyle(PanelStyle.green)
                            Text(t.chooseAgent)
                            Spacer()
                            Text(model.snapshot?.score != nil ? t.past7d : t.past24h).foregroundStyle(PanelStyle.muted)
                        }
                        .font(.system(size: 10, design: .monospaced))
                        agentPicker
                    }
                    scoreCard
                    modelSection
                    voteSection
                    if let status = model.status {
                        Label(status, systemImage: "info.circle")
                            .font(.custom("Geist-Regular", size: 11)).foregroundStyle(PanelStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(PanelStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel(t.voteStatusAccessibility(status))
                    }
                    if !model.queue.items.isEmpty { queueSection }
                }
                .padding(16)
            }
            // A stable viewport avoids AppKit retaining the initial hosting size
            // while asynchronous index data changes SwiftUI's fitting size.
            .frame(height: min(bodyHeight, max(320, (NSScreen.main?.visibleFrame.height ?? 800) - 135)))
            footer
        }
        .frame(width: 400)
        .font(.custom("Geist-Regular", size: 12))
        .foregroundStyle(PanelStyle.text)
        .background(PanelStyle.background)
        .tint(PanelStyle.accent)
        .preferredColorScheme(.dark)
        .onChange(of: model.agent) { _, _ in reason = nil }
        .onAppear { model.reloadSession() }
    }

    private var bodyHeight: CGFloat {
        var height: CGFloat = 420
        if model.status != nil { height += 44 }
        if model.update != nil { height += 62 }
        height += 62 // model step
        if modelNote != nil { height += 16 }
        if model.client == nil { height += 28 }
        if model.availableAt(model.agent) != nil { height += 25 }
        if model.snapshot?.mode == "demo" { height += 22 }
        if model.snapshot?.score != nil { height += 70 }
        if model.showMascot { height += 39 }
        if showReason { height += 64 }
        if !model.queue.items.isEmpty { height += 30 }
        if showQueue { height += CGFloat(model.queue.items.count) * 48 }
        return height
    }

    private var header: some View {
        HStack(spacing: 9) {
            BrandLogo().frame(width: 34, height: 34)
            Text("derpmeter").font(.custom("Geist-Bold", size: 21)).tracking(-0.9)
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(stateColor).frame(width: 5, height: 5)
                Text(connection).font(.system(size: 8, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(stateColor)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(stateColor.opacity(0.07), in: Capsule())
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .overlay(alignment: .bottom) { Rectangle().fill(PanelStyle.border).frame(height: 1) }
    }

    private func updateBanner(_ update: UpdateNotice) -> some View {
        let color = update.unsupported ? PanelStyle.coral : PanelStyle.accent
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(update.unsupported ? t.updateUnsupported(update.latest) : t.updateAvailable(update.latest))
                    .font(.custom("Geist-Bold", size: 12))
                Text(t.updateHow).font(.system(size: 9, design: .monospaced)).foregroundStyle(PanelStyle.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(t.updateAction) { model.openUpdatePage() }
                .font(.custom("Geist-Bold", size: 11))
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.45)) }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            let (before, accent, after) = t.headline
            (Text(before) + Text(accent).foregroundColor(PanelStyle.accent) + Text(after))
                .font(.custom("Geist-Bold", size: 22)).tracking(-0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
    }

    private var agentPicker: some View {
        HStack(spacing: 8) {
            ForEach(Agent.allCases) { agent in
                let selected = agent == model.agent
                let shown = model.snapshot?.leadScore(agent)
                let sample = model.snapshot?.leadSample(agent) ?? 0
                Button { model.agent = agent } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 5) {
                            ProviderMark(agent: agent).frame(width: 14, height: 14)
                            Text(agent == .claudeCode ? "Claude" : agent == .codex ? "Codex" : "agy")
                                .font(.custom("Geist-Regular", size: 11))
                            Spacer(minLength: 0)
                            if selected {
                                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(PanelStyle.green)
                            }
                        }
                        Text(shown.map { String(format: "%.1f", $0) } ?? "—")
                            .font(.system(size: 26, weight: .medium, design: .monospaced)).tracking(-1.7)
                            .foregroundStyle(shown == nil ? PanelStyle.muted : PanelStyle.text)
                            .contentTransition(.numericText())
                        Text("n=\(sample)")
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(PanelStyle.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(selected ? PanelStyle.green.opacity(0.045) : PanelStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? PanelStyle.green.opacity(0.65) : PanelStyle.border) }
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(PanelButtonStyle())
                .help(t.agentHelp(agent, sample: sample))
                .accessibilityLabel(t.selectAgentAccessibility(agent, score: shown.map { String(format: "%.1f", $0) }, sample: sample))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    /// One card: the blended Derp Score on its 0–100 gauge, the 7 daily values
    /// (faint under a sample of 10), and its two components.
    private var scoreCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.agent.displayName).font(.custom("Geist-Bold", size: 12))
                Text(t.derpScoreTag).font(.system(size: 8, design: .monospaced)).foregroundStyle(PanelStyle.muted)
                Spacer(minLength: 4)
                if shownSample < 30 {
                    Text(shownScore == nil ? t.noVotesYetTag : t.lowSampleTag)
                        .font(.system(size: 8, design: .monospaced)).foregroundStyle(PanelStyle.amber)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    HStack(spacing: 3) {
                        ForEach(0..<30, id: \.self) { segment in
                            RoundedRectangle(cornerRadius: 1)
                                .fill((segment < 10 ? PanelStyle.green : segment < 20 ? PanelStyle.amber : PanelStyle.coral).opacity(0.35))
                        }
                    }
                    if let score = shownScore {
                        Capsule().fill(scoreColor(score)).frame(width: 3, height: 15)
                            .offset(x: max(0, min(geometry.size.width - 3, geometry.size.width * score / 100)))
                    }
                }
                .frame(height: 15)
            }
            .frame(height: 15)
            .accessibilityLabel(t.scoreAccessibility(shownScore.map { String(format: "%.1f", $0) }))
            HStack {
                Text(t.scaleSmart).foregroundStyle(PanelStyle.green)
                Spacer()
                Text(t.scaleHint).foregroundStyle(PanelStyle.muted)
                Spacer()
                Text(t.scaleDumb).foregroundStyle(PanelStyle.coral)
            }
            .font(.system(size: 8, design: .monospaced))
            if let blended { components(blended) }
            if model.showMascot {
                MeterGlyph(score: shownScore, mascot: true)
                    .foregroundStyle(PanelStyle.accent).frame(width: 40, height: 30).frame(maxWidth: .infinity)
            }
            if model.snapshot?.mode == "demo" {
                Text(t.demoNotice).font(.system(size: 10)).foregroundStyle(PanelStyle.amber)
            }
        }
    }

    @ViewBuilder private func components(_ b: BlendedScore.AgentScore) -> some View {
        let f = { (v: Double?) in v.map { String(format: "%.1f", $0) } ?? "—" }
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(b.days, id: \.day) { d in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(d.sample >= 10 ? scoreColor(d.score) : PanelStyle.border)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(3, 30 * (d.score ?? 0) / 100))
            }
        }
        .frame(height: 30, alignment: .bottom)
        .accessibilityHidden(true)
        HStack {
            Text(b.days.first.map { String($0.day.dropFirst(5)).replacingOccurrences(of: "-", with: "/") } ?? "")
            Spacer()
            Text(t.faintDays)
            Spacer()
            Text(b.days.last.map { String($0.day.dropFirst(5)).replacingOccurrences(of: "-", with: "/") } ?? "")
        }
        .font(.system(size: 8, design: .monospaced)).foregroundStyle(PanelStyle.muted)
        Rectangle().fill(PanelStyle.border).frame(height: 1)
        VStack(alignment: .leading, spacing: 2) {
            Text(t.partsLine(votes: f(b.votes.score), votesN: Int(b.votes.n), radar: b.radar.map { f($0.score) }, radarN: Int(b.radar?.n ?? 0)))
            Text(t.blendNote(Int(model.snapshot?.score?.voteWeight ?? 3)))
        }
        .font(.system(size: 10, design: .monospaced)).foregroundStyle(PanelStyle.muted)
        .accessibilityElement(children: .combine)
    }

    /// Model step: automatic (detected), no model, or an explicit catalog model.
    private var modelChoiceBinding: Binding<String> {
        Binding(get: { model.modelChoice(for: model.agent).storageValue },
                set: { model.setModelChoice(ModelChoice(storageValue: $0), for: model.agent) })
    }

    private var detectedListed: (id: String, source: L10n.ModelSource)? {
        guard let d = model.detectedModel(for: model.agent), let id = d.id else { return nil }
        return (id, d.source)
    }

    private var modelNote: String? {
        guard model.modelChoice(for: model.agent) == .auto else { return nil }
        if let d = detectedListed { return t.modelFrom(model.agent, source: d.source) }
        if let d = model.detectedModel(for: model.agent) { return t.modelUnlisted(d.raw, source: d.source) }
        return model.detectConfiguredModels ? t.noModelInSettings : t.turnOnDetection
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Rectangle().fill(PanelStyle.border).frame(height: 1)
            HStack {
                Text("02").foregroundStyle(PanelStyle.green).font(.system(size: 10, design: .monospaced))
                Text(t.whichModel).font(.custom("Geist-Bold", size: 13))
                Spacer()
                Picker(t.modelPickerLabel, selection: modelChoiceBinding) {
                    Text(t.autoModel(detectedListed.map { model.modelName($0.id, for: model.agent) })).tag("")
                    Text(t.noModel).tag("-")
                    Divider()
                    ForEach(model.models(for: model.agent), id: \.id) { entry in
                        Text(entry.name ?? entry.id).tag(entry.id)
                    }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .disabled(model.catalog == nil)
                .accessibilityLabel(t.modelAccessibility(model.agent))
            }
            if let note = modelNote {
                Text(note).font(.system(size: 10)).foregroundStyle(detectedListed == nil ? PanelStyle.muted : PanelStyle.accent)
            }
        }
    }

    private var voteSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Rectangle().fill(PanelStyle.border).frame(height: 1)
            HStack {
                Text("03").foregroundStyle(PanelStyle.green).font(.system(size: 10, design: .monospaced))
                Text(t.howDidItDo).font(.custom("Geist-Bold", size: 13))
                Spacer()
                Text(model.paused ? t.queuesOffline : t.oneClick)
                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(PanelStyle.muted)
            }
            if model.client == nil {
                Text(t.votingUnavailable).font(.caption).foregroundStyle(PanelStyle.amber)
            }
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                let wait = model.availableAt(model.agent)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(Rating.allCases) { rating in
                            let color = rating == .smart ? PanelStyle.green : rating == .meh ? PanelStyle.amber : PanelStyle.coral
                            Button { model.vote(rating, reason: rating == .smart ? nil : reason) } label: {
                                VStack(spacing: 8) {
                                    Text(rating == .smart ? "^‿^" : rating == .meh ? "–_–" : "×_×")
                                        .font(.system(size: 18, weight: .medium, design: .monospaced))
                                    HStack(spacing: 5) {
                                        Text(t.rating(rating)).font(.custom("Geist-Bold", size: 12))
                                        Text("\(Rating.allCases.firstIndex(of: rating)! + 1)")
                                            .font(.system(size: 8, design: .monospaced)).opacity(0.55)
                                    }
                                }
                                .foregroundStyle(color)
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(color.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.3)) }
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(PanelButtonStyle())
                            .keyboardShortcut(KeyEquivalent(Character("\(Rating.allCases.firstIndex(of: rating)! + 1)")), modifiers: [])
                            .disabled(wait != nil || model.client == nil)
                            .accessibilityLabel(t.voteAccessibility(rating, agent: model.agent))
                        }
                    }
                    if let wait {
                        Label(t.nextVoteIn(wait.timeIntervalSinceNow), systemImage: "hourglass")
                            .font(.caption).foregroundStyle(PanelStyle.muted)
                    }
                }
            }
            DisclosureGroup(isExpanded: $showReason) {
                Picker(t.failureReason, selection: $reason) {
                    Text(t.noReason).tag(FailureReason?.none)
                    ForEach(FailureReason.allCases) { Text(t.reason($0)).tag(Optional($0)) }
                }.labelsHidden().padding(.top, 5)
                Text(t.reasonHint).font(.caption2).foregroundStyle(PanelStyle.muted)
            } label: {
                Text(reason.map { t.reason($0) } ?? t.addReason).font(.system(size: 11)).foregroundStyle(PanelStyle.muted)
            }
            HStack(spacing: 5) {
                Image(systemName: "lock.shield").font(.system(size: 10))
                Text(t.privacyLine).font(.custom("Geist-Regular", size: 10))
            }
            .foregroundStyle(PanelStyle.muted)
        }
    }

    private var queueSection: some View {
        DisclosureGroup(isExpanded: $showQueue) {
            ForEach(model.queue.items) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(item.body.agent) · \(item.body.score)")
                        Text(t.queueState(item.state)).foregroundStyle(.secondary)
                    }.font(.caption.monospaced())
                    Spacer()
                    Button(t.discard) { model.discard(item.id) }.font(.caption)
                }.padding(.vertical, 4)
            }
        } label: {
            Label(t.queueTitle(model.queue.items.count), systemImage: "tray")
                .font(.system(size: 11)).foregroundStyle(PanelStyle.muted)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button { model.refreshSoon() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
            }
            .help(t.refresh).accessibilityLabel(t.refresh)
            .disabled(model.loading || model.paused)
            if let time = model.fetchedAt {
                HStack(spacing: 3) {
                    Text(model.offline ? t.cached : t.updated)
                    Text(time, style: .relative)
                }.font(.system(size: 9, design: .monospaced))
            }
            Spacer(minLength: 0)
            Link(destination: URL(string: "https://derpmeter.com/dashboard")!) {
                Image(systemName: "chart.xyaxis.line").font(.system(size: 12))
            }.help(t.openDashboard).accessibilityLabel(t.openDashboardAccessibility)
            Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                .help(t.settingsHelp).accessibilityLabel(t.settingsHelp)
            Menu {
                Text(t.sentimentNotBenchmark)
                Button(t.undoLastVote) { model.cancelLastVote() }
                Toggle(t.pauseNetwork, isOn: $model.paused)
                Toggle(t.smashMenuToggle, isOn: $model.smash.enabled)
                Divider()
                Button(t.quit) { NSApplication.shared.terminate(nil) }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(t.moreActions)
        }
        .buttonStyle(.plain).foregroundStyle(PanelStyle.muted)
        .padding(.horizontal, 16).padding(.vertical, 11)
        .overlay(alignment: .top) { Rectangle().fill(PanelStyle.border).frame(height: 1) }
    }
}

private struct PanelButtonStyle: ButtonStyle {
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(enabled ? configuration.isPressed ? 0.65 : 1 : 0.35)
            .brightness(enabled && hovered ? 0.075 : 0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// Settings shown inside the menu bar panel (gear → Settings, ‹ back).
/// Grouped by what the user is doing; sub-options are nested under their
/// switch and only shown when it is on.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    var onBack: (() -> Void)? = nil
    @State private var token = ""
    @State private var tokenMessage: String?
    @State private var showAdvanced = false
    private var t: L10n { model.t }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let onBack {
                    Button(action: onBack) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                            Text(t.back).font(.custom("Geist-Regular", size: 12))
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(PanelStyle.accent)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(t.backAccessibility)
                }
                Spacer()
                Text(t.settings).font(.custom("Geist-Bold", size: 15))
                Spacer()
                if onBack != nil { Color.clear.frame(width: 44, height: 1) }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .overlay(alignment: .bottom) { Rectangle().fill(PanelStyle.border).frame(height: 1) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    voting
                    notifications
                    desktop
                    app
                    connection
                    Text(t.settingsFooter)
                        .font(.system(size: 10)).foregroundStyle(PanelStyle.muted)
                        .frame(maxWidth: .infinity)
                }
                .padding(16)
            }
        }
        .font(.custom("Geist-Regular", size: 12))
        .foregroundStyle(PanelStyle.text)
        .background(PanelStyle.background)
        .tint(PanelStyle.accent)
        .preferredColorScheme(.dark)
        .environment(\.locale, model.language.locale)
    }

    private var voting: some View {
        SettingsSection(t.sectionVoting) {
            SettingsToggle(t.globalShortcuts, detail: t.globalShortcutsDetail, isOn: $model.hotkeysEnabled)
            SettingsDivider()
            SettingsToggle(t.detectModel, detail: t.detectModelDetail, isOn: $model.detectConfiguredModels)
            if model.detectConfiguredModels {
                SettingsGroup {
                    SettingsToggle(t.liveSession, detail: t.liveSessionDetail, isOn: $model.useLocalSession)
                }
            }
        }
    }

    private var notifications: some View {
        SettingsSection(t.sectionNotifications) {
            SettingsToggle(t.voteResults, isOn: $model.notifyVotes)
            SettingsDivider()
            SettingsToggle(t.scoreJumps, detail: t.scoreJumpsDetail, isOn: $model.notifyScoreJumps)
        }
    }

    private var desktop: some View {
        SettingsSection(t.sectionDesktop) {
            SettingsToggle(t.mascot, isOn: $model.showMascot)
            SettingsDivider()
            SettingsToggle("Derp Smash", detail: t.smashDetail, isOn: $model.smash.enabled)
            if model.smash.enabled {
                SettingsGroup {
                    SettingsRow(t.weaponLabel) {
                        Picker(t.weaponLabel, selection: $model.smash.weapon) {
                            ForEach(SmashWeapon.allCases) { Text(t.weapon($0)).tag($0) }
                        }.labelsHidden().pickerStyle(.segmented).fixedSize()
                    }
                    SettingsRow(t.sizeLabel) {
                        Picker(t.sizeLabel, selection: $model.smash.size) {
                            ForEach(SmashSize.allCases) { Text(t.size($0)).tag($0) }
                        }.labelsHidden().pickerStyle(.segmented).fixedSize()
                    }
                    SettingsToggle(t.muteImpact, isOn: $model.smash.muted)
                    SettingsToggle(t.keepAbove, isOn: $model.smash.keepOnTop)
                }
            }
        }
    }

    private var app: some View {
        SettingsSection(t.sectionApp) {
            // Applies live: every view reads its text from `model.t`.
            SettingsRow(t.languageLabel, detail: t.languageDetail(current: LanguagePreference.system.resolve())) {
                Picker(t.languageLabel, selection: $model.languagePreference) {
                    ForEach(LanguagePreference.allCases) { Text(t.languageOption($0)).tag($0) }
                }.labelsHidden().pickerStyle(.menu).fixedSize()
            }
            SettingsDivider()
            SettingsToggle(t.launchAtLogin, isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            SettingsDivider()
            SettingsToggle(t.pauseNetwork, detail: t.pauseNetworkDetail, isOn: $model.paused)
        }
    }

    private var connection: some View {
        SettingsSection(t.sectionConnection) {
            SettingsLabel(t.connection,
                          detail: model.tokenAccessPending ? t.checkingToken
                            : model.hasToken ? t.connected : t.connectsOnFirstVote)
            SettingsDivider()
            SettingsRow(t.localCache, detail: t.localCacheDetail) {
                Button(t.clear) { model.clearLocalState() }.controlSize(.small)
            }
            SettingsDivider()
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(t.ownToken).font(.custom("Geist-Bold", size: 11))
                    SecureField("dm_menubar_…", text: $token).textFieldStyle(.roundedBorder)
                    HStack {
                        Button(t.save) {
                            tokenMessage = model.setToken(token) ? t.tokenSaved : t.tokenInvalid
                            token = ""
                        }
                        Button(t.removeToken, role: .destructive) { model.removeToken() }.disabled(!model.hasToken)
                        if let tokenMessage { Text(tokenMessage).font(.system(size: 10)).foregroundStyle(PanelStyle.muted) }
                    }.controlSize(.small)
                }
                .padding(.top, 8)
            } label: {
                Text(t.advanced).font(.custom("Geist-Regular", size: 12))
            }
        }
    }
}

// MARK: - Settings building blocks (panel style)

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1)
                .foregroundStyle(PanelStyle.muted).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PanelStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(PanelStyle.border) }
        }
    }
}

/// Sub-options of the switch above: indented with a guide line.
private struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(.leading, 12)
            .overlay(alignment: .leading) { Rectangle().fill(PanelStyle.accent.opacity(0.35)).frame(width: 2) }
    }
}

private struct SettingsDivider: View {
    var body: some View { Rectangle().fill(PanelStyle.border).frame(height: 1) }
}

private struct SettingsLabel: View {
    let title: String
    var detail: String? = nil
    init(_ title: String, detail: String? = nil) { self.title = title; self.detail = detail }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.custom("Geist-Bold", size: 12))
            if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(PanelStyle.muted).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

private struct SettingsToggle: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) { self.title = title; self.detail = detail; self._isOn = isOn }
    var body: some View {
        // Label left, switch in one right-aligned column; the whole row toggles.
        HStack(alignment: .center, spacing: 10) {
            SettingsLabel(title, detail: detail)
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn).labelsHidden()
                .toggleStyle(.switch).controlSize(.mini).tint(PanelStyle.accent)
        }
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let trailing: Trailing
    init(_ title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.detail = detail; self.trailing = trailing()
    }
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SettingsLabel(title, detail: detail)
            Spacer(minLength: 8)
            trailing
        }
    }
}
