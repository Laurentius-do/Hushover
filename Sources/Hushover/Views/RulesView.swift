import SwiftUI

struct RulesView: View {
    @Environment(DuckingEngine.self) private var engine

    var body: some View {
        Form {
            Section {
                Text(L10n.rulesIntro)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = engine.micError {
                    Label(error, systemImage: "mic.slash").foregroundStyle(.orange)
                }
            }

            ForEach(engine.settings.rules) { rule in
                RuleEditor(rule: binding(for: rule))
            }

            Section {
                Button(L10n.addRule, systemImage: "plus") { engine.addRule() }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 560)
    }

    /// Looks the rule up by ID on every access. Index-based bindings (`ForEach($rules)`) can crash
    /// when a rule is deleted from inside its own row.
    private func binding(for rule: DuckRule) -> Binding<DuckRule> {
        Binding(
            get: { engine.settings.rules.first { $0.id == rule.id } ?? rule },
            set: { updated in
                guard let index = engine.settings.rules.firstIndex(where: { $0.id == rule.id }) else { return }
                engine.settings.rules[index] = updated
            }
        )
    }
}

private struct RuleEditor: View {
    @Environment(DuckingEngine.self) private var engine
    @Binding var rule: DuckRule

    var body: some View {
        Section {
            Picker(L10n.makeQuieter, selection: $rule.targetAppID) { appOptions(selected: rule.targetAppID) }
            Picker(L10n.whenSpeakingIn, selection: $rule.triggerAppID) { appOptions(selected: rule.triggerAppID) }

            if !rule.isComplete {
                Text(L10n.chooseBothApps).foregroundStyle(.secondary)
            } else if rule.targetsItself {
                Label(L10n.targetsItselfWarning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                settings
            }

            HStack {
                Spacer()
                Button(L10n.deleteRule, role: .destructive) { engine.deleteRule(rule.id) }
            }
        } header: {
            HStack {
                Text(rule.isComplete ? L10n.ruleHeader(target: engine.name(for: rule.targetAppID), trigger: triggerName) : L10n.newRule)
                Spacer()
                StateBadge(state: engine.ruleStates[rule.id] ?? .idle)
            }
        }
    }

    @ViewBuilder private var settings: some View {
        Toggle(L10n.ruleEnabled, isOn: $rule.isEnabled)
        Toggle(L10n.onlyDuringCalls(triggerName), isOn: $rule.requireTriggerMic)

        PercentSlider(title: L10n.speechVolume, value: $rule.speechLevel)
        PercentSlider(title: L10n.pauseVolume, value: $rule.pauseLevel)

        Toggle(L10n.reactToMyVoice, isOn: $rule.useMicrophone)
        if rule.useMicrophone {
            ThresholdSlider(title: L10n.microphoneThreshold, threshold: $rule.micThresholdDB, source: .microphone)
        }

        Toggle(L10n.reactToOthers(triggerName), isOn: $rule.useTriggerAudio)
        if rule.useTriggerAudio {
            ThresholdSlider(title: L10n.threshold(of: triggerName), threshold: $rule.triggerThresholdDB,
                            source: .app(rule.triggerAppID))
        }

        SecondsSlider(title: L10n.holdAfterSpeech, value: $rule.holdSeconds)
        SecondsSlider(title: L10n.releaseOver, value: $rule.releaseSeconds)
    }

    private var triggerName: String { engine.name(for: rule.triggerAppID) }

    /// The placeholder is only offered while nothing is chosen, so a chosen app can't be un-chosen.
    @ViewBuilder private func appOptions(selected: String) -> some View {
        if selected.isEmpty {
            Text(L10n.chooseApp).tag("")
        }
        ForEach(engine.appChoices, id: \.id) { choice in
            Text(choice.name).tag(choice.id)
        }
    }
}

private struct PercentSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: DuckRule.levelRange, step: 0.05)
                Text(value.percent).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            .frame(width: 220)
        }
    }
}

private struct SecondsSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: DuckRule.secondsRange, step: 0.1)
                Text(L10n.seconds(value.formatted(.number.precision(.fractionLength(1))))).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            .frame(width: 220)
        }
    }
}

private struct ThresholdSlider: View {
    let title: String
    @Binding var threshold: Double
    let source: LevelSource

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                HStack {
                    Slider(value: $threshold, in: DuckRule.thresholdRange, step: 1)
                    Text(verbatim: "\(Int(threshold)) dB").monospacedDigit().frame(width: 52, alignment: .trailing)
                }
                .frame(width: 220)
            }
            LiveLevelMeter(source: source, threshold: threshold, height: 6, label: title)
            Text(L10n.thresholdHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
