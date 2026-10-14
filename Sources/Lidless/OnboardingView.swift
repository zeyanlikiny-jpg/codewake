import SwiftUI

/// First-run setup walkthrough. Explains what CodeWake does and walks the user
/// through the helper and AI hook setup, then hands off to the menu bar. It
/// surfaces existing `AppState` flows only and
/// introduces no new permission logic.
struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @State private var step = 0

    private let lastStep = 4

    var body: some View {
        VStack(spacing: 0) {
            stepContent
                .padding(.horizontal, 36)
                .padding(.top, 36)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 460, height: 560)
        .environment(\.locale, state.appLanguage.locale)
    }

    // MARK: Steps

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0:  welcomeStep
        case 1:  howItWorksStep
        case 2:  helperStep
        case 3:  agentIntegrationStep
        default: doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 88, height: 88)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            Text("Welcome to CodeWake")
                .font(.largeTitle.weight(.semibold))
            Text("Keep your Mac awake — even with the lid closed.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Let coding agents, downloads, or builds keep running while the closed Mac stays plugged in on a cool, ventilated desk. Never put it in a bag while keep-awake is active.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var howItWorksStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            header(symbol: "bolt.fill", title: "How it works")
            VStack(alignment: .leading, spacing: 16) {
                bullet("macbook", "Overrides the lid-close sleep that normally stops everything when you shut the lid.")
                bullet("thermometer.medium", "Auto-pauses if the Mac runs hot or the battery runs low — so it stays safe unattended.")
                bullet("shield.lefthalf.filled", "A durable lease and watchdog restore the sleep setting after an app/helper failure or missed heartbeat.")
                bullet("moon.zzz.fill", "After the final successful AI turn, it confirms completion for five seconds and sleeps a closed Mac when no manual hold remains.")
            }
            Label("Keep your Mac plugged in and ventilated under heavy use.", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private var helperStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            header(symbol: "key.fill", title: "Install the safety helper")
            Text("Install and approve the background helper before using keep-awake. It records ownership before changing macOS power state, so crashes and timeouts can recover safely.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            helperStatusBox

            Text("Manual and automatic modes both require this one-time approval. CodeWake never uses an untracked administrator-command fallback.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var helperStatusBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.usingHelper {
                Label("Background helper installed and active.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if state.helperNeedsApproval {
                Label("Approve CodeWake under System Settings ▸ Login Items, then come back here.", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Login Items to approve…") { state.installHelper() }
            } else {
                Button("Install background helper…") { state.installHelper() }
                    .buttonStyle(.borderedProminent)
            }

            if let err = state.lastError, !state.usingHelper {
                Text(verbatim: err)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var agentIntegrationStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            header(symbol: "terminal.fill", title: "Connect your coding agents")
            Text("Install privacy-minimized lifecycle hooks shared by Codex Desktop, Codex CLI, and Claude Code. They send only opaque IDs/tokens, event type, background-work count, and time — never prompts, answers, paths, commands, or source code.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(verbatim: state.integrationSummary)
                } icon: {
                    Image(systemName: state.integrationHealthy
                          ? "checkmark.circle.fill"
                          : "link.circle")
                }
                .foregroundStyle(state.integrationHealthy ? .green : .primary)
                observationRow("Codex Desktop", observed: state.codexDesktopObserved)
                observationRow("Codex CLI", observed: state.codexCLIObserved)
                observationRow("Claude Code", observed: state.claudeCodeObserved)
                Button {
                    state.installAgentIntegrations()
                } label: {
                    Text(state.integrationInstalled
                         ? LocalizedStringKey("Repair integrations…")
                         : LocalizedStringKey("Install integrations…"))
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            Text("After installation, approve the fixed CodeWake command in `/hooks`, then run one real turn in both Codex Desktop and Codex CLI. Claude Code uses its normal settings trust flow. Configuration alone is not shown as runtime verification.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(symbol: "checkmark.circle.fill", title: "You're all set")
            Text("Start a Codex or Claude Code turn, leave the Mac plugged in and ventilated, then close the lid. CodeWake keeps it awake while work is active. A successful final Stop gets a cancelable five-second confirmation before the closed Mac sleeps; waiting for input keeps its five-minute grace.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Launch CodeWake at login", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)
            .padding(.top, 8)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Back") {
                withAnimation { step -= 1 }
            }
            .disabled(step == 0)
            .opacity(step == 0 ? 0 : 1)

            Spacer()

            HStack(spacing: 6) {
                ForEach(0...lastStep, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: L10n.format(
                "onboarding.step_progress",
                defaultValue: "Step %d of %d",
                language: state.appLanguage,
                step + 1,
                lastStep + 1
            )))

            Spacer()

            Button {
                if step == lastStep {
                    state.completeOnboarding()
                } else {
                    withAnimation { step += 1 }
                }
            } label: {
                Text(step == lastStep
                     ? LocalizedStringKey("Done")
                     : LocalizedStringKey("Continue"))
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Helpers

    private func header(symbol: String, title: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text(title)
                .font(.title.weight(.semibold))
        }
    }

    private func bullet(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func observationRow(_ title: String, observed: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: observed ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(observed ? .green : .secondary)
            Text(verbatim: title)
            Spacer()
            Text(observed
                 ? LocalizedStringKey("Observed")
                 : LocalizedStringKey("Awaiting event"))
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
    }
}
