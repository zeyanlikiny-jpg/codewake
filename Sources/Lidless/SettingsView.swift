import SwiftUI

/// The Settings window. Holds the secondary controls and the detailed
/// explanations that used to clutter the menu bar popover: launch at login,
/// background-helper setup, the auto-off timer, and About/GitHub.
struct SettingsView: View {
    /// Fixed size of the window this view lives in — the view isn't resizable,
    /// so `SettingsWindowController` sizes the window from the same constant.
    static let preferredSize = CGSize(width: 500, height: 760)

    @EnvironmentObject var state: AppState
    private let upstreamURL = URL(string: "https://github.com/nghialuong/Lidless")!

    var body: some View {
        Form {
            Section("General") {
                Picker("Language", selection: Binding(
                    get: { state.appLanguage },
                    set: { state.setAppLanguage($0) }
                )) {
                    Text(verbatim: "简体中文")
                        .tag(AppLanguage.simplifiedChinese)
                    Text(verbatim: "English")
                        .tag(AppLanguage.english)
                }
                .pickerStyle(.segmented)

                Picker("Menu height", selection: Binding(
                    get: { state.menuPopoverHeightMode },
                    set: { state.setMenuPopoverHeightMode($0) }
                )) {
                    Text("30% Taller")
                        .tag(MenuPopoverHeightMode.thirtyPercentTaller)
                    Text("Show All")
                        .tag(MenuPopoverHeightMode.showAll)
                }
                .pickerStyle(.segmented)

                Text("Menus still scroll on smaller screens.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle("Launch at login", isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }
                ))
                Button("Show Setup Guide…") { state.showOnboarding() }
            }

            Section("Input switching") {
                audioInputPicker(title: "Input A", slot: .primary)
                audioInputPicker(title: "Input B", slot: .secondary)

                Text("Choose two different input devices. Offline selections stay saved and become available again when reconnected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("CodeWake changes only the macOS default input. Apps that use a fixed microphone may not follow it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("AI agents") {
                Toggle("Automatically keep awake for AI work", isOn: Binding(
                    get: { state.aiSettings.isEnabled },
                    set: { value in
                        var settings = state.aiSettings
                        settings.isEnabled = value
                        state.updateAISettings(settings)
                    }
                ))

                Toggle("Allow AI automation on battery", isOn: Binding(
                    get: { state.aiSettings.allowOnBattery },
                    set: { value in
                        var settings = state.aiSettings
                        settings.allowOnBattery = value
                        state.updateAISettings(settings)
                    }
                ))

                Picker("When AI waits for input", selection: Binding(
                    get: { state.aiSettings.waitingReleaseDelaySeconds },
                    set: { value in
                        var settings = state.aiSettings
                        settings.waitingReleaseDelaySeconds = value
                        state.updateAISettings(settings)
                    }
                )) {
                    ForEach(
                        AIAutomationSettings.allowedWaitingReleaseDelaySeconds,
                        id: \.self
                    ) { seconds in
                        Text(verbatim: waitingReleaseDelayLabel(seconds: seconds))
                            .tag(seconds)
                    }
                }

                Picker("Maximum time per turn", selection: Binding(
                    get: { state.aiSettings.maximumHours },
                    set: { value in
                        var settings = state.aiSettings
                        settings.maximumHours = value
                        state.updateAISettings(settings)
                    }
                )) {
                    ForEach(AIAutomationSettings.allowedMaximumHours, id: \.self) { hours in
                        Text(verbatim: maximumHoursLabel(hours: hours)).tag(hours)
                    }
                }

                LabeledContent("Configuration") {
                    Label {
                        Text(verbatim: state.integrationSummary)
                    } icon: {
                        Image(systemName: state.integrationHealthy
                              ? "checkmark.circle.fill"
                              : "exclamationmark.circle")
                    }
                    .foregroundStyle(state.integrationHealthy ? .green : .orange)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Observed events")
                        .font(.callout.weight(.medium))
                    integrationObservation(
                        "Codex Desktop",
                        observed: state.codexDesktopObserved
                    )
                    integrationObservation("Codex CLI", observed: state.codexCLIObserved)
                    integrationObservation("Claude Code", observed: state.claudeCodeObserved)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent event diagnostics")
                        .font(.callout.weight(.medium))
                    LabeledContent("Type", value: state.agentLastEventTypeText)
                    LabeledContent("Received", value: state.agentLastEventReceivedText)
                    LabeledContent("Rejection code", value: state.agentLastEventRejectionCode)
                }
                .font(.callout)

                HStack {
                    Button {
                        state.installAgentIntegrations()
                    } label: {
                        Text(state.integrationInstalled
                             ? LocalizedStringKey("Repair integrations…")
                             : LocalizedStringKey("Install integrations…"))
                    }
                    Button("Remove", role: .destructive) { state.removeAgentIntegrations() }
                        .disabled(!state.integrationInstalled)
                }

                Text("Installed configuration and observed runtime events are separate. Each surface is verified only after its current bridge sends a real lifecycle event. The bridge sends only opaque IDs/tokens, event kind, background-work count, and time — never prompts, answers, commands, paths, or source code.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("A manual, timed, or charging hold remains in control after AI work finishes. Leave the main manual switch off when you want AI completion to put a closed Mac to sleep.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("When an AI task finishes or its input wait expires, CodeWake releases its hold. With an external display connected, macOS system sleep settings remain in control.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Image(systemName: state.usingHelper ? "checkmark.shield.fill" : "exclamationmark.shield")
                            .foregroundStyle(state.usingHelper ? .green : .orange)
                        Text(state.usingHelper
                             ? LocalizedStringKey("Active")
                             : LocalizedStringKey("Required"))
                            .foregroundStyle(.secondary)
                    }
                }
                if !state.helperInstalled {
                    Text("Install and approve the background helper before using keep-awake. It owns persistent system-sleep changes and restores the prior state after a crash or timeout.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button {
                        state.installHelper()
                    } label: {
                        Text(state.helperNeedsApproval
                             ? LocalizedStringKey("Open Login Items to approve…")
                             : LocalizedStringKey("Install background helper…"))
                    }
                }
                if let notice = state.helperRecoveryNotice {
                    Label {
                        Text(verbatim: notice)
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill")
                    }
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            } header: {
                Text("Background helper")
            }

            // The auto-off timer used to live here as a preference — set a
            // duration, then separately remember to flip the switch. It's now a
            // "Keep awake for…" control in the popover next to the toggle it
            // governs, where choosing a duration also turns keep-awake on. One
            // concept, one place; a second entry point here would only be a
            // second thing to keep in step.

            Section("About") {
                HStack(spacing: 12) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 48, height: 48)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CodeWake").font(.headline)
                        Text("Version \(state.appVersion)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Based on Lidless by Nghia Luong (MIT)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Link("View the original Lidless project", destination: upstreamURL)
                Text("This local development build has no automatic update feed. A CodeWake update channel will require its own signed and notarized releases.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .environment(\.locale, state.appLanguage.locale)
        .onAppear { state.refreshAudioInputs() }
    }

    @ViewBuilder
    private func audioInputPicker(
        title: LocalizedStringKey,
        slot: AudioInputSlot
    ) -> some View {
        Picker(selection: Binding(
            get: { selectedAudioInputUID(for: slot) },
            set: { uid in
                state.setAudioInput(slot: slot, uid: uid.isEmpty ? nil : uid)
            }
        )) {
            Text("Choose an input…")
                .tag("")
            ForEach(state.audioInputChoices(for: slot), id: \.uid) { choice in
                Text(verbatim: audioInputChoiceLabel(choice))
                    .tag(choice.uid)
                    .disabled(!choice.isAvailable)
            }
        } label: {
            Text(title)
        }
        .accessibilityHint(
            "Choose a different device for each slot. Unavailable inputs stay saved until they reconnect."
        )
        .disabled(state.isSwitchingAudioInput)
    }

    private func selectedAudioInputUID(for slot: AudioInputSlot) -> String {
        switch slot {
        case .primary:
            return state.audioInputConfiguration.primary?.uid ?? ""
        case .secondary:
            return state.audioInputConfiguration.secondary?.uid ?? ""
        }
    }

    private func audioInputChoiceLabel(_ choice: AudioInputChoice) -> String {
        guard !choice.isAvailable else { return choice.displayName }
        return L10n.format(
            "audio.input.choice.unavailable",
            defaultValue: "%@ (Unavailable)",
            language: state.appLanguage,
            choice.displayName
        )
    }

    private func integrationObservation(_ title: String, observed: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: observed ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(observed ? .green : .secondary)
            Text(verbatim: title)
            Spacer()
            Text(observed
                 ? LocalizedStringKey("Observed")
                 : LocalizedStringKey("Awaiting first event"))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func waitingReleaseDelayLabel(seconds: Int) -> String {
        guard seconds > 0 else {
            return L10n.string(
                "ai.wait.immediate",
                defaultValue: "Immediate",
                language: state.appLanguage
            )
        }
        return L10n.format(
            "ai.wait.minutes",
            defaultValue: "%d minutes",
            language: state.appLanguage,
            seconds / 60
        )
    }

    private func maximumHoursLabel(hours: Int) -> String {
        L10n.format(
            "ai.maximum.hours",
            defaultValue: "%d hours",
            language: state.appLanguage,
            hours
        )
    }
}
