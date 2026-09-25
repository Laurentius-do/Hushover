import AppKit
import SwiftUI

/// The rules window. Opened from the menu, and when Hushover is launched again while it's already
/// running (Finder, Spotlight, Launchpad) – so the app stays reachable even if its menu bar icon is hidden,
/// e.g. behind the notch.
@MainActor
final class RulesWindowController: NSObject, NSWindowDelegate {
    private let engine: DuckingEngine
    private var window: NSWindow?

    init(engine: DuckingEngine) {
        self.engine = engine
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        // Level meters for calibrating thresholds run only while the window is open.
        engine.calibrating = true
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        engine.calibrating = false
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: RulesView().environment(engine)))
        window.title = L10n.rulesWindowTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}
