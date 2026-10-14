import SwiftUI

/// Shared horizontal inset so every row, divider, and the footer line up on the
/// same leading/trailing columns.
private let hInset: CGFloat = 20

private struct MenuBodyHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MenuFooterHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension AgentStatusColorRole {
    var color: Color {
        switch self {
        case .neutral:
            return .primary
        case .working:
            return .green
        case .attention:
            return .red
        }
    }
}

/// The menu bar popover — "Minimal Quick Toggle".
///
/// Keeps only the essentials: the primary keep-awake switch, a compact status
/// strip, and the core safety controls. Everything secondary (helper setup,
/// launch at login, auto-off timer, GitHub) lives in the Settings window.
struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @State private var measuredBodyHeight: CGFloat = 0
    @State private var measuredFooterHeight: CGFloat = 0
    @State private var screenVisibleHeight: CGFloat?

    private var resolvedBodyHeight: CGFloat {
        MenuPopoverLayout.resolvedBodyHeight(
            mode: state.menuPopoverHeightMode,
            contentHeight: measuredBodyHeight,
            footerHeight: measuredFooterHeight,
            screenVisibleHeight: screenVisibleHeight
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
            PopoverHeader()
                .padding(.horizontal, hInset)
                .padding(.top, 18)

            Text("Keeps active AI coding work awake, then restores the Mac’s normal sleep policy when work finishes or an input wait expires.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, hInset)
                .padding(.top, 8)

            Divider()
                .padding(.horizontal, hInset)
                .padding(.top, 14)

            PrimaryToggleRow()
                .padding(.horizontal, hInset)
                .disabled(state.isRestoringNormalSleep || state.isQuitting)

            KeepAwakeDurationRow()
                .padding(.horizontal, hInset)
                .disabled(state.isRestoringNormalSleep || state.isQuitting)

            DisplayAwakeToggleRow()
                .padding(.horizontal, hInset)
                .disabled(state.isRestoringNormalSleep || state.isQuitting)

            BuiltInDisplayBlackoutRow()
                .padding(.horizontal, hInset)

            AllDisplaysSleepRow()
                .padding(.horizontal, hInset)

            if !state.autoWarningReasons.isEmpty {
                AutoDisabledWarning(reasons: state.autoWarningReasons)
                    .padding(.horizontal, hInset)
                    .padding(.bottom, 10)
            }

            Divider()
                .padding(.horizontal, hInset)

            AudioInputQuickSwitch()
                .padding(.horizontal, hInset)
                .padding(.vertical, 10)

            Divider()
                .padding(.horizontal, hInset)

            StatusStrip()
                .padding(.horizontal, hInset)
                .padding(.vertical, 10)

            if state.shouldShowAgentStatus {
                AgentStatusStrip()
                    .padding(.horizontal, hInset)
                    .padding(.bottom, 10)
            }

            CodexStatusActions()
                .padding(.horizontal, hInset)
                .padding(.bottom, 10)

            // Disjoint notice slots ensure a display assertion failure cannot
            // overwrite Helper recovery, verification, or ordinary diagnostics.
            if let notice = state.externalNotice {
                Label {
                    Text(verbatim: notice)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, hInset)
                    .padding(.bottom, 10)
            }

            if let notice = state.verificationNotice {
                Label {
                    Text(verbatim: notice)
                } icon: {
                    Image(systemName: "questionmark.circle.fill")
                }
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, hInset)
                    .padding(.bottom, 10)
            }

            if let notice = state.helperRecoveryNotice {
                Label {
                    Text(verbatim: notice)
                } icon: {
                    Image(systemName: "exclamationmark.shield.fill")
                }
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, hInset)
                    .padding(.bottom, 10)
            }

            if let notice = state.displayAwakeWarning {
                Label {
                    Text(verbatim: notice)
                } icon: {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: "display")
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 8, weight: .bold))
                            .offset(x: 3, y: 2)
                    }
                }
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, hInset)
                    .padding(.bottom, 10)
            }

            if let err = state.lastError {
                Label {
                    Text(verbatim: err)
                } icon: {
                    Image(systemName: "info.circle")
                }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, hInset)
                    .padding(.bottom, 10)
            }

            Divider()
                .padding(.horizontal, hInset)

            SafetySection()
                .padding(.horizontal, hInset)
                .padding(.top, 12)
                .disabled(state.isRestoringNormalSleep || state.isQuitting)

            Divider()
                .padding(.horizontal, hInset)
                .padding(.top, 12)

            AutomaticSection()
                .padding(.horizontal, hInset)
                .padding(.top, 12)
                .disabled(state.isRestoringNormalSleep || state.isQuitting)
                .padding(.bottom, 12)
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: MenuBodyHeightPreferenceKey.self,
                            value: geometry.size.height
                        )
                    }
                }
            }
            .lidlessMenuScrollViewport(height: resolvedBodyHeight)

            VStack(alignment: .leading, spacing: 0) {
                Divider()
                    .padding(.horizontal, hInset)

                FooterActions()
                    .padding(.horizontal, hInset)
                    .padding(.bottom, 14)
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: MenuFooterHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            }
        }
        .frame(width: MenuPopoverLayout.width)
        .background {
            MenuWindowScreenMetricsProbe { visibleHeight in
                guard screenVisibleHeight == nil
                        || abs((screenVisibleHeight ?? 0) - visibleHeight)
                            > MenuPopoverLayout.screenMetricsTolerance
                else { return }
                screenVisibleHeight = visibleHeight
            }
        }
        .onPreferenceChange(MenuBodyHeightPreferenceKey.self) { height in
            guard height.isFinite, height > 0,
                  abs(measuredBodyHeight - height) > 0.5 else { return }
            measuredBodyHeight = height
        }
        .onPreferenceChange(MenuFooterHeightPreferenceKey.self) { height in
            guard height.isFinite, height > 0,
                  abs(measuredFooterHeight - height) > 0.5 else { return }
            measuredFooterHeight = height
        }
        .environment(\.locale, state.appLanguage.locale)
        // The popover is the moment the user actually looks at the toggle, so
        // it's the moment it most needs to be true.
        .onAppear {
            state.refreshState()
            state.refreshDisplayState()
            state.refreshCodexStatus()
            state.refreshAudioInputs()
        }
    }
}

