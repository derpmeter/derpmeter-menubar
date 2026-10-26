import AppKit
import Combine
import DerpCore
import SwiftUI

@main
struct DerpMeterApp: App {
    @NSApplicationDelegateAdaptor(MenuBarDelegate.self) private var delegate

    var body: some Scene {
        // Settings live in the menu bar panel; this scene only satisfies SwiftUI.
        Settings { SettingsView(model: delegate.model).frame(width: 400, height: 620) }
    }
}

/// AppKit owns the status item so its visibility does not depend on SwiftUI's
/// limited MenuBarExtra label rendering. The panel itself remains SwiftUI.
@MainActor
final class MenuBarDelegate: NSObject, NSApplicationDelegate {
    lazy var model = AppModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var observation: AnyCancellable?
    private var smashObservation: AnyCancellable?
    private lazy var smashPet = DerpSmashPet(model: model) { [weak self] in self?.openPanel() }
    private static let statusFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    // Reserve the widest mood + three-digit score once. Unicode face glyphs
    // can use fallback fonts, so measure real glyph advances, not character counts.
    private static let statusWidth: CGFloat = {
        let titles = ["(•‿•) · Derp 100", "(•_•) · Derp 100", "(⊙_☉) · Derp 100", "(·_·) · Derp —"]
        return ceil(titles.map { ($0 as NSString).size(withAttributes: [.font: statusFont]).width }.max() ?? 120) + 20
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        BrandAssets.registerFonts()
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: Self.statusWidth)
        item.autosaveName = "DerpMeter"
        item.isVisible = true
        statusItem = item
        item.button?.alignment = .left
        item.button?.image = nil
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        popover.behavior = .transient
        popover.animates = true
        let controller = NSHostingController(rootView:
            MenuContent(model: model))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        updateIcon()
        observation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }
        // Derp Smash is off unless the user enabled it; follows its preferences.
        smashObservation = model.$smash.removeDuplicates { $0.enabled == $1.enabled && $0.keepOnTop == $1.keepOnTop && $0.size == $1.size }
            .sink { [weak self] prefs in DispatchQueue.main.async { self?.smashPet.apply(prefs) } }
        // Manual UI QA: render Derp Smash states (this app's own views only).
        if let flag = CommandLine.arguments.firstIndex(of: "--render-smash"),
           CommandLine.arguments.indices.contains(flag + 1) {
            renderSmashStates(model: model, to: URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true))
        }
        // Opens the actual status-item popover for manual UI QA.
        if CommandLine.arguments.contains("--open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.statusItem?.button?.performClick(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let score = model.snapshot?.leadScore(model.agent)
        // Match ANSI mood semantics: 32 green, 33 yellow, 31 red. Native
        // adaptive colors stay legible across macOS menu bar appearances.
        let color: NSColor = score.map {
            if $0 < 35 { return .systemGreen }
            if $0 < 65 { return .systemYellow }
            // Pure saturated red loses apparent stroke weight on a dark,
            // translucent menu bar. Preserve red, with appearance-aware contrast.
            return NSColor(name: "DerpMeterDumb") { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return dark
                    ? NSColor(srgbRed: 1, green: 0.50, blue: 0.45, alpha: 1)
                    : NSColor(srgbRed: 0.70, green: 0.14, blue: 0.10, alpha: 1)
            }
        } ?? .secondaryLabelColor
        let title = NSAttributedString(string: model.title, attributes: [
            .font: Self.statusFont,
            .foregroundColor: color,
        ])
        // Loading, queue and timestamp updates should not redraw the same title.
        if !button.attributedTitle.isEqual(to: title) { button.attributedTitle = title }
        let t = model.t
        let sample = (model.snapshot?.leadSample(model.agent) ?? 0) < 30 ? " · \(t.lowSampleDetail)" : ""
        let connection = model.paused ? " · \(t.pausedDetail)" : model.offline ? " · \(t.offlineDetail)" : ""
        let detail = "DerpMeter · \(model.agent.displayName) · \(t.statusSentiment(score: score)) · \(model.title)\(sample)\(connection)"
        button.toolTip = detail
        button.setAccessibilityLabel(detail)
        if popover.isShown, let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            if popover.contentSize != size { popover.contentSize = size }
        }
    }

    /// Open the panel from the desktop pet ("Open DerpMeter").
    private func openPanel() {
        if !popover.isShown { togglePanel() }
    }

    @objc private func togglePanel() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--open-panel") {
            let diagnostic = "DerpMeter status: visible=\(statusItem?.isVisible ?? false), iconFrame=\(String(describing: button.window?.frame)), screen=\(String(describing: button.window?.screen?.frame)), popover=\(popover.isShown), panelFrame=\(String(describing: popover.contentViewController?.view.window?.frame))\n"
            FileHandle.standardOutput.write(Data(diagnostic.utf8))
            if let flag = CommandLine.arguments.firstIndex(of: "--capture-panel"),
               CommandLine.arguments.indices.contains(flag + 1) {
                let directory = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self else { return }
                    // Render only this app's own views, never the desktop or other apps.
                    self.capture(self.popover.contentViewController?.view, to: directory.appendingPathComponent("companion-panel.png"))
                    self.capture(self.statusItem?.button, to: directory.appendingPathComponent("companion-statusline.png"))
                }
            }
        }
    }

    private func capture(_ view: NSView?, to url: URL) {
        guard let view else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: url)
            FileHandle.standardOutput.write(Data("Rendered app view: \(url.lastPathComponent)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("Could not render app view.\n".utf8))
        }
    }


}
