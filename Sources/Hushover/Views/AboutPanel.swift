import AppKit

/// Details from Info.plist.
enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    /// Set `HushoverRepositoryURL` in Info.plist to link the source code from the About panel.
    static var repositoryURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "HushoverRepositoryURL") as? String)
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }
}

/// The standard macOS About panel: icon, name, version and copyright come from Info.plist,
/// the credits add the tagline and – once configured – a link to the source code.
@MainActor
enum AboutPanel {
    static func show() {
        let credits = NSMutableAttributedString(string: L10n.tagline, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        if let url = AppInfo.repositoryURL {
            credits.append(NSAttributedString(string: "\n\n"))
            credits.append(NSAttributedString(string: L10n.sourceCode, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .link: url,
            ]))
        }
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))

        // A menu bar app isn't active by default; without this the panel opens behind other windows.
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
