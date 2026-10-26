import AppKit
import DerpCore
import SwiftUI

/// Retro CRT desktop pet. Animations run only for a moment after a hit or
/// during a repair (keyframes, no timers), so the pet is idle-cheap.
struct DerpSmashView: View {
    struct Actions {
        /// Any click on the pet (keeps animations smooth; see DerpSmashPet).
        let interacted: () -> Void
        let hide: () -> Void
        let openDerpMeter: () -> Void
    }

    @ObservedObject var model: AppModel
    @ObservedObject var controller: SmashController
    let actions: Actions
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private var machine: SmashMachine { controller.machine }
    private var t: L10n { model.t }
    /// No animation trigger when Reduce Motion is on; damage still shows.
    private var trigger: Int { reduceMotion ? 0 : controller.impacts }

    var body: some View {
        // Drawn at the base size and scaled to the chosen size.
        let layout = SmashLayout(size: model.smash.size)
        VStack(spacing: 0) {
            crt
                .scaleEffect(layout.crtScale, anchor: .topLeading)
                .frame(width: layout.crt.width, height: layout.crt.height, alignment: .topLeading)
            if machine.promptVisible {
                SmashPrompt(model: model, controller: controller, interacted: actions.interacted)
                    .padding(.top, 8)
                    .frame(width: SmashLayout.promptBase.width, height: SmashLayout.promptBase.height, alignment: .top)
                    .scaleEffect(layout.promptScale, anchor: .topLeading)
                    .frame(width: layout.prompt.width, height: layout.prompt.height, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.locale, model.language.locale)
        .onChange(of: controller.impacts) {
            SmashSound.play(model.smash.weapon, broken: machine.state == .broken || machine.promptVisible,
                            muted: model.smash.muted)
        }
    }

    private var crt: some View {
        CRTMonitor(agent: model.agent, modelName: model.voteModelName, machine: machine,
                   caption: t.smashCaption(machine), feedback: machine.state == .repairing ? controller.feedback : nil, reduceMotion: reduceMotion)
            .keyframeAnimator(initialValue: Shake(), trigger: trigger) { content, value in
                content.offset(x: value.x, y: value.y).rotationEffect(.degrees(value.tilt))
            } keyframes: { _ in
                KeyframeTrack(\.x) {
                    LinearKeyframe(0, duration: 0.08)
                    LinearKeyframe(7, duration: 0.03)
                    LinearKeyframe(-6, duration: 0.05)
                    LinearKeyframe(3, duration: 0.05)
                    LinearKeyframe(0, duration: 0.06)
                }
                // Every track ends exactly at rest so no offset or tilt lingers.
                KeyframeTrack(\.y) {
                    LinearKeyframe(0, duration: 0.08)
                    LinearKeyframe(3, duration: 0.04)
                    CubicKeyframe(-1, duration: 0.07)
                    LinearKeyframe(0, duration: 0.06)
                }
                KeyframeTrack(\.tilt) {
                    LinearKeyframe(0, duration: 0.08)
                    LinearKeyframe(-2.5, duration: 0.05)
                    CubicKeyframe(1, duration: 0.08)
                    LinearKeyframe(0, duration: 0.07)
                }
            }
            .overlay(alignment: .topTrailing) {
                WeaponSwing(weapon: model.smash.weapon, trigger: trigger).offset(x: -6, y: 8)
            }
            .overlay { Sparks(trigger: trigger).offset(x: 34, y: -24) }
            .frame(width: SmashLayout.crtBase.width, height: SmashLayout.crtBase.height, alignment: .bottom)
            .contentShape(Rectangle())
            // Left click / drag are handled by the hosting view (see DerpSmashPet).
            .contextMenu { menu }
            .help(t.smashHelp)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(t.smashAccessibility(model.agent, caption: t.smashCaption(machine)))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: t.smashAction) { controller.hit() }
            .accessibilityAction(named: t.repairAction) { controller.repair() }
    }

    @ViewBuilder private var menu: some View {
        Menu(t.changeWeapon) {
            ForEach(SmashWeapon.allCases) { weapon in
                Toggle(t.weapon(weapon), isOn: Binding(get: { model.smash.weapon == weapon },
                                                   set: { if $0 { model.smash.weapon = weapon } }))
            }
        }
        Button(t.repairCRT) { actions.interacted(); controller.repair() }
            .disabled(machine.state == .idle || machine.state == .repairing)
        if machine.state == .broken {
            Button(t.rateYourAI) { controller.openPrompt() }
        }
        Menu(t.changeAgent) {
            ForEach(Agent.allCases) { agent in
                Toggle(agent.displayName, isOn: Binding(get: { model.agent == agent },
                                                        set: { if $0 { model.agent = agent } }))
            }
        }
        Menu(t.sizeLabel) {
            ForEach(SmashSize.allCases) { size in
                Toggle(t.size(size), isOn: Binding(get: { model.smash.size == size },
                                                 set: { if $0 { model.smash.size = size } }))
            }
        }
        Toggle(t.muteSounds, isOn: $model.smash.muted)
        Toggle(t.keepAboveWindows, isOn: $model.smash.keepOnTop)
        Divider()
        Button(t.hideSmash) { actions.hide() }
        Button(t.openDerpMeter) { actions.openDerpMeter() }
    }
}

private struct Shake { var x: CGFloat = 0; var y: CGFloat = 0; var tilt: Double = 0 }

// MARK: - CRT

private enum Phosphor {
    static let green = Color(red: 0.49, green: 1, blue: 0.70)
    static let cyan = Color(red: 0.45, green: 0.93, blue: 1)
    static let amber = Color(red: 1, green: 0.78, blue: 0.38)
    static let red = Color(red: 1, green: 0.42, blue: 0.36)
    static func tint(_ state: SmashState) -> Color {
        switch state {
        case .idle, .lightDamage: return green
        case .heavyDamage: return amber
        case .broken, .voting: return red
        case .cooldown, .repairing: return cyan
        }
    }
}

private struct CRTMonitor: View {
    let agent: Agent
    let modelName: String?
    let machine: SmashMachine
    let caption: String
    let feedback: String?
    let reduceMotion: Bool
    @State private var sweep: CGFloat = 0

