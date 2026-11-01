import AppKit
import Combine
import DerpCore
import SwiftUI

/// Owns the optional Derp Smash window. AppKit only for what SwiftUI cannot
/// do: a borderless, transparent, non-activating desktop panel.
@MainActor
final class DerpSmashPet {
    private let model: AppModel
    private let openDerpMeter: () -> Void
    private var panel: SmashPanel?
    private var controller: SmashController?
    private var subscriptions = Set<AnyCancellable>()
    private var awake: NSObjectProtocol?
    private var awakeUntil = Date.distantPast
    private var layout = SmashLayout(size: .small)
    private var host: FirstMouseHostingView<DerpSmashView>?
    private let geometry = SmashGeometry()
    /// The CRT's frame on screen. It stays put when the prompt opens or closes;
    /// the window grows around it to wherever the prompt fits.
    private var crtFrame: CGRect?
    /// Polls the small observation file while the CRT is up (Claude Code activity).
    private var activity: Timer?

    init(model: AppModel, openDerpMeter: @escaping () -> Void) {
        self.model = model
        self.openDerpMeter = openDerpMeter
    }

    func apply(_ prefs: SmashPreferences) {
        guard prefs.enabled else { hide(); return }
        let resized = SmashLayout(size: prefs.size) != layout
        layout = SmashLayout(size: prefs.size)
        let panel = panel ?? makePanel()
        if resized { layOut(prompt: controller?.machine.promptVisible ?? false) }
        // Default: just above the desktop icons, so app windows cover it.
        panel.level = prefs.keepOnTop
            ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        if !panel.isVisible { panel.orderFrontRegardless() }
        if activity == nil {
            model.refreshClaudeActivity()
            activity = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.model.refreshClaudeActivity() }
            }
        }
    }

    /// Disable: close the window, stop animations and drop every reference.
    private func hide() {
        guard let panel else { return }
        subscriptions.removeAll()
        activity?.invalidate()
        activity = nil
        endAwake()
        controller?.reset()
        controller = nil
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        self.panel = nil
        host = nil
        crtFrame = nil
    }

    private func makePanel() -> SmashPanel {
        let controller = SmashController(voter: model)
        controller.language = model.language
        controller.onBroken = { [weak model] in model?.recordSmash() }
        self.controller = controller
        let size = layout.crt
        let origin = smashPlacement(saved: model.smash.origin, size: size, screens: Self.screens)
        let panel = SmashPanel(contentRect: CGRect(origin: origin, size: size))
        let root = DerpSmashView(model: model, controller: controller, geometry: geometry, actions: .init(
            interacted: { [weak self] in self?.keepAwake() },
            hide: { [weak self] in self?.model.smash.enabled = false },
            openDerpMeter: { [weak self] in self?.openDerpMeter() }))
        let host = FirstMouseHostingView(rootView: root)
        host.sizingOptions = [] // the pet controls its own frame (prompt grows it)
        host.crtRect = CGRect(origin: .zero, size: size)
        host.onClick = { [weak self, weak controller] in
            self?.keepAwake()
            controller?.hit()
        }

        panel.contentView = host
        self.panel = panel
        self.host = host
        crtFrame = panel.frame
        // Open the vote prompt where it fits, keeping the CRT where it is.
        // Shrinking waits one turn so SwiftUI has removed the prompt first
        // (its minimum height would otherwise block the resize).
        controller.$machine.map(\.promptVisible).removeDuplicates()
            .sink { [weak self] visible in DispatchQueue.main.async { self?.layOut(prompt: visible) } }
            .store(in: &subscriptions)
        // A native window drag ends asynchronously: save once it settles.
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.keepOnScreen(save: true) }
            .store(in: &subscriptions)
        // Feedback the controller writes itself follows the display language.
        model.$languagePreference
            .sink { [weak controller] pref in controller?.language = pref.resolve() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.keepOnScreen(save: false) }
            .store(in: &subscriptions)
        return panel
    }

    private static var screens: [CGRect] { NSScreen.screens.map(\.visibleFrame) }

    /// App Nap throttles an unfocused accessory app, which would stall the hit
    /// animation. Opt out only briefly after an interaction; idle stays napped.
    private func keepAwake(for seconds: TimeInterval = 1.5) {
        awakeUntil = Date().addingTimeInterval(seconds)
        if awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                          reason: "Derp Smash animation")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) { [weak self] in
            guard let self, Date() >= self.awakeUntil else { return }
            self.endAwake()
        }
    }

    private func endAwake() {
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
    }

    /// Frame the window around the CRT (kept where it is, resized around its
    /// top centre) and, when shown, the prompt placed where it fits on screen.
    private func layOut(prompt: Bool) {
        guard let panel else { return }
        let old = crtFrame ?? panel.frame
        let size = layout.crt
        var crt = CGRect(x: old.midX - size.width / 2, y: old.maxY - size.height, width: size.width, height: size.height)
        crt.origin = smashPlacement(saved: crt.origin, size: crt.size, screens: Self.screens)
        crtFrame = crt
        let bubble = prompt ? smashPromptPlacement(crt: crt, prompt: layout.prompt, screens: Self.screens) : nil
        let window = bubble.map { crt.union($0) } ?? crt
        // Offsets from the window's top-left, as SwiftUI lays them out.
        func offset(_ r: CGRect) -> CGPoint { CGPoint(x: r.minX - window.minX, y: window.maxY - r.maxY) }
        geometry.crt = offset(crt)
        if let bubble {
            geometry.prompt = offset(bubble)
            geometry.promptFacing = bubble.maxY <= crt.minY ? .top : bubble.minY >= crt.maxY ? .bottom
                : bubble.minX >= crt.maxX ? .leading : .trailing
        }
        // AppKit coordinates (bottom-left origin) for the hosting view's hit test.
        host?.crtRect = CGRect(x: crt.minX - window.minX, y: crt.minY - window.minY, width: crt.width, height: crt.height)
        if panel.frame != window { panel.setFrame(window, display: true) }
    }

    /// After a drag or a display change: keep the CRT on screen, re-place the
    /// prompt around it, and remember the CRT's bottom-left corner.
    private func keepOnScreen(save: Bool) {
        guard let panel, let host else { return }
        let r = host.crtRect
        crtFrame = CGRect(x: panel.frame.minX + r.minX, y: panel.frame.minY + r.minY, width: r.width, height: r.height)
        layOut(prompt: controller?.machine.promptVisible ?? false)
        if save, let crt = crtFrame { model.smash.origin = crt.origin }
    }
}