// MARK: - Reusable row

/// A native settings-style row: leading label, flexible gap, trailing control
/// pinned to the shared right edge. Used for the primary toggle and every
/// safety row so all controls share one trailing column.
private struct SettingRow<Trailing: View>: View {
    let title: LocalizedStringKey
    var titleFont: Font = .callout
    var minHeight: CGFloat = 36
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(titleFont)
                .lineLimit(1)
            Spacer(minLength: 16)
            trailing()
                .fixedSize()
        }
        .frame(minHeight: minHeight)
    }
}

// MARK: - Header

private struct PopoverHeader: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("CodeWake").font(.headline)
            Spacer()
            Text("v\(state.appVersion)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Primary control

/// The strongest row in the popover: the main keep-awake action.
private struct PrimaryToggleRow: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        SettingRow(title: "Manual keep awake with lid closed",
                   titleFont: .body.weight(.semibold),
                   minHeight: 42) {
            Toggle("Manual keep awake with lid closed", isOn: Binding(
                get: { state.masterToggleOn },
                set: { state.setMasterToggle($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.regular)
            .tint(.accentColor)
        }
    }
}

// MARK: - Keep-awake duration

/// "Keep awake for 15 minutes" as a single gesture: picking a duration turns
/// keep-awake on and starts the countdown that turns it back off.
///
/// Sits directly under the toggle because it modifies it — this is how long the
/// switch above stays on, not a setting that lives somewhere else.
private struct KeepAwakeDurationRow: View {
    @EnvironmentObject var state: AppState

    private var autoMode: Bool { state.settings.autoEnableWhenCharging }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingRow(title: "Manual keep awake for", minHeight: 32) {
                // A Menu of buttons rather than a Picker: a Picker's binding only
                // fires when the value *changes*, so after a timer had elapsed,
                // choosing the same duration again would do nothing at all —
                // exactly when someone wants another fifteen minutes.
                Menu {
                    Button(durationLabel(minutes: 0)) { state.keepAwakeFor(minutes: 0) }
                    ForEach(AutoOff.presetMinutes, id: \.self) { minutes in
                        Button(durationLabel(minutes: minutes)) {
                            state.keepAwakeFor(minutes: minutes)
                        }
                    }
                } label: {
                    Text(verbatim: durationLabel(minutes: state.autoOffMinutes))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(autoMode)
            }

            if !state.autoOffRemaining.isEmpty {
                Label("Turning off in \(state.autoOffRemaining)", systemImage: "timer")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if autoMode {
                // Auto mode decides activation itself, so a countdown would
                // disarm the feature behind its back. Say so rather than leaving
                // a control that looks live and does nothing.
                Text("Not used while “Automatically enable when charging” is on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 8)
    }

    private func durationLabel(minutes: Int) -> String {
        guard minutes > 0 else {
            return L10n.string(
                "duration.no_limit",
                defaultValue: "No limit",
                language: state.appLanguage
            )
        }
        if minutes.isMultiple(of: 60) {
            return L10n.format(
                "duration.hours",
                defaultValue: "%d hours",
                language: state.appLanguage,
                minutes / 60
            )
        }
        return L10n.format(
            "duration.minutes",
            defaultValue: "%d min",
            language: state.appLanguage,
            minutes
        )
    }
}

private struct DisplayAwakeToggleRow: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingRow(title: "Keep display awake", minHeight: 32) {
                Toggle("Keep display awake", isOn: Binding(
                    get: { state.keepDisplayAwakeDuringActivity },
                    set: { state.setKeepDisplayAwakeDuringActivity($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Keep display awake during activity")
                .accessibilityHint(
                    "Only prevents idle display sleep during active AI work or a manual or timed hold. Waiting, completion confirmation, and charging-only holds do not keep it on. It does not light a sleeping display or override lid-closed behavior."
                )
            }

            Text("Prevents idle display sleep only during active AI work or a manual or timed hold—not while waiting, confirming completion, or charging alone. It doesn’t light a sleeping display or override lid-closed behavior.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 8)
    }
}

private struct BuiltInDisplayBlackoutRow: View {
    @EnvironmentObject var state: AppState

    private var isActive: Bool {
        state.builtInDisplayBlackoutActive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingRow(title: "Built-in display", minHeight: 32) {
                Button(action: state.toggleBuiltInDisplayBlackout) {
                    if isActive {
                        Label("Restore Built-in Display", systemImage: "sun.max.fill")
                    } else {
                        Label("Turn Off Built-in Display", systemImage: "sun.min.fill")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                // Once the display is dark, recovery must remain available even
                // if the wake lease or display topology changes underneath us.
                .disabled(!isActive && !state.canToggleBuiltInDisplayBlackout)
                .accessibilityHint(
                    "Sets only the built-in display brightness to zero. For 1.5 seconds after turn-off, pointer movement, dragging, and scrolling do not restore brightness. Click again or press a regular key to restore immediately; after that, any input restores brightness."
                )
                .help(
                    "Sets only the built-in display brightness to zero. For 1.5 seconds after turn-off, pointer movement, dragging, and scrolling do not restore brightness. Click again or press a regular key to restore immediately; after that, any input restores brightness."
                )
            }

            Text(verbatim: state.builtInDisplayBlackoutAvailabilityMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let warning = state.builtInDisplayBlackoutWarning,
               !warning.isEmpty {
                Label {
                    Text(verbatim: warning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 8)
    }
}

private struct AllDisplaysSleepRow: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingRow(title: "All displays", minHeight: 32) {
                Button(action: state.turnOffAllDisplays) {
                    if state.allDisplaysSleepBusy {
                        Label("Turning Off Displays…", systemImage: "hourglass")
                    } else {
                        Label("Turn Off All Displays", systemImage: "display.2")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!state.canTurnOffAllDisplays)
                .accessibilityHint(
                    "Turns off the built-in and all external displays after 1.5 seconds. Move the mouse or press a key to restore the displays. The Mac keeps its current keep-awake rules."
                )
                .help(
                    "Turns off the built-in and all external displays after 1.5 seconds. Move the mouse or press a key to restore the displays. The Mac keeps its current keep-awake rules."
                )
            }

            Text("Turns off the built-in and all external displays after 1.5 seconds. Move the mouse or press a key to restore the displays. The Mac keeps its current keep-awake rules.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let warning = state.allDisplaysSleepWarning,
               !warning.isEmpty {
                Label {
                    Text(verbatim: warning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 8)
    }
}

// MARK: - Audio input

/// A single-action switch between the two inputs selected in Settings. The
/// button names its destination so a device disappearing never turns a click
/// into a surprising fallback to some other microphone.
private struct AudioInputQuickSwitch: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Microphone input")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.secondary)
                Text("Current system input")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(verbatim: state.currentAudioInputDisplayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: currentInputAccessibilityLabel))

            Button(action: performPrimaryAction) {
                HStack(spacing: 7) {
                    if case .switching = presentation {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: buttonIconName)
                    }
                    Text(verbatim: buttonTitle)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!presentation.allowsButtonAction)
            .accessibilityLabel(Text(verbatim: switchAccessibilityLabel))
            .accessibilityHint(Text(verbatim: switchAccessibilityHint))

            if let notice = audioInputStatusNotice {
                Label {
                    Text(verbatim: notice)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityLabel(Text(verbatim: notice))
            }
        }
    }

    private var audioInputStatusNotice: String? {
        if let notice = state.audioInputNotice { return notice }
        switch presentation {
        case .currentInputInUse:
            return localized(
                "The microphone is being used by another app. Stop recording before switching."
            )
        case .currentInputActivityUnknown:
            return localized(
                "Couldn’t confirm whether the current microphone is in use. Switching is paused for safety."
            )
        case .currentInputReconnecting, .targetReconnecting:
            return localized(
                "The input device is reconnecting. Switching will be available when it is stable."
            )
        case .currentInputUnstable, .targetUnstable:
            return localized(
                "This input device has disconnected repeatedly. Switching will resume automatically when the connection is stable."
            )
        case .targetUnavailable:
            return localized("The selected input device is no longer available.")
        case .needsConfiguration, .switching, .cooldown, .ready:
            return nil
        }
    }

    private func performPrimaryAction() {
        if state.audioInputSwitchNeedsConfiguration {
            MenuBarExtraPanel.dismiss()
            state.showSettings()
        } else {
            state.switchAudioInput()
        }
    }

    private var presentation: AudioInputSwitchPresentation {
        state.audioInputSwitchPresentation
    }

    private var buttonIconName: String {
        switch presentation {
        case .needsConfiguration:
            return "gearshape"
        case .switching, .ready:
            return "arrow.left.arrow.right"
        case .cooldown:
            return "hourglass"
        case .currentInputInUse:
            return "mic.fill"
        case .currentInputActivityUnknown:
            return "questionmark.circle"
        case .currentInputReconnecting, .targetReconnecting:
            return "arrow.clockwise"
        case .currentInputUnstable, .targetUnstable:
            return "exclamationmark.triangle.fill"
        case .targetUnavailable:
            return "mic.slash"
        }
    }

    private var buttonTitle: String {
        switch presentation {
        case .needsConfiguration:
            return localized("Configure Input Switching…")
        case .switching:
            return localized("Switching input…")
        case .cooldown:
            return localized("Please wait…")
        case .currentInputInUse:
            return localized("Microphone in use")
        case .currentInputActivityUnknown:
            return localized("Couldn’t confirm microphone status")
        case .currentInputReconnecting(let name), .targetReconnecting(let name):
            return L10n.format(
                "audio.input.switch.reconnecting",
                defaultValue: "Waiting for %@ to reconnect…",
                language: state.appLanguage,
                name
            )
        case .currentInputUnstable, .targetUnstable:
            return localized("Connection unstable — switching paused")
        case .targetUnavailable(let name):
            return L10n.format(
                "audio.input.switch.unavailable",
                defaultValue: "%@ unavailable",
                language: state.appLanguage,
                name
            )
        case .ready(let name):
            return L10n.format(
                "audio.input.switch.button",
                defaultValue: "Switch to %@",
                language: state.appLanguage,
                name
            )
        }
    }

    private var currentInputAccessibilityLabel: String {
        L10n.format(
            "audio.input.current.accessibility",
            defaultValue: "Current system input: %@",
            language: state.appLanguage,
            state.currentAudioInputDisplayName
        )
    }

    private var switchAccessibilityLabel: String {
        guard case .ready(let name) = presentation else { return buttonTitle }
        return L10n.format(
            "audio.input.switch.accessibility",
            defaultValue: "Switch system input to %@",
            language: state.appLanguage,
            name
        )
    }

    private var switchAccessibilityHint: String {
        switch presentation {
        case .currentInputInUse:
            return localized(
                "The microphone is being used by another app. Stop recording before switching."
            )
        case .currentInputActivityUnknown:
            return localized(
                "Couldn’t confirm whether the current microphone is in use. Switching is paused for safety."
            )
        case .currentInputReconnecting, .targetReconnecting:
            return localized(
                "The input device is reconnecting. Switching will be available when it is stable."
            )
        case .currentInputUnstable, .targetUnstable:
            return localized(
                "This input device has disconnected repeatedly. Switching will resume automatically when the connection is stable."
            )
        case .targetUnavailable:
            return localized("The selected input device is no longer available.")
        case .needsConfiguration:
            return localized(
                "Choose two different input devices. Offline selections stay saved and become available again when reconnected."
            )
        case .switching, .cooldown, .ready:
            return localized(
                "Changes the macOS default input. Apps pinned to another microphone may not follow it."
            )
        }
    }

    private func localized(_ value: String) -> String {
        L10n.string(
            value,
            defaultValue: value,
            language: state.appLanguage
        )
    }
}

// MARK: - Status strip

/// Essential live status: helper health, battery level, and the current display
/// topology reported by the signed-in user's WindowServer session.
private struct StatusStrip: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: state.usingHelper ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(state.usingHelper ? .green : .orange)
                    Text(state.isEnabled ? LocalizedStringKey("Mac awake") : LocalizedStringKey("Normal sleep"))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(sleepAccessibilityLabel)

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    Image(systemName: batterySymbol)
                    Text("Battery \(state.batteryPercent)%")
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(batteryAccessibilityLabel)
            }

            HStack(spacing: 6) {
                Image(systemName: "display")
                    .foregroundStyle(displayStatusColor)
                Text(verbatim: displayStatusText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: displayAccessibilityText))
            .help(displayAccessibilityText)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var sleepAccessibilityLabel: Text {
        if state.isEnabled {
            return Text("Sleep prevention active")
        }
        return Text("Normal sleep policy active")
    }

    private var batteryAccessibilityLabel: Text {
        if state.batteryOnAC {
            return Text("Battery \(state.batteryPercent) percent, on power")
        }
        return Text("Battery \(state.batteryPercent) percent")
    }

    private var displayStatusText: String {
        switch state.externalDisplayState {
        case let .connected(count, names):
            if count == 1, let name = names.first, !name.isEmpty {
                return L10n.format(
                    "display.status.named",
                    defaultValue: "External display: %@",
                    language: state.appLanguage,
                    name
                )
            }
            if count == 1 {
                return L10n.string(
                    "display.status.connected",
                    defaultValue: "External display: Connected",
                    language: state.appLanguage
                )
            }
            return L10n.format(
                "display.status.multiple",
                defaultValue: "%d external displays connected",
                language: state.appLanguage,
                count
            )
        case .disconnected:
            return L10n.string(
                "display.status.disconnected",
                defaultValue: "External display: Not connected",
                language: state.appLanguage
            )
        case .unknown:
            return L10n.string(
                "display.status.unknown",
                defaultValue: "External display: Unable to detect",
                language: state.appLanguage
            )
        }
    }

    private var displayAccessibilityText: String {
        guard case let .connected(count, names) = state.externalDisplayState,
              count > 1,
              !names.isEmpty else {
            return displayStatusText
        }
        let separator = state.appLanguage == .simplifiedChinese ? "、" : ", "
        return L10n.format(
            "display.accessibility.multiple_named",
            defaultValue: "%d external displays connected: %@",
            language: state.appLanguage,
            count,
            names.joined(separator: separator)
        )
    }

    private var displayStatusColor: Color {
        switch state.externalDisplayState {
        case .connected:
            return .green
        case .disconnected:
            return .secondary
        case .unknown:
            return .orange
        }
    }

    /// Closest native battery glyph for the current charge (names available on
    /// macOS 13+).
    private var batterySymbol: String {
        switch state.batteryPercent {
        case 88...:   return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default:      return "battery.0"
        }
    }
}

private struct AgentStatusStrip: View {
    @EnvironmentObject var state: AppState

    private var statusColorRole: AgentStatusColorRole {
        AgentStatusColorRole.resolve(for: state.activityPresentation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label {
                    Text(verbatim: state.agentStatusText)
                } icon: {
                    Image(systemName: "cpu")
                }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(statusColorRole.color)
                Spacer()
                if state.agentSessionCount > 0 {
                    Text(verbatim: L10n.format(
                        "agent.task_count",
                        defaultValue: "%d tasks",
                        language: state.appLanguage,
                        state.agentSessionCount
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !state.wakeSourceSummary.isEmpty {
                Text("Wake source: \(state.wakeSourceSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !state.agentCountdownText.isEmpty {
                Text(verbatim: state.agentCountdownText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CodexStatusActions: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Codex status")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                statusRow(title: "Codex", value: state.codexSoftwareStatusText)
                statusRow(title: "Task", value: state.codexTaskStatusText)
            }

            Button {
                state.refreshCodexStatus()
            } label: {
                HStack(spacing: 7) {
                    if state.isRefreshingCodexStatus {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    if state.isRefreshingCodexStatus {
                        Text("Refreshing…")
                    } else {
                        Text("Refresh Codex Status")
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(state.isRefreshingCodexStatus || state.isRestoringNormalSleep)

            if let notice = state.codexCancellationNotice {
                Label {
                    Text(verbatim: notice)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(.caption)
                .foregroundStyle(Color.green)
                .accessibilityLabel(Text(verbatim: notice))
            }

            Divider()
                .padding(.vertical, 2)

            Text("Emergency recovery")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("Clears every CodeWake keep-awake hold and returns control to macOS. It does not force immediate sleep.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                state.restoreNormalSleep()
            } label: {
                HStack(spacing: 7) {
                    if state.isRestoringNormalSleep {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "moon.zzz")
                    }
                    if state.isRestoringNormalSleep {
                        Text("Restoring…")
                    } else {
                        Text("Restore Normal Sleep")
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(state.isRefreshingCodexStatus || state.isRestoringNormalSleep)

            if let notice = state.normalSleepRestoreStatusText,
               let status = state.normalSleepRestoreStatus {
                Label {
                    Text(verbatim: notice)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: status.isWarning
                        ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                }
                .font(.caption)
                .foregroundStyle(status.isWarning ? Color.orange : Color.green)
            }
        }
    }

    @ViewBuilder
    private func statusRow(title: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Safety

private struct SafetySection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Safety")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            SettingRow(title: "Only while charging") {
                Toggle("Only while charging", isOn: Binding(
                    get: { state.settings.onlyWhileCharging },
                    set: { v in var s = state.settings; s.onlyWhileCharging = v; state.updateSettings(s) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            SettingRow(title: "Pause when running hot") {
                Toggle("Pause when running hot", isOn: Binding(
                    get: { state.settings.pauseOnHighThermal },
                    set: { v in var s = state.settings; s.pauseOnHighThermal = v; state.updateSettings(s) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            LowBatteryCutoffRow()
        }
    }
}

/// Full-width low-battery cutoff slider (0–100%, snapping in 5% steps). `0` means
/// "Never" — the low-battery check is disabled entirely.
private struct LowBatteryCutoffRow: View {
    @EnvironmentObject var state: AppState

    /// The value shown while dragging. Committing on every step would write
    /// UserDefaults — and, in auto mode, run a reconcile that can reach the
    /// privileged helper — once per 5% of travel, so the commit waits for the
    /// drag to end.
    @State private var dragging: Double?

    private var threshold: Int { state.settings.lowBatteryThreshold }

    /// The committed value, or the in-flight one while a drag is in progress.
    private var shown: Int { Int((dragging ?? Double(threshold)).rounded()) }

    /// The cutoff only ever fires off power, so it's meaningless whenever
    /// keep-awake is already gated on being plugged in — under "Only while
    /// charging", and equally under auto mode, which requires external power.
    private var isInactive: Bool {
        state.settings.onlyWhileCharging || state.settings.autoEnableWhenCharging
    }

    private var value: Binding<Double> {
        Binding(get: { dragging ?? Double(threshold) },
                set: { dragging = $0 })
    }

    /// Commit the dragged value once the drag ends, and only if it actually moved.
    private func commit(editing: Bool) {
        guard !editing, let value = dragging else { return }
        dragging = nil
        var updated = state.settings
        updated.lowBatteryThreshold = Int(value.rounded())
        guard updated != state.settings else { return }
        state.updateSettings(updated)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("Low-battery cutoff")
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 16)
                if shown == 0 {
                    Text("Never")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: "\(shown)%")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Slider(value: value,
                   in: 0...100,
                   step: 5,
                   label: { Text("Low-battery cutoff") },
                   minimumValueLabel: { Text("Never").font(.caption2).foregroundStyle(.secondary) },
                   maximumValueLabel: { Text("100%").font(.caption2).foregroundStyle(.secondary) },
                   onEditingChanged: commit)
            .labelsHidden()
            .controlSize(.small)
        }
        .frame(minHeight: 36)
        .padding(.vertical, 4)
        .disabled(isInactive)
    }
}

// MARK: - Auto-mode warning

/// Shown directly under the primary toggle when auto mode is armed but keep-awake
/// isn't live right now, listing every safety check currently blocking it.
private struct AutoDisabledWarning: View {
    @EnvironmentObject var state: AppState
    let reasons: [SafetyReason]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color(nsColor: .systemYellow))
                Text("Automatic mode is on, but keep-awake isn’t active right now.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)

            Text("Temporarily disabled because the following check(s) failed:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                    Text(verbatim: "• \(localizedCheckLabel(reason))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 4)
        }
    }

    private func localizedCheckLabel(_ reason: SafetyReason) -> String {
        switch reason {
        case .highThermal:
            return L10n.string(
                "safety.check.high_thermal",
                defaultValue: "Running hot",
                language: state.appLanguage
            )
        case .notCharging:
            return L10n.string(
                "safety.check.not_charging",
                defaultValue: "Not on charger",
                language: state.appLanguage
            )
        case .lowBattery(let percent):
            return L10n.format(
                "safety.check.low_battery",
                defaultValue: "Battery %d%% is at or below the cutoff",
                language: state.appLanguage,
                percent
            )
        case .notOnPower:
            return L10n.string(
                "safety.check.not_on_power",
                defaultValue: "Not connected to power",
                language: state.appLanguage
            )
        }
    }
}

// MARK: - Automatic

private struct AutomaticSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Automatic")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            SettingRow(title: "Automatically enable when charging") {
                Toggle("Automatically enable when charging", isOn: Binding(
                    get: { state.settings.autoEnableWhenCharging },
                    set: { v in var s = state.settings; s.autoEnableWhenCharging = v; state.updateSettings(s) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Footer

private struct FooterActions: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack {
            SettingsButton()
            Spacer()
            Button {
                state.quitAndRestoreSleep()
            } label: {
                Label {
                    if state.isQuitting {
                        Text("Quitting…")
                    } else {
                        Text("Quit CodeWake")
                    }
                } icon: {
                    Image(systemName: "power")
                }
                    .foregroundStyle(.secondary)
            }
            .disabled(state.isQuitting || state.isRestoringNormalSleep)
            .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .font(.callout)
        .frame(minHeight: 36)
    }
}

/// Opens the Settings window. Neither `SettingsLink` nor `showSettingsWindow:`
/// reliably activates an LSUIElement app (issue #22), so a plain button drives
/// the AppKit-backed `SettingsWindowController` through `AppState`.
private struct SettingsButton: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button {
            // The popover won't close on its own: SwiftUI's `dismiss()` can't
            // reach it, and an accessory app can't reliably take key away from it.
            MenuBarExtraPanel.dismiss()
            state.showSettings()
        } label: {
            Label("Settings…", systemImage: "gearshape")
                .foregroundStyle(.secondary)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}