    private var state: SmashState { machine.state }
    private var tint: Color { Phosphor.tint(state) }
    private var damage: Int {
        switch SmashMachine.damage(forHits: machine.hits) {
        case .idle: return 0
        case .lightDamage: return 1
        case .heavyDamage: return 2
        default: return 3
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Beige plastic case with a thick bezel.
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.93, green: 0.89, blue: 0.79),
                                                  Color(red: 0.80, green: 0.75, blue: 0.62)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(red: 0.55, green: 0.50, blue: 0.40), lineWidth: 2))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
                VStack(spacing: 6) {
                    screen.frame(width: 156, height: 118)
                    HStack(spacing: 6) {
                        Text("DERPTRON 95").font(.system(size: 7, weight: .heavy, design: .monospaced))
                            .foregroundStyle(Color(red: 0.45, green: 0.41, blue: 0.33))
                        Spacer()
                        Circle().fill(state == .broken || state == .voting ? Phosphor.red
                                      : state == .heavyDamage ? Phosphor.amber : Phosphor.green)
                            .frame(width: 5, height: 5)
                            .shadow(color: tint.opacity(0.8), radius: 2)
                    }
                    .frame(width: 150)
                }
                .padding(.top, 4)
            }
            .frame(width: 184, height: 160)
            // Stand.
            Trapezoid().fill(Color(red: 0.76, green: 0.71, blue: 0.58))
                .overlay(Trapezoid().stroke(Color(red: 0.55, green: 0.50, blue: 0.40), lineWidth: 1.5))
                .frame(width: 92, height: 18)
            RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.70, green: 0.65, blue: 0.52))
                .frame(width: 130, height: 8)
        }
        .onChange(of: state == .repairing) { _, repairing in
            guard repairing else { return }
            sweep = 0
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.85)) { sweep = 1 }
        }
    }

    private var screen: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(RadialGradient(colors: [Color(red: 0.06, green: 0.13, blue: 0.10), Color(red: 0.02, green: 0.04, blue: 0.03)],
                                     center: .center, startRadius: 4, endRadius: 100))
            content.foregroundStyle(tint)
                .shadow(color: tint.opacity(0.7), radius: 3)
                .padding(10)
            Scanlines().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if damage > 0 {
                Cracks(level: damage).stroke(.white.opacity(0.75), lineWidth: damage == 3 ? 1.3 : 1)
                    // The repair sweep wipes the cracks away from the top down.
                    .mask(alignment: .bottom) {
                        GeometryReader { geo in
                            Rectangle().frame(height: geo.size.height * (state == .repairing ? 1 - sweep : 1))
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                    .transition(.opacity)
            }
            if state == .repairing {
                GeometryReader { geo in
                    Rectangle().fill(Phosphor.cyan.opacity(0.55)).frame(height: 10).blur(radius: 3)
                        .offset(y: sweep * (geo.size.height - 10))
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.black.opacity(0.6), lineWidth: 3))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: damage)
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 4) {
            if state == .broken || state == .voting {
                Text("(⊙_☉)").font(.system(size: 22, weight: .bold, design: .monospaced))
            } else {
                HStack(spacing: 5) {
                    ProviderMark(agent: agent).frame(width: 14, height: 14)
                        .saturation(state == .idle ? 1 : 0.4)
                    Text(agent.displayName.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                if let modelName {
                    Text(modelName).font(.system(size: 9, design: .monospaced)).lineLimit(1).opacity(0.85)
                }
            }
            Text(feedback ?? caption)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.8)
                .padding(.top, 2)
        }
    }
}