/// Never becomes key or main, so clicking it does not take focus from your work.
final class SmashPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        // Every Space, but not on top of full-screen apps; stays put in Mission Control.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        setAccessibilityLabel("Derp Smash")
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Clicks land on the first try even though the panel never activates.
/// The CRT area (top of the window) is handled here: a click smashes, a drag
/// moves the window natively. SwiftUI gestures are unreliable in a panel that
/// never becomes key. Right-clicks and the vote prompt stay with SwiftUI.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    /// Where the CRT is in the view (AppKit coordinates, bottom-left origin).
    var crtRect: CGRect = .zero
    var onClick: () -> Void = {}
    private var downAt: NSPoint?
    private var dragged = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func inCRT(_ event: NSEvent) -> Bool {
        var p = convert(event.locationInWindow, from: nil)
        if isFlipped { p.y = bounds.height - p.y }
        return crtRect.contains(p)
    }

    override func mouseDown(with event: NSEvent) {
        guard inCRT(event), !event.modifierFlags.contains(.control) else { return super.mouseDown(with: event) }
        downAt = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downAt else { return super.mouseDragged(with: event) }
        let p = event.locationInWindow
        guard !dragged, hypot(p.x - downAt.x, p.y - downAt.y) > 3 else { return }
        dragged = true
        window?.performDrag(with: event) // the pet saves its spot on didMove
        self.downAt = nil
    }

    override func mouseUp(with event: NSEvent) {
        guard downAt != nil else { return super.mouseUp(with: event) }
        downAt = nil
        if !dragged { onClick() }
    }
}

/// Optional impact sounds: built-in system sounds, muted on request or when
/// the user turned off interface sound effects.
enum SmashSound {
    static func play(_ weapon: SmashWeapon, broken: Bool, muted: Bool) {
        guard !muted, interfaceSoundsEnabled else { return }
        let name = broken ? "Basso" : weapon == .hammer ? "Pop" : "Bottle"
        NSSound(named: NSSound.Name(name))?.play()
    }

    private static var interfaceSoundsEnabled: Bool {
        let value = UserDefaults.standard.persistentDomain(forName: "com.apple.systemsound")?["com.apple.sound.uiaudio.enabled"]
        return (value as? Int) != 0
    }
}

// MARK: - QA rendering

/// Renders each Derp Smash state to PNG with ImageRenderer. Offscreen: never
/// touches the desktop, other windows or the network (the vote voter is a stub).
@MainActor
func renderSmashStates(model: AppModel, to directory: URL) {
    final class StubVoter: SmashVoter {
        var next: Date?
        func smashNextVoteAt() -> Date? { next }
        func submitSmashVote(_ rating: Rating) async -> SmashVoteResult { .failed("QA stub") }
    }
    var now = Date()
    let cases: [(String, Int, Date?, Bool)] = [
        ("idle", 0, nil, false), ("light", 2, nil, false), ("heavy", 4, nil, false),
        ("voting", 5, nil, false), ("cooldown", 5, Date().addingTimeInterval(1500), false),
        ("broken", 5, nil, true), ("repairing", 3, nil, false),
    ]
    let actions = DerpSmashView.Actions(interacted: {}, hide: {}, openDerpMeter: {})
    for (name, hits, next, dismiss) in cases {
        let voter = StubVoter()
        voter.next = next
        let controller = SmashController(voter: voter, repairDuration: 60) { now }
        controller.language = model.language
        for _ in 0..<hits { controller.hit(); now = now.addingTimeInterval(1) }
        if dismiss { controller.dismissPrompt() }
        if name == "repairing" { controller.repair() }
        let layout = SmashLayout(size: model.smash.size)
        let size = layout.window(prompt: controller.machine.promptVisible)
        // The prompt hanging below the CRT, as on a free spot of the desktop.
        let geometry = SmashGeometry()
        geometry.crt = CGPoint(x: (size.width - layout.crt.width) / 2, y: 0)
        geometry.prompt = CGPoint(x: (size.width - layout.prompt.width) / 2, y: layout.crt.height)
        let view = DerpSmashView(model: model, controller: controller, geometry: geometry, actions: actions)
            .frame(width: size.width, height: size.height)
            .background(Color(red: 0.16, green: 0.20, blue: 0.27))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: directory.appendingPathComponent("smash-\(name).png"))
        }
        controller.reset()
    }
    FileHandle.standardOutput.write(Data("Rendered Derp Smash states.\n".utf8))
    NSApp.terminate(nil)
}
