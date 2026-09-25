import AppKit
import SwiftUI

@main
struct HushoverApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(openRules: appDelegate.rulesWindow.show)
                .environment(appDelegate.engine)
                .environment(appDelegate.launchAtLogin)
        } label: {
            MenuBarLabel(engine: appDelegate.engine)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = DuckingEngine()
    let launchAtLogin = LaunchAtLogin()
    private(set) lazy var rulesWindow = RulesWindowController(engine: engine)

    func applicationDidFinishLaunching(_ notification: Notification) {
        GracefulTermination.install()
    }

    /// Launching Hushover again while it's running opens the rules window – the only way in
    /// when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        rulesWindow.show()
        return false
    }
}

private struct MenuBarLabel: View {
    let engine: DuckingEngine

    var body: some View {
        Image(nsImage: engine.isDucking ? MenuBarIcon.ducking : MenuBarIcon.normal)
    }
}

/// Turns SIGTERM (e.g. `pkill`, as used by install.sh) into a normal quit, so pending settings get saved
/// and taps are shut down cleanly instead of the process just disappearing.
@MainActor
private enum GracefulTermination {
    private static var source: DispatchSourceSignal?

    static func install() {
        guard source == nil else { return }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        source.resume()
        self.source = source
    }
}
