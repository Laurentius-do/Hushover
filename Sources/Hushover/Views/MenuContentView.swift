import SwiftUI

struct MenuContentView: View {
    @Environment(DuckingEngine.self) private var engine
    @Environment(LaunchAtLogin.self) private var launchAtLogin
    let openRules: @MainActor () -> Void

    var body: some View {
        @Bindable var engine = engine

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 22, height: 22)
                Text(verbatim: "Hushover").font(.headline)
                Spacer()
                Toggle(L10n.automation, isOn: $engine.settings.automationEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if !engine.taps.errors.isEmpty || !engine.taps.suspended.isEmpty {
                PermissionHint(
                    errors: engine.taps.errors.map { "\(engine.name(for: $0.key)): \($0.value)" }.sorted(),
                    suspendedApps: engine.taps.suspended.map { engine.name(for: $0) }.sorted(),
                    retry: engine.retrySuspendedTaps
                )
            }

            sectionTitle(L10n.volumePerApp)
            if engine.visibleApps.isEmpty {
                Text(L10n.noAppPlaying)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            AppList(apps: engine.visibleApps)
            Toggle(L10n.showAllApps, isOn: $engine.settings.showAllApps)
                .controlSize(.small)
                .font(.caption)

            Divider()

            sectionTitle(L10n.automation)
            if engine.settings.rules.isEmpty {
                Text(L10n.noRules)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.createFirstRule) {
                    engine.addRule()
                    openRules()
                }
            }
            ForEach(engine.settings.rules) { rule in
                HStack(spacing: 6) {
                    if rule.isComplete {
                        AppIconView(bundleID: rule.targetAppID, size: 16)
                        Text(engine.name(for: rule.targetAppID))
                        Image(systemName: "arrow.down").font(.caption).foregroundStyle(.secondary)
                        AppIconView(bundleID: rule.triggerAppID, size: 16)
                        Text(engine.name(for: rule.triggerAppID)).lineLimit(1)
                        Spacer()
                        StateBadge(state: engine.ruleStates[rule.id] ?? .idle)
                    } else {
                        Text(L10n.newRuleNotSetUp).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
            MicLevelRow()

            Divider()

            LaunchAtLoginRow()

            HStack {
                Button(L10n.editRules, action: openRules)
                Spacer()
                Button(L10n.about, systemImage: "info.circle", action: AboutPanel.show)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(L10n.about)
                Button(L10n.quit) { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(WindowVisibilityObserver { visible in
            engine.menuVisible = visible
            if visible { launchAtLogin.refresh() }
        })
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// With "show all apps" the list can get long. It takes its natural height up to `maxHeight` and scrolls
/// beyond that, instead of growing the menu past the bottom of the screen.
///
/// The height is measured explicitly: the menu bar window doesn't propose a usable height while sizing
/// itself, so `ViewThatFits` or a plain `maxHeight` frame collapse the list.
private struct AppList: View {
    private static let maxHeight: CGFloat = 320

    let apps: [AudioApp]
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let scrolls = contentHeight > Self.maxHeight
        ScrollView {
            rows
                .padding(.trailing, scrolls ? 12 : 0)  // room for the scroll bar
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight, Self.maxHeight))
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(apps) { app in
                AppVolumeRow(app: app)
            }
        }
    }
}

private struct AppVolumeRow: View {
    @Environment(DuckingEngine.self) private var engine
    let app: AudioApp

    var body: some View {
        let volume = engine.volume(for: app.id)
        let duck = engine.duckFactors[app.id] ?? 1

        HStack(alignment: .top, spacing: 10) {
            AppIconView(bundlePath: app.bundlePath, bundleID: app.id, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(app.name).lineLimit(1)
                    if app.isUsingMic {
                        Image(systemName: "mic.fill").font(.caption2).foregroundStyle(.orange)
                    }
                    Spacer()
                    if duck < DuckingEngine.Tuning.duckingIndicatorFactor {
                        Label(Double(duck).percent, systemImage: "arrow.down")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help(L10n.beingLowered)
                    }
                    Text(volume.percent)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                Slider(value: Binding(get: { volume }, set: { engine.setVolume($0, for: app) }), in: 0...1)
                    .controlSize(.small)
                    .accessibilityLabel(L10n.volume(of: app.name))
                LiveLevelMeter(source: .app(app.id), height: 3, label: L10n.level(of: app.name))
            }
        }
    }
}

private struct MicLevelRow: View {
    @Environment(DuckingEngine.self) private var engine

    var body: some View {
        if engine.micRunning {
            HStack {
                Image(systemName: "mic.fill").foregroundStyle(.secondary)
                LiveLevelMeter(source: .microphone, height: 4, label: L10n.microphoneLevel)
            }
        }
    }
}

private struct LaunchAtLoginRow: View {
    @Environment(LaunchAtLogin.self) private var launchAtLogin

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(L10n.launchAtLogin, isOn: Binding(
                get: { launchAtLogin.isEnabled || launchAtLogin.needsApproval },
                set: { launchAtLogin.set($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            if launchAtLogin.needsApproval {
                HStack(spacing: 4) {
                    Text(L10n.loginItemNeedsApproval)
                    Button(L10n.open) { launchAtLogin.openSystemSettings() }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if let error = launchAtLogin.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionHint: View {
    let errors: [String]
    let suspendedApps: [String]
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.captureFailedTitle, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            Text(L10n.captureFailedHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !suspendedApps.isEmpty {
                Text(L10n.pausedApps(suspendedApps.formatted(.list(type: .and))))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(errors, id: \.self) { Text($0).font(.caption2).foregroundStyle(.tertiary) }
            HStack {
                Button(L10n.openSystemSettings) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                if !suspendedApps.isEmpty {
                    Button(L10n.tryAgain, action: retry)
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