/// Static scanlines: drawn once by Canvas, never animated.
private struct Scanlines: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            while y < size.height {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.22)))
                y += 3
            }
        }
        .allowsHitTesting(false)
    }
}

/// Deterministic crack pattern that grows with damage (no randomness).
private struct Cracks: Shape {
    let level: Int
    static let lines: [[CGPoint]] = [
        [CGPoint(x: 0.72, y: 0.18), CGPoint(x: 0.62, y: 0.34), CGPoint(x: 0.66, y: 0.46), CGPoint(x: 0.54, y: 0.62)],
        [CGPoint(x: 0.62, y: 0.34), CGPoint(x: 0.80, y: 0.40), CGPoint(x: 0.92, y: 0.36)],
        [CGPoint(x: 0.66, y: 0.46), CGPoint(x: 0.44, y: 0.42), CGPoint(x: 0.30, y: 0.50), CGPoint(x: 0.12, y: 0.46)],
        [CGPoint(x: 0.54, y: 0.62), CGPoint(x: 0.60, y: 0.80), CGPoint(x: 0.52, y: 0.96)],
        [CGPoint(x: 0.44, y: 0.42), CGPoint(x: 0.36, y: 0.24), CGPoint(x: 0.40, y: 0.06)],
        [CGPoint(x: 0.30, y: 0.50), CGPoint(x: 0.22, y: 0.70), CGPoint(x: 0.08, y: 0.84)],
        [CGPoint(x: 0.80, y: 0.40), CGPoint(x: 0.84, y: 0.66), CGPoint(x: 0.96, y: 0.78)],
        [CGPoint(x: 0.60, y: 0.80), CGPoint(x: 0.36, y: 0.86), CGPoint(x: 0.24, y: 0.98)],
    ]
    func path(in rect: CGRect) -> Path {
        let count = [0, 2, 5, Self.lines.count][min(level, 3)]
        var path = Path()
        for line in Self.lines.prefix(count) {
            path.addLines(line.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) })
        }
        return path
    }
}

private struct Trapezoid: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.22, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

// MARK: - Effects

private struct Swing { var angle: Double = -80; var opacity: Double = 0 }

