import AppKit
import SwiftUI

/// Horizontal level meter from -70 dB to 0 dB with an optional threshold marker.
struct LevelMeter: View {
    var db: Float?
    var threshold: Double?
    var height: CGFloat = 6
    var label = L10n.level

    private static let floor: Double = -70

    private func fraction(_ value: Double) -> CGFloat {
        CGFloat(min(max((value - Self.floor) / -Self.floor, 0), 1))
    }

    var body: some View {
        GeometryReader { geo in
            let level = Double(db ?? -100)
            let above = threshold.map { level > $0 } ?? true
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(above ? Color.green : Color.secondary.opacity(0.6))
                    .frame(width: geo.size.width * fraction(level))
                if let threshold {
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: 2, height: height + 4)
                        .offset(x: geo.size.width * fraction(threshold) - 1)
                }
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.05), value: db)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard let db, db > silenceDB else { return L10n.silence }
        let value = "\(Int(db)) dB"
        guard let threshold else { return value }
        return Double(db) > threshold ? L10n.aboveThreshold(value) : L10n.belowThreshold(value)
    }
}

struct AppIconView: View {
    var bundlePath: String?
    var bundleID: String?
    var size: CGFloat = 22

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var image: NSImage {
        if let bundlePath { return AppIcons.icon(forBundlePath: bundlePath) }
        return AppIcons.icon(forBundleID: bundleID)
    }
}

struct StateBadge: View {
    var state: RuleState

    var body: some View {
        Text(state.label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch state {
        case .disabled: .secondary
        case .idle: .secondary
        case .listening: .blue
        case .speaking: .orange
        }
    }
}

/// Where a live level comes from. Reading it in its own small view means only that view re-renders
/// 30 times a second, not the whole menu or form around it.
enum LevelSource {
    case microphone
    case app(String)
}

struct LiveLevelMeter: View {
    @Environment(DuckingEngine.self) private var engine
    let source: LevelSource
    var threshold: Double?
    var height: CGFloat = 6
    var label = L10n.level

    var body: some View {
        LevelMeter(db: level, threshold: threshold, height: height, label: label)
    }

    private var level: Float? {
        switch source {
        case .microphone: engine.micRunning ? engine.micLevelDB : nil
        case .app(let id): engine.appLevelDB[id]
        }
    }
}

/// Reports whether the window hosting this view is on screen. `onAppear`/`onDisappear` aren't reliable
/// for the menu bar window, which SwiftUI may keep alive while it's closed.
struct WindowVisibilityObserver: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(onChange: onChange)
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: @MainActor (Bool) -> Void
        private var observer: NSObjectProtocol?
        private var lastReported: Bool?

        init(onChange: @escaping @MainActor (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            if let window {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            report()
        }

        private func report() {
            let visible = window?.occlusionState.contains(.visible) ?? false
            guard visible != lastReported else { return }
            lastReported = visible
            onChange(visible)
        }
    }
}

extension Double {
    var percent: String { formatted(.percent.precision(.fractionLength(0))) }
}