/// Hammer or bat that appears, strikes the top-right of the screen and leaves.
private struct WeaponSwing: View {
    let weapon: SmashWeapon
    let trigger: Int
    var body: some View {
        WeaponShape(weapon: weapon)
            .frame(width: 60, height: 76)
            .keyframeAnimator(initialValue: Swing(), trigger: trigger) { content, value in
                content.rotationEffect(.degrees(value.angle), anchor: .bottomTrailing).opacity(value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.angle) {
                    LinearKeyframe(-80, duration: 0.01)
                    CubicKeyframe(18, duration: 0.08)
                    LinearKeyframe(10, duration: 0.12)
                    LinearKeyframe(-80, duration: 0.01)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.01)
                    LinearKeyframe(1, duration: 0.16)
                    LinearKeyframe(0, duration: 0.06)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct WeaponShape: View {
    let weapon: SmashWeapon
    var body: some View {
        // Drawn with simple blocks for a pixel-toy look; pivot at bottom-right.
        ZStack(alignment: .bottomTrailing) {
            if weapon == .hammer {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(LinearGradient(colors: [Color(red: 0.62, green: 0.40, blue: 0.22), Color(red: 0.45, green: 0.28, blue: 0.15)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 7, height: 58)
                    .offset(x: -8, y: 0)
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [Color(white: 0.78), Color(white: 0.45)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color(white: 0.3), lineWidth: 1))
                    .frame(width: 34, height: 15)
                    .offset(x: 6, y: -54)
            } else {
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 0.86, green: 0.66, blue: 0.40), Color(red: 0.66, green: 0.45, blue: 0.24)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 12, height: 72)
                    .overlay(alignment: .bottom) {
                        Capsule().fill(Color(red: 0.25, green: 0.20, blue: 0.18)).frame(width: 7, height: 16)
                    }
                    .offset(x: -6, y: 0)
            }
        }
    }
}

private struct Burst { var progress: CGFloat = 0; var opacity: Double = 0 }

/// A few pixel sparks flying out from the impact point.
private struct Sparks: View {
    let trigger: Int
    private static let directions: [CGVector] = [
        .init(dx: 1, dy: -0.4), .init(dx: 0.7, dy: 0.8), .init(dx: -0.2, dy: -1), .init(dx: -0.9, dy: 0.3),
        .init(dx: 0.3, dy: 1), .init(dx: -0.7, dy: -0.7), .init(dx: 1, dy: 0.2), .init(dx: -1, dy: -0.1),
    ]
    var body: some View {
        ZStack {
            ForEach(Self.directions.indices, id: \.self) { i in
                Rectangle()
                    .fill(i.isMultiple(of: 2) ? Phosphor.amber : .white)
                    .frame(width: 3, height: 3)
                    .modifier(SparkOffset(direction: Self.directions[i]))
            }
        }
        .keyframeAnimator(initialValue: Burst(), trigger: trigger) { content, value in
            content.environment(\.sparkProgress, value.progress).opacity(value.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.progress) {
                LinearKeyframe(0, duration: 0.08)
                CubicKeyframe(1, duration: 0.28)
            }
            KeyframeTrack(\.opacity) {
                LinearKeyframe(0, duration: 0.08)
                LinearKeyframe(1, duration: 0.01)
                LinearKeyframe(0, duration: 0.27)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SparkProgressKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private extension EnvironmentValues {
    var sparkProgress: CGFloat {
        get { self[SparkProgressKey.self] }
        set { self[SparkProgressKey.self] = newValue }
    }
}

private struct SparkOffset: ViewModifier {
    let direction: CGVector
    @Environment(\.sparkProgress) private var progress
    func body(content: Content) -> some View {
        content.offset(x: direction.dx * 26 * progress, y: direction.dy * 26 * progress)
    }
}

// MARK: - Vote prompt

/// Optional, explicit vote. Never preselected; closing it is always possible.
private struct SmashPrompt: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: SmashController
    let interacted: () -> Void

    private var cooling: Bool { controller.machine.state == .cooldown }
    private var t: L10n { model.t }

    var body: some View {
        VStack(spacing: 7) {
            Text(t.promptError)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Phosphor.red)
            Text(t.promptQuestion).font(.system(size: 12, weight: .semibold))
            Text([model.agent.displayName, model.voteModelName].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 6) {
                ForEach(Rating.allCases) { rating in
                    Button {
                        interacted()
                        Task { await controller.vote(rating) }
                    } label: {
                        VStack(spacing: 1) {
                            Text(face(rating)).font(.system(size: 9, design: .monospaced))
                            Text(t.rating(rating)).font(.system(size: 11, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .disabled(cooling || controller.submitting)
                    .opacity(cooling || controller.submitting ? 0.4 : 1)
                }
            }
            if cooling, let until = controller.machine.cooldownUntil {
                // Word order differs: "Next vote in 12:34" / "12:34 후 다시 투표 가능".
                HStack(spacing: 4) {
                    if !t.countdownPrefix.isEmpty { Text(t.countdownPrefix) }
                    Text(timerInterval: Date()...until, countsDown: true).fixedSize()
                    if !t.countdownSuffix.isEmpty { Text(t.countdownSuffix) }
                }
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Phosphor.cyan)
            } else if let feedback = controller.feedback {
                Text(feedback).font(.system(size: 10)).foregroundStyle(Phosphor.amber).lineLimit(2)
                    .multilineTextAlignment(.center)
            } else if controller.submitting {
                Text(t.sendingPlain).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack {
                Button(t.repairAction) { interacted(); controller.repair() }
                Spacer()
                Button(t.notNow) { controller.dismissPrompt() }
            }
            .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 200)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.06, green: 0.08, blue: 0.08).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Phosphor.green.opacity(0.35)))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func face(_ rating: Rating) -> String {
        switch rating {
        case .smart: return "(•‿•)"
        case .meh: return "(•_•)"
        case .dumb: return "(⊙_☉)"
        }
    }
}
