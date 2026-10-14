import AppKit
import Combine
import SwiftUI
import Foundation

enum NormalSleepRestoreStatus: Equatable {
    case restored
    case alreadyNormal
    case anotherWakeSettingRemains
    case failed

    var isWarning: Bool {
        self == .anotherWakeSettingRemains || self == .failed
    }
}

@MainActor
final class AppState: ObservableObject {
    /// App-owned language selection. It is deliberately independent of the
    /// system language and defaults to Simplified Chinese for both new and
    /// upgraded installs that do not yet have a saved preference.
    @Published private(set) var appLanguage: AppLanguage = .simplifiedChinese
    /// Presentation-only menu height preference. It is intentionally separate
    /// from every wake, display, Helper, and Agent policy setting.
    @Published private(set) var menuPopoverHeightMode: MenuPopoverHeightMode = .default
    @Published var isEnabled = false {
        didSet {
            if oldValue, !isEnabled,
               builtInDisplayBlackoutActive || builtInDisplayBlackoutBusy {
                displayBlackoutSupervisor.restore()
            }
        }
    }
    @Published var helperInstalled = false
    @Published var helperNeedsApproval = false
    @Published var batteryDescription = ""
    /// Current battery charge (0–100) and whether on AC power. Drives the
    /// popover status strip (icon + "Battery 74%").
    @Published var batteryPercent = 0
    @Published var batteryOnAC = false
    /// Live, presentation-only topology from the signed-in user's display
    /// session. The privileged helper independently rechecks this fact before
    /// any completion-triggered sleep request.
    @Published private(set) var externalDisplayState: ExternalDisplayState = .unknown
    /// One-shot built-in-panel blackout state. This is independent of both the
    /// Helper's SleepDisabled lease and the optional display-idle assertion.
    @Published private(set) var builtInDisplayBlackoutActive = false
    @Published private(set) var builtInDisplayBlackoutBusy = false
    @Published private(set) var builtInDisplayBlackoutRecoveryPending = false
    @Published private var builtInDisplayRecoveryStatus: DisplayBlackoutResponseStatus?
    @Published private var builtInDisplayRecoveryFailure: AllDisplaysSleepPreparationFailure?
    @Published private var builtInDisplayBlackoutWarningCanonical: String?

    /// A one-shot display request, separate from every system wake source and
    /// the saved screen-on preference. Its controller owns the pending work.
    @Published private var allDisplaysSleepSnapshot = AllDisplaysSleepController.Snapshot()

    var allDisplaysSleepBusy: Bool { allDisplaysSleepSnapshot.isBusy }

    var canTurnOffAllDisplays: Bool {
        allDisplaysSleepSnapshot.phase == .idle
            && !isRestoringNormalSleep
            && !isQuitting
    }

    var allDisplaysSleepWarning: String? {
        guard let failure = allDisplaysSleepSnapshot.failure else { return nil }
        let canonical: String
        switch failure {
        case .preparationFailed:
            canonical = allDisplaysSleepSnapshot.preparationFailure?.message
                ?? "Couldn’t restore the built-in display before turning off all displays."
        case .commandLaunchFailed:
            canonical = "Couldn’t start the display sleep request."
        case .commandFailed:
            canonical = "macOS couldn’t turn off all displays."
        case .commandTimedOut:
            canonical = "The display sleep request timed out."
        case .confirmationTimedOut:
            canonical = "macOS didn’t confirm that all displays turned off."
        }
        return localized(canonical, defaultValue: canonical)
    }

    var builtInDisplayBlackoutWarning: String? {
        builtInDisplayBlackoutWarningCanonical.map {
            localized($0, defaultValue: $0)
        }
    }

    /// Keep the restore action reachable even if the wake lease or topology
    /// changes after the panel was darkened. A new arm is deliberately stricter.
    var canToggleBuiltInDisplayBlackout: Bool {
        if builtInDisplayBlackoutActive { return true }
        guard !builtInDisplayBlackoutBusy,
              !builtInDisplayBlackoutRecoveryPending,
              !allDisplaysSleepSnapshot.suspendsDisplayAwake,
              !isRestoringNormalSleep,
              !isQuitting,
              helperLeaseActive,
              isEnabled,
              hasConfirmedState,
              pendingVerification == nil,
              !systemWakeUnavailable,
              externalDisplayState == .disconnected,
              case .ready = builtInDisplayBlackoutCapability else {
            return false
        }
        return true
    }

    var builtInDisplayBlackoutAvailabilityMessage: String {
        let canonical: String
        if builtInDisplayBlackoutActive {
            canonical = "For 1.5 seconds after turn-off, pointer movement, dragging, and scrolling do not restore brightness. Click again or press a regular key to restore immediately; after that, any input restores brightness."
        } else if builtInDisplayBlackoutRecoveryPending {
            canonical = BuiltInDisplayRecoveryPresentation.message(
                status: builtInDisplayRecoveryStatus,
                failure: builtInDisplayRecoveryFailure,
                topology: AllDisplaysSleepTopology.system()
            )
        } else {
            switch externalDisplayState {
            case .connected:
                canonical = "Unavailable while an external display is connected."
            case .unknown:
                canonical = "Display status could not be confirmed."
            case .disconnected:
                if !helperLeaseActive || !isEnabled || !hasConfirmedState
                    || pendingVerification != nil || systemWakeUnavailable {
                    canonical = "Turn on keep-awake before turning off the built-in display."
                } else {
                    switch builtInDisplayBlackoutCapability {
                    case .ready:
                        canonical = "For 1.5 seconds after turn-off, pointer movement, dragging, and scrolling do not restore brightness. Click again or press a regular key to restore immediately; after that, any input restores brightness."
                    case .externalDisplayConnected:
                        canonical = "Unavailable while an external display is connected."
                    case .topologyUnknown:
                        canonical = "Display status could not be confirmed."
                    case .builtInUnavailable, .brightnessUnavailable:
                        canonical = "Built-in display brightness control is unavailable."
                    }
                }
            }
        }
        return localized(canonical, defaultValue: canonical)
    }
    /// User-selected A/B system-input devices. Only persistent Core Audio UIDs
    /// and last-known display names are stored; transient AudioDeviceIDs stay in
    /// the user-session controller.
    @Published private(set) var audioInputConfiguration: AudioInputSwitchConfiguration = .empty
    @Published private(set) var availableAudioInputs: [AudioInputChoice] = []
    @Published private(set) var currentAudioInputUID: String?
    @Published private(set) var isSwitchingAudioInput = false
    @Published private(set) var isAudioInputSwitchCoolingDown = false
    @Published private var stableCurrentAudioInputDisplayName: String?
    @Published private var audioInputError: AudioInputDeviceControllerError?

    var audioInputNotice: String? {
        guard let audioInputError else { return nil }
        let stateNotice: AudioInputSwitchStateNotice?
        switch audioInputError {
        case .inputInUse:
            stateNotice = .currentInputInUse
        case .inputActivityUnknown:
            stateNotice = .currentInputActivityUnknown
        case .targetUnstable:
            stateNotice = .targetUnstable
        case .targetUnavailable:
            stateNotice = .targetUnavailable
        case .configurationIncomplete, .switchAlreadyInProgress,
             .targetBecameUnavailable, .topologyChanged, .refreshFailed,
             .observationFailed, .setFailed, .confirmationTimedOut:
            stateNotice = nil
        }
        if let stateNotice,
           !audioInputSwitchPresentation.matches(stateNotice) {
            return nil
        }

        let canonical: String
        switch audioInputError {
        case .configurationIncomplete, .switchAlreadyInProgress:
            return nil
        case .targetUnavailable:
            canonical = "The selected input device is no longer available."
        case .targetBecameUnavailable:
            canonical = "The target input became unavailable before switching."
        case .targetUnstable:
            canonical = "The target input is unstable. Try again when it is ready."
        case .topologyChanged:
            canonical = "Input devices changed. Please try again."
        case .inputInUse:
            canonical = "The microphone is being used by another app. Stop recording before switching."
        case .inputActivityUnknown:
            canonical = "Couldn’t confirm whether the current microphone is in use. Switching is paused for safety."
        case .refreshFailed:
            canonical = "Couldn’t read the available system input devices."
        case .observationFailed:
            canonical = "Couldn’t monitor system input changes. CodeWake will refresh before switching."
        case .setFailed:
            canonical = "Couldn’t switch the system input device."
        case .confirmationTimedOut:
            canonical = "macOS didn’t confirm the system input change."
        }
        return localized(canonical, defaultValue: canonical)
    }
    /// Raw framework/XPC/POSIX detail for internal diagnosis. User-facing text
    /// is always a stable AppPresentationError category instead.
    private var lastDiagnosticError: String?
    @Published private var lastErrorCanonical: String?
    var lastError: String? {
        get { lastErrorCanonical.map(localizePresentation) }
        set {
            lastDiagnosticError = nil
            lastErrorCanonical = newValue
        }
    }

    /// Explains a toggle that moved by itself. Its own channel, so an external
    /// change and a safety pause can both be on screen at once.
    @Published private var externalNoticeCanonical: String?
    var externalNotice: String? {
        get { externalNoticeCanonical.map(localizePresentation) }
        set { externalNoticeCanonical = newValue }
    }

    /// Transient status of a write we haven't been able to confirm. Also its own
    /// channel, so clearing it can't disturb `lastError`.
    @Published private var verificationNoticeCanonical: String?
    var verificationNotice: String? {
        get { verificationNoticeCanonical.map(localizePresentation) }
        set { verificationNoticeCanonical = newValue }
    }
    /// Durable-helper recovery status has its own channel so an async health
    /// reply cannot overwrite a newer user action or integration message.
    @Published private var helperRecoveryNoticeCanonical: String?
    private(set) var helperRecoveryNotice: String? {
        get { helperRecoveryNoticeCanonical.map(localizePresentation) }
        set { helperRecoveryNoticeCanonical = newValue }
    }
    /// Display-idle assertion failures are independent from the durable Helper
    /// lease. A failed screen hold must never overwrite or veto the stronger
    /// system-wake and recovery diagnostics.
    @Published private var displayAwakeWarningCanonical: String?
    private(set) var displayAwakeWarning: String? {
        get { displayAwakeWarningCanonical.map(localizePresentation) }
        set { displayAwakeWarningCanonical = newValue }
    }

    /// True only when the required privileged helper is registered and approved.
    @Published var usingHelper = false

    /// User-tunable safety preferences (persisted).
    @Published var settings: SafetySettings = .default

    /// Lifecycle-hook automation policy. It is intentionally separate from the
    /// original charging automation: either source may keep the aggregate lease
    /// alive without taking ownership of the other.
    @Published var aiSettings: AIAutomationSettings = .default
    /// User preference only. The live display assertion is derived from this
    /// preference plus an actually active manual/timed or working Agent source.
    @Published private(set) var keepDisplayAwakeDuringActivity = false
    @Published private var integrationSummaryCanonical = "Not installed"
    private(set) var integrationSummary: String {
        get { localizePresentation(integrationSummaryCanonical) }
        set { integrationSummaryCanonical = newValue }
    }
    @Published private(set) var integrationHealthy = false
    @Published private(set) var codexIntegrationHealthy = false
    private var codexLifecycleChannelHealth: CodexLifecycleChannelHealth = .unavailable
    /// Forces a fresh completion-channel proof at the first raw transition to
    /// idle instead of reusing the health snapshot from the preceding work.
    private var codexSummaryWasIdle = true
    @Published private(set) var integrationInstalled = false
    @Published private(set) var integrationObservations = AgentIntegrationObservations(
        bridgeSchemaVersion: HookBridgePayload.currentSchemaVersion
    )
    @Published private(set) var eventServerAvailable = false
    @Published private(set) var agentSessionCount = 0
    @Published private(set) var agentWorkingCount = 0
    @Published private(set) var agentWaitingCount = 0
    @Published private(set) var agentFinishingCount = 0
    @Published private(set) var isRefreshingCodexStatus = false
    @Published private(set) var codexProcessPresence: CodexProcessPresence?
    @Published private(set) var codexTaskSemanticStatus: CodexTaskSemanticStatus?

    var codexSoftwareStatusText: String {
        let keyAndDefault: (String, String)
        switch codexProcessPresence {
        case .desktopOnly?:
            keyAndDefault = ("codex.software.desktop_open", "Desktop app open")
        case .cliOnly?:
            keyAndDefault = ("codex.software.cli_open", "CLI open")
        case .both?:
            keyAndDefault = ("codex.software.both_open", "Desktop app and CLI open")
        case .notDetected?:
            keyAndDefault = ("codex.software.not_detected", "Not detected")
        case .scanFailed?:
            keyAndDefault = ("codex.software.detection_failed", "Unable to detect")
        case nil:
            keyAndDefault = ("codex.software.not_checked", "Not checked")
        }
        return localized(keyAndDefault.0, defaultValue: keyAndDefault.1)
    }

    var codexTaskStatusText: String {
        guard let codexTaskSemanticStatus else {
            return localized("codex.task.unknown", defaultValue: "Status unknown")
        }
        switch codexTaskSemanticStatus {
        case .working(let details):
            return codexTaskDetailsText(details)
        case .waiting(let details):
            return codexTaskDetailsText(details)
        case .finishing(let details):
            return codexTaskDetailsText(details)
        case .idle:
            return localized("codex.task.idle", defaultValue: "No active task")
        case .unknown:
            return localized("codex.task.unknown", defaultValue: "Status unknown")
        }
    }

    /// Preserve every root-task bucket in mixed states. The semantic reducer's
    /// leading case is only a priority for presentation order; it must not hide
    /// a second task that is waiting or still confirming completion.
    private func codexTaskDetailsText(_ details: CodexTaskSemanticDetails) -> String {
        var parts: [String] = []
        if details.workingCount > 0 {
            parts.append(L10n.format(
                "codex.task.working",
                defaultValue: "Working (%d)",
                language: appLanguage,
                details.workingCount
            ))
        }
        if details.waitingCount > 0 {
            let keyAndDefault: (String, String)
            switch details.waitingReason {
            case .planConfirmation:
                keyAndDefault = (
                    "codex.task.waiting.plan",
                    "Waiting for plan confirmation (%d)"
                )
            case .permission:
                keyAndDefault = (
                    "codex.task.waiting.permission",
                    "Waiting for permission (%d)"
                )
            case .userInput, .unknown, nil:
                keyAndDefault = (
                    "codex.task.waiting.input",
                    "Waiting for input (%d)"
                )
            }
            parts.append(L10n.format(
                keyAndDefault.0,
                defaultValue: keyAndDefault.1,
                language: appLanguage,
                details.waitingCount
            ))
        }
        if details.finishingCount > 0 {
            parts.append(L10n.format(
                "codex.task.finishing",
                defaultValue: "Confirming completion (%d)",
                language: appLanguage,
                details.finishingCount
            ))
        }
        if details.unknownCount > 0 {
            parts.append(L10n.format(
                "codex.task.unknown_count",
                defaultValue: "Unknown (%d)",
                language: appLanguage,
                details.unknownCount
            ))
        }
        return parts.isEmpty
            ? localized("codex.task.unknown", defaultValue: "Status unknown")
            : parts.joined(separator: " · ")
    }
    @Published private var agentStatusTextCanonical = "No AI session"
    private(set) var agentStatusText: String {
        get { localizePresentation(agentStatusTextCanonical) }
        set { agentStatusTextCanonical = newValue }
    }
    @Published private var agentCountdownTextCanonical = ""
    private(set) var agentCountdownText: String {
        get { localizePresentation(agentCountdownTextCanonical) }
        set { agentCountdownTextCanonical = newValue }
    }
    @Published private var agentCompletionNoticeCanonical: String?
    private(set) var agentCompletionNotice: String? {
        get { agentCompletionNoticeCanonical.map(localizePresentation) }
        set { agentCompletionNoticeCanonical = newValue }
    }
    /// Independent acknowledgement for a precise Codex cancellation. It stays
    /// visible even when a sibling Codex turn or Claude session is still active,
    /// while the aggregate Agent status continues to describe that live work.
    @Published private var codexCancellationNoticeCanonical: String?
    private(set) var codexCancellationNotice: String? {
        get { codexCancellationNoticeCanonical.map(localizePresentation) }
        set { codexCancellationNoticeCanonical = newValue }
    }
    @Published private var agentLastEventType: String?
    var agentLastEventTypeText: String {
        agentLastEventType ?? localized(
            "diagnostics.none_observed",
            defaultValue: "None observed"
        )
    }
    @Published private var agentLastEventReceivedAt: Date?
    var agentLastEventReceivedText: String {
        guard let agentLastEventReceivedAt else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = appLanguage.locale
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: agentLastEventReceivedAt)
    }
    @Published private(set) var agentLastEventRejectionCode = "none"
    @Published private var wakeSourceSummaryCanonical = ""
    private(set) var wakeSourceSummary: String {
        get { localizePresentation(wakeSourceSummaryCanonical) }
        set { wakeSourceSummaryCanonical = newValue }
    }
    @Published private(set) var shouldShowAgentStatus = false
    @Published private(set) var manualWakeRequested = false
    @Published private(set) var isRestoringNormalSleep = false
    @Published private(set) var isQuitting = false
    @Published private(set) var normalSleepRestoreStatus: NormalSleepRestoreStatus?

    var normalSleepRestoreStatusText: String? {
        guard let normalSleepRestoreStatus else { return nil }
        switch normalSleepRestoreStatus {
        case .restored:
            return localized(
                "codex.restore.result.restored",
                defaultValue: "Normal sleep restored. All CodeWake holds were cleared."
            )
        case .alreadyNormal:
            return localized(
                "codex.restore.result.already_normal",
                defaultValue: "Normal sleep was already active."
            )
        case .anotherWakeSettingRemains:
            return localized(
                "codex.restore.result.other_setting",
                defaultValue: "CodeWake released its hold, but another app or system setting still prevents sleep."
            )
        case .failed:
            return localized(
                "codex.restore.result.failed",
                defaultValue: "CodeWake could not confirm that normal sleep was restored."
            )
        }
    }

    /// Auto-mode master-toggle intent (persisted): whether the user wants
    /// keep-awake armed. In auto mode the *live* state (`isEnabled`) is derived
    /// from `armed` gated by power + safety — see `reconcile()`. Unused in manual
    /// mode, where the toggle drives `isEnabled` directly; it's (re-)seeded on the
    /// way into auto mode rather than tracked continuously.
    @Published var armed = false

    /// The currently-unmet checks to surface in the popover's auto-mode warning,
    /// or empty when there's nothing to warn about. Non-empty only when auto mode
    /// is on, the feature is armed, but keep-awake isn't live right now.
    var autoWarningReasons: [SafetyReason] {
        guard settings.autoEnableWhenCharging, armed, !isEnabled else { return [] }
        return SafetyEvaluator.allUnmetReasons(battery: currentBattery,
                                               thermalSerious: thermalSerious(),
                                               settings: settings,
                                               requirePower: true)
    }

    /// The value the main "Keep awake with lid closed" toggle should show: the
    /// armed intent in auto mode, or either user-controlled manual source.
    var masterToggleOn: Bool {
        settings.autoEnableWhenCharging
            ? armed
            : (manualWakeRequested || autoOffDeadline != nil)
    }

    /// True only while a user-controlled manual source is currently permitted
    /// and the system is actually keeping the Mac awake. Requested sources under
    /// a safety veto are deliberately excluded from the menu-bar color.
    var isManualKeepAwakeActive: Bool {
        guard isEnabled else { return false }
        return wakeArbiter.decision.activeSources.contains { source in
            switch source {
            case .manual, .manualTimer:
                return true
            case .charging, .agent:
                return false
            }
        }
    }

    /// Single semantic presentation shared by the menu-bar item and the
    /// popover's primary Agent status row. Raw aggregate task counters are
    /// diagnostics only and never select an activity color.
    var activityPresentation: MenuBarIconPresentation {
        MenuBarIconPresentation.resolve(
            isKeepAwakeActive: wakeArbiter.decision.hasVerifiedActiveWakeHold(
                systemKeepAwake: isEnabled,
                helperLeaseActive: helperLeaseActive
            ),
            isManualKeepAwakeActive: isManualKeepAwakeActive,
            codexStatus: codexTaskSemanticStatus
        )
    }

    /// Launch-at-login state (the app itself).
    @Published var launchAtLogin = false

    /// Auto-off timer: minutes after which keep-awake turns itself off
    /// (`0` = never). Persisted.
    @Published var autoOffMinutes = 0
    /// When the active auto-off timer will fire; nil when not counting down.
    @Published var autoOffDeadline: Date?
    /// Human countdown (e.g. `1:05:09`) shown while a timer is active.
    @Published var autoOffRemaining = ""

    /// Whether the user has finished first-run onboarding (persisted).
    @Published var onboardingComplete = false

    private let helper = HelperManager()
    /// Reads the flag on every path — `pmset -g` needs no privileges. All writes
    /// go through the durable privileged-helper lease protocol.
    private let power = PowerManager()
    private let battery = BatteryMonitor()
    private let displayTopology = DisplayTopologyMonitor()
    private let displayBlackoutSupervisor = DisplayBlackoutSupervisor()
    private let allDisplaysSleepController = AllDisplaysSleepController()
    private var displayTopologyCancellable: AnyCancellable?
    private var builtInDisplayBlackoutCapability: DisplayBlackoutCapability =
        .brightnessUnavailable
    private let audioInputController = AudioInputDeviceController()
    private var audioInputCancellables = Set<AnyCancellable>()
    private var audioInputSwitchGate = AudioInputSwitchRequestGate()
    private var audioInputSwitchRequestActive = false
    private var audioInputControllerIsSwitching = false
    private var audioInputSwitchTask: Task<Void, Never>?
    private var audioInputCooldownTask: Task<Void, Never>?
    private var audioInputCooldownGeneration: UInt64?
    // Renew from the same 30-second cadence as the durable Helper lease. The
    // controller still enforces its own edge/backoff rules, while disabling its
    // private timer lets AppState surface renewal failures immediately.
    private let displaySleepAssertion = DisplaySleepAssertionController(
        automaticallyRenews: false
    )
    private let store = SettingsStore()
    private let loginItem = LoginItemManager()
    private lazy var onboarding = OnboardingController(state: self)
    private let agentEventServer = AgentEventSocketServer()
    /// Content-free fallback for the cancellation edge that Codex does not
    /// currently expose through its public hook surface. Disk IO always runs on
    /// `codexCancellationScanQueue`, except for one bounded launch gate before a
    /// provisional recovery is allowed to reach the helper lease.
    private let codexCancellationObserver = CodexCancellationObserver()
    private let codexCancellationScanQueue = DispatchQueue(
        label: "com.kenny.lidlessai.codex-cancellation",
        qos: .utility
    )
    private var periodicCodexCancellationScanInFlight = false
    private var agentMachine = AgentStateMachine()
    /// Active sessions loaded from disk are provisional. They may be restored
    /// only when the helper proves the pre-crash aggregate lease is still live,
    /// or a fresh authoritative hook proves that exact session is alive.
    private var pendingAgentRecovery: AgentStateRecoverySnapshot?
    private var wakeArbiter = WakeIntentArbiter()
    private var knownAgentSources: Set<WakeIntentSource> = []
    /// Per-turn edge tracking is separate from the root-session wake sources.
    /// It lets completion policy inspect exactly the turns that ended on the
    /// final edge without allocating one helper lease per subagent.
    private var knownActiveAgentTurns: Set<AgentTurnKey> = []
    private var aggregateWakeRequested = false
    private var lastProcessSnapshots: [AgentProcessIdentity: AgentProcessSnapshot] = [:]
    private var agentProcessAssociations = AgentProcessAssociationTracker()
    private var agentProcessScanGate = AgentProcessScanGenerationGate()
    /// `nil` means no successful latest scan can support an idle claim. An empty
    /// set means a complete scan succeeded and found no Codex process.
    private var latestScannedCodexProcessIdentities: Set<AgentProcessIdentity>?
    /// Current-process proof, not the persisted "surface observed sometime"
    /// diagnostics. Identity includes process start time, so relaunch requires a
    /// fresh lifecycle event before the status view may claim idle.
    private var codexLifecycleObservedProcessIdentities: Set<AgentProcessIdentity> = []
    /// Owns the cancellable window before a completion-triggered helper release
    /// is actually submitted. StateSync can reject a stale callback, but only
    /// this generation gate can stop the stale power mutation itself.
    private var conditionalSleepRelease = ConditionalSleepReleaseCoordinator()
    /// Completion blockers are presentation-only once consumed. They must never
    /// become a deferred sleep request when a manual/charging source ends later.
    private var consumedCompletionBlockers: Set<AgentSleepReleaseBlocker> = []
    private var consumedCompletionLabel = "FINISHED"
    private var consumedCompletionReleasePending = false
    private var conditionalReleaseLabel = "FINISHED"

    private lazy var settingsWindow = SettingsWindowController(
        title: localized(
            "window.settings.title",
            defaultValue: "CodeWake Settings"
        ),
        contentSize: SettingsView.preferredSize
    ) { [weak self] in
        guard let self else { return AnyView(EmptyView()) }
        return AnyView(
            SettingsView()
                .environmentObject(self)
        )
    }

    /// Marketing version shown in the menu.
    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private func localized(_ key: String, defaultValue: String) -> String {
        L10n.string(
            key,
            defaultValue: defaultValue,
            language: appLanguage
        )
    }

    private func localizePresentation(_ canonical: String) -> String {
        PresentationLocalizer.string(canonical, language: appLanguage)
    }

    private func setPresentationError(
        _ error: AppPresentationError,
        diagnostic: String
    ) {
        lastDiagnosticError = diagnostic
        lastErrorCanonical = error.canonicalMessage
    }
    private var batteryTimer: Timer?
    private var heartbeatTimer: Timer?
    private var autoOffTimer: Timer?
    private var agentStatusTimer: Timer?
    private let aggregateLeaseID = "com.kenny.lidlessai.aggregate-wake"
    @Published private var helperLeaseActive = false {
        didSet {
            if oldValue, !helperLeaseActive,
               builtInDisplayBlackoutActive || builtInDisplayBlackoutBusy {
                displayBlackoutSupervisor.restore()
            }
        }
    }
    private var helperLeaseDeadline = Date.distantPast
    private var helperLeaseHasHardDeadline = false
    private var aggregateDecisionDeadline = Date.distantPast

    /// Last-known "helper is usable" value, so we can detect it flipping on at
    /// runtime (right after the user approves it) and prompt a restart.
    private var helperWasUsable = false
    /// True once the system flag has been read successfully this session. Set
    /// only by a read — a write's success reply is a claim, not a reading, and
    /// treating it as one would let an unconfirmed write masquerade as drift.
    @Published private var hasConfirmedState = false
    /// The write currently awaiting confirmation, if any.
    private var pendingVerification: PendingVerification?
    /// Rejects async replies that have been superseded.
    private var sync = StateSync()
    /// True while the onboarding window is open and not yet completed.
    private var onboardingActive = false
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var willTerminateObserver: NSObjectProtocol?
    private var workspaceSessionResignObserver: NSObjectProtocol?
    private var workspaceSessionBecomeObserver: NSObjectProtocol?
    private var workspaceWillPowerOffObserver: NSObjectProtocol?
    private var helperHealthGeneration = 0
    /// Prevents any wake source from acquiring/updating the aggregate lease
    /// while the helper registration is being replaced. The old helper first
    /// releases its durable lease, so unregister can never orphan SleepDisabled.
    private var helperRepairInFlight = false
    /// One unexpected external 1→0 drift is retried transactionally. A second
    /// immediate mismatch becomes a global veto instead of an unbounded XPC loop.
    private var unexpectedDisableReassertionAttempted = false
    @Published private var systemWakeUnavailable = false {
        didSet {
            if !oldValue, systemWakeUnavailable,
               builtInDisplayBlackoutActive || builtInDisplayBlackoutBusy {
                displayBlackoutSupervisor.restore()
            }
        }
    }
    /// While a pre-crash session snapshot is provisional, the first helper
    /// state read must complete before this instance may mutate the aggregate
    /// lease. Otherwise a fresh session could refresh the same lease ID and make
    /// stale sibling sessions appear to have survived the crash.
    private var recoveryLeaseInspectionInFlight = false
    /// Explicit Quit waits for the same safe policy-only release used by the
    /// emergency restore button. The generation prevents an XPC reply arriving
    /// after the bounded quit timeout from mutating a new operation.
    private var normalSleepRestoreGeneration = 0
    private var terminateAfterNormalSleepRestore = false
    private var intentionalQuitPrepared = false
    private var terminationReadyHandler: (() -> Void)?
    private var relaunchAfterTermination = false

    init() {
        let launchedAt = Date()
        appLanguage = store.loadAppLanguage()
        menuPopoverHeightMode = store.loadMenuPopoverHeightMode()
        settings = store.load()
        aiSettings = store.loadAIAutomationSettings()
        keepDisplayAwakeDuringActivity = store.loadKeepDisplayAwakeDuringActivity()
        audioInputConfiguration = store.loadAudioInputSwitchConfiguration()
        integrationObservations = store.loadAgentIntegrationObservations(
            bridgeSchemaVersion: HookBridgePayload.currentSchemaVersion
        )
        agentMachine.updatePolicy(
            maximumTurnDuration: aiSettings.maximumDuration,
            completionConfirmation: AIAutomationSettings.completionConfirmation,
            waitingGrace: aiSettings.waitingReleaseDelay
        )
        if let recovery = store.loadAgentRecoverySnapshot() {
            if recovery.sessions.isEmpty {
                agentMachine.restore(recovery, at: launchedAt)
            } else {
                // Terminal tombstones are safe to restore immediately; only
                // wake-eligible sessions remain provisional until a live helper
                // lease or a fresh hook proves them.
                agentMachine.restore(
                    AgentStateRecoverySnapshot(
                        sessions: [],
                        tombstones: recovery.tombstones
                    ),
                    at: launchedAt
                )
                pendingAgentRecovery = AgentStateRecoverySnapshot(
                    sessions: recovery.sessions,
                    tombstones: []
                )
            }
        }
        armed = store.loadArmed()
        autoOffMinutes = store.loadAutoOffMinutes()
        onboardingComplete = store.loadOnboardingComplete()
        launchAtLogin = loginItem.isEnabled
        audioInputController.$availableInputs
            .removeDuplicates()
            .sink { [weak self] inputs in
                guard let self else { return }
                self.availableAudioInputs = inputs
                self.refreshAudioInputLastKnownNames()
                self.refreshCurrentAudioInputDisplayName()
            }
            .store(in: &audioInputCancellables)
        audioInputController.$defaultInputUID
            .removeDuplicates()
            .sink { [weak self] uid in
                guard let self else { return }
                self.currentAudioInputUID = uid
                self.refreshCurrentAudioInputDisplayName()
            }
            .store(in: &audioInputCancellables)
        audioInputController.$isSwitching
            .removeDuplicates()
            .sink { [weak self] switching in
                guard let self else { return }
                self.audioInputControllerIsSwitching = switching
                self.publishAudioInputSwitchingState()
            }
            .store(in: &audioInputCancellables)
        audioInputController.$lastError
            .removeDuplicates()
            .sink { [weak self] error in
                self?.audioInputError = error
            }
            .store(in: &audioInputCancellables)
        audioInputController.refresh()
        // Bind the hook socket before synchronous pmset/battery probes. The
        // bridge has a strict one-second launch budget, so cold-start lifecycle
        // events must not wait behind power-state inspection.
        startAgentEventServer()
        displayBlackoutSupervisor.onSnapshotChange = { [weak self] snapshot in
            self?.applyDisplayBlackoutSnapshot(snapshot)
        }
        allDisplaysSleepController.onSnapshotChange = { [weak self] snapshot in
            guard let self else { return }
            self.allDisplaysSleepSnapshot = snapshot
            if snapshot.phase != .preparing {
                self.displayBlackoutSupervisor.cancelAllDisplaysSleepPreparation()
            }
            self.reconcileDisplayAwake()
        }
        displayTopologyCancellable = displayTopology.$state
            .sink { [weak self] state in
                self?.handleDisplayTopologyChange(state)
            }
        builtInDisplayBlackoutCapability =
            displayBlackoutSupervisor.refreshCapability()
        displayBlackoutSupervisor.recoverAtLaunchIfNeeded()
        reconcileCodexCancellationsAtLaunch(at: launchedAt)
        refreshHelperStatus()
        refreshHelperRegistrationIfUpdated()
        helperWasUsable = usingHelper
        inspectHelperLeaseHealth()
        refreshState()
        refreshBattery()
        refreshIntegrationHealth()
        // Auto mode owns the live state at launch: (re-)activate if armed and
        // conditions allow, or turn it off if a prior session left it on with
        // conditions since lapsed. `refreshState()` above reads the flag
        // synchronously, so `isEnabled` is already the real state to compare
        // against and there's nothing to force.
        //
        // Plainly `reconcile()`, not `reconcileNow()`: adopting the state that
        // read just established may already have dispatched a write, and clearing
        // that claim here would dispatch a second one for the same decision.
        reconcile()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        agentStatusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.agentTick() }
        }
        // Re-check the helper whenever the app comes forward — e.g. when the user
        // returns from approving it in System Settings — so we notice it being
        // enabled without requiring a manual restart.
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recheckHelper()
                // Also re-read the flag: it may have been changed from a Terminal
                // the user was just in. `recheckHelper` only refreshes on the rare
                // helper unusable→usable transition.
                self?.refreshState()
                self?.refreshDisplayState()
                self?.refreshAudioInputs()
                self?.startAgentEventServer()
                self?.refreshIntegrationHealth()
                self?.schedulePeriodicCodexCancellationScan()
            }
        }
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.allDisplaysSleepController.onSnapshotChange = nil
                self.allDisplaysSleepController.cancel()
                self.displayBlackoutSupervisor.closeControlPipeForTermination()
                self.stopDisplayAwakeAssertion()
                // Explicit Quit has already persisted tombstones and completed
                // (or bounded) the policy-only helper release. Repeating the old
                // fire-and-forget path here would reintroduce the quit race.
                guard !self.intentionalQuitPrepared else { return }
                self.conditionalSleepRelease.cancel()
                guard self.helperLeaseActive else { return }
                self.store.saveAgentRecoverySnapshot(
                    self.agentMachine.recoverySnapshot(at: Date())
                )
                self.helper.releaseLease(id: self.aggregateLeaseID) { _, _ in }
            }
        }
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceSessionResignObserver = workspaceNotifications.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.beginNormalSleepRestore(terminateWhenFinished: false)
            }
        }
        workspaceSessionBecomeObserver = workspaceNotifications.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDisplayState()
                self?.displayBlackoutSupervisor.retryPendingRecovery()
            }
        }
        workspaceWillPowerOffObserver = workspaceNotifications.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.beginNormalSleepRestore(terminateWhenFinished: false)
            }
        }
        // First launch shows onboarding once (persisted so closing it early won't
        // re-nag). A relaunch triggered mid-onboarding resumes the flow instead.
        if store.loadResumeOnboarding() {
            store.saveResumeOnboarding(false)
            DispatchQueue.main.async { [weak self] in self?.showOnboarding() }
        } else if !onboardingComplete {
            onboardingComplete = true
            store.saveOnboardingComplete(true)
            DispatchQueue.main.async { [weak self] in self?.showOnboarding() }
        }
    }

    deinit {
        audioInputSwitchTask?.cancel()
        audioInputCooldownTask?.cancel()
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
        if let willTerminateObserver {
            NotificationCenter.default.removeObserver(willTerminateObserver)
        }
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        if let workspaceSessionResignObserver {
            workspaceNotifications.removeObserver(workspaceSessionResignObserver)
        }
        if let workspaceSessionBecomeObserver {
            workspaceNotifications.removeObserver(workspaceSessionBecomeObserver)
        }
        if let workspaceWillPowerOffObserver {
            workspaceNotifications.removeObserver(workspaceWillPowerOffObserver)
        }
        agentEventServer.stop()
    }

    // MARK: Onboarding

    /// Present the first-run setup window (also reachable from Settings).
    func showOnboarding() {
        onboardingActive = true
        onboarding.updateTitle(localized(
            "window.onboarding.title",
            defaultValue: "Welcome to CodeWake"
        ))
        onboarding.show()
    }

    /// Mark onboarding done, persist it, and close the window.
    func completeOnboarding() {
        onboardingActive = false
        onboardingComplete = true
        store.saveOnboardingComplete(true)
        store.saveResumeOnboarding(false)
        onboarding.close()
    }

    // MARK: Settings

    /// Present the Settings window from the menu-bar popover.
    func showSettings() {
        settingsWindow.updateTitle(localized(
            "window.settings.title",
            defaultValue: "CodeWake Settings"
        ))
        settingsWindow.show()
    }

    /// Persist and immediately publish the selected language. This intentionally
    /// does not reconcile power state, update a helper lease, or touch any Agent
    /// session: localization is presentation-only.
    func setAppLanguage(_ language: AppLanguage) {
        guard appLanguage != language else { return }
        appLanguage = language
        store.saveAppLanguage(language)
        settingsWindow.updateTitle(localized(
            "window.settings.title",
            defaultValue: "CodeWake Settings"
        ))
        onboarding.updateTitle(localized(
            "window.onboarding.title",
            defaultValue: "Welcome to CodeWake"
        ))
    }

    /// Persist and immediately publish the popover height mode. This is a
    /// presentation-only preference and must never reconcile power state or
    /// mutate Helper/Agent/display-awake policy.
    func setMenuPopoverHeightMode(_ mode: MenuPopoverHeightMode) {
        guard menuPopoverHeightMode != mode else { return }
        menuPopoverHeightMode = mode
        store.saveMenuPopoverHeightMode(mode)
    }

    /// Persist the preference independently from AI and safety policy, then
    /// apply it immediately to the current qualifying wake sources.
    func setKeepDisplayAwakeDuringActivity(_ enabled: Bool) {
        guard keepDisplayAwakeDuringActivity != enabled else { return }
        keepDisplayAwakeDuringActivity = enabled
        store.saveKeepDisplayAwakeDuringActivity(enabled)
        reconcileDisplayAwake(now: Date())
    }

    // MARK: System audio input

    var currentAudioInputDisplayName: String {
        stableCurrentAudioInputDisplayName
            ?? localized("No system input", defaultValue: "No system input")
    }

    var audioInputSwitchNeedsConfiguration: Bool {
        let configuration = audioInputConfiguration.sanitized()
        return configuration.primary == nil || configuration.secondary == nil
    }

    var audioInputSwitchTargetDisplayName: String {
        guard let route = currentAudioInputSwitchRoute else {
            return localized("No system input", defaultValue: "No system input")
        }
        return audioInputController.choice(for: route.target).displayName
    }

    var audioInputSwitchPresentation: AudioInputSwitchPresentation {
        if isSwitchingAudioInput { return .switching }
        if isAudioInputSwitchCoolingDown { return .cooldown }
        if audioInputSwitchNeedsConfiguration { return .needsConfiguration }

        guard let currentAudioInputUID,
              let current = availableAudioInputs.first(where: {
                  $0.uid == currentAudioInputUID
              }) else {
            return .currentInputActivityUnknown
        }
        let currentStability: AudioInputSwitchObservedStability
        switch current.stability {
        case .stable:
            currentStability = .stable
        case .reconnecting:
            currentStability = .reconnecting
        case .unstable:
            currentStability = .unstable
        }
        if let blockingState = AudioInputSwitchPresentation.blockingCurrentInputState(
            displayName: current.displayName,
            stability: currentStability,
            observationIsTrustworthy: audioInputError != .refreshFailed,
            isAvailable: current.isAvailable,
            isRunningSomewhere: current.isRunningSomewhere
        ) {
            return blockingState
        }

        guard let route = currentAudioInputSwitchRoute else {
            return .targetUnavailable(audioInputSwitchTargetDisplayName)
        }
        let target = audioInputController.choice(for: route.target)
        switch target.stability {
        case .stable:
            break
        case .reconnecting:
            return .targetReconnecting(target.displayName)
        case .unstable:
            return .targetUnstable
        }
        guard target.isAvailable, target.isSwitchEligible else {
            return .targetUnavailable(target.displayName)
        }
        return .ready(target.displayName)
    }

    var audioInputSwitchCanExecute: Bool {
        if case .ready = audioInputSwitchPresentation { return true }
        return false
    }

    /// Online inputs plus either slot's retained offline selection. The device
    /// already used by the other slot is excluded, so the settings UI cannot
    /// create an ambiguous A/A configuration.
    func audioInputChoices(for slot: AudioInputSlot) -> [AudioInputChoice] {
        let retained = [
            audioInputConfiguration.primary,
            audioInputConfiguration.secondary
        ].compactMap { $0 }
        let otherUID: String?
        switch slot {
        case .primary:
            otherUID = audioInputConfiguration.secondary?.uid
        case .secondary:
            otherUID = audioInputConfiguration.primary?.uid
        }
        return audioInputController.choices(retaining: retained).filter { choice in
            choice.uid != otherUID
        }
    }

    func setAudioInput(slot: AudioInputSlot, uid: String?) {
        guard !isSwitchingAudioInput else { return }
        let cleanUID = uid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedUID = cleanUID?.isEmpty == false ? cleanUID : nil

        let otherUID: String?
        switch slot {
        case .primary:
            otherUID = audioInputConfiguration.secondary?.uid
        case .secondary:
            otherUID = audioInputConfiguration.primary?.uid
        }
        guard selectedUID == nil || selectedUID != otherUID else { return }

        let selection: AudioInputSelection?
        if let selectedUID {
            let retained = [
                audioInputConfiguration.primary,
                audioInputConfiguration.secondary
            ].compactMap { $0 }
            guard let choice = audioInputController
                .choices(retaining: retained)
                .first(where: { $0.uid == selectedUID }) else { return }
            selection = AudioInputSelection(
                uid: choice.uid,
                lastKnownName: choice.displayName
            )
        } else {
            selection = nil
        }

        var configuration = audioInputConfiguration
        switch slot {
        case .primary:
            configuration.primary = selection
        case .secondary:
            configuration.secondary = selection
        }
        configuration = configuration.sanitized()
        guard configuration != audioInputConfiguration else { return }
        audioInputConfiguration = configuration
        store.saveAudioInputSwitchConfiguration(configuration)
        refreshAudioInputs()
    }

    func refreshAudioInputs() {
        audioInputController.refresh()
    }

    func switchAudioInput() {
        guard !audioInputSwitchNeedsConfiguration else {
            showSettings()
            return
        }
        guard case .ready = audioInputSwitchPresentation,
              let route = currentAudioInputSwitchRoute else { return }

        let acceptedAt = ProcessInfo.processInfo.systemUptime
        guard let token = audioInputSwitchGate.begin(at: acceptedAt) else { return }
        let expectedTopologyGeneration = audioInputController.topologyGeneration

        audioInputCooldownTask?.cancel()
        audioInputCooldownTask = nil
        audioInputCooldownGeneration = nil
        isAudioInputSwitchCoolingDown = false
        audioInputSwitchRequestActive = true
        publishAudioInputSwitchingState()

        audioInputSwitchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let completedRoute: AudioInputSwitchRoute?
            do {
                completedRoute = try await self.audioInputController.switchInput(
                    route: route,
                    expectedTopologyGeneration: expectedTopologyGeneration
                )
                self.refreshAudioInputLastKnownNames()
            } catch {
                // The controller publishes a stable error category. Keeping the
                // failure in that dedicated channel prevents audio diagnostics
                // from overwriting sleep, Helper, or Agent notices.
                completedRoute = nil
            }

            let remainingProgress = self.audioInputSwitchGate.remainingProgressDuration(
                for: token,
                at: ProcessInfo.processInfo.systemUptime
            )
            if remainingProgress > 0 {
                let nanoseconds = UInt64(remainingProgress * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            self.finishAudioInputSwitch(token: token, completedRoute: completedRoute)
        }
    }

    private func finishAudioInputSwitch(
        token: AudioInputSwitchRequestGate.Token,
        completedRoute _: AudioInputSwitchRoute?
    ) {
        guard audioInputSwitchGate.finish(token) else { return }
        let remainingCooldown = audioInputSwitchGate.remainingSuppressionDuration(
            at: ProcessInfo.processInfo.systemUptime
        )

        audioInputSwitchTask = nil
        isAudioInputSwitchCoolingDown = remainingCooldown > 0
        audioInputSwitchRequestActive = false
        publishAudioInputSwitchingState()
        refreshCurrentAudioInputDisplayName()

        guard remainingCooldown > 0 else {
            audioInputCooldownGeneration = nil
            return
        }

        audioInputCooldownGeneration = token.generation
        audioInputCooldownTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(remainingCooldown * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self,
                  self.audioInputCooldownGeneration == token.generation else { return }
            self.audioInputCooldownGeneration = nil
            self.audioInputCooldownTask = nil
            self.isAudioInputSwitchCoolingDown = false
        }
    }

    private func publishAudioInputSwitchingState() {
        let switching = audioInputSwitchRequestActive || audioInputControllerIsSwitching
        guard isSwitchingAudioInput != switching else { return }
        isSwitchingAudioInput = switching
    }

    private func refreshCurrentAudioInputDisplayName() {
        // Freeze the source name for the complete request. Core Audio can publish
        // the new default and device-list changes in separate callbacks; exposing
        // those intermediate snapshots makes the current-name row visibly flash.
        guard !audioInputSwitchRequestActive else { return }

        guard let currentAudioInputUID else {
            stableCurrentAudioInputDisplayName = nil
            return
        }
        if let live = availableAudioInputs.first(where: {
            $0.uid == currentAudioInputUID
        }) {
            stableCurrentAudioInputDisplayName = live.displayName
            return
        }
        if let primary = audioInputConfiguration.primary,
           primary.uid == currentAudioInputUID {
            stableCurrentAudioInputDisplayName = audioInputController
                .choice(for: primary)
                .displayName
            return
        }
        if let secondary = audioInputConfiguration.secondary,
           secondary.uid == currentAudioInputUID {
            stableCurrentAudioInputDisplayName = audioInputController
                .choice(for: secondary)
                .displayName
            return
        }
        stableCurrentAudioInputDisplayName = nil
    }

    private var currentAudioInputSwitchRoute: AudioInputSwitchRoute? {
        AudioInputSwitchRouter.route(
            configuration: audioInputConfiguration,
            currentUID: currentAudioInputUID,
            availableUIDs: Set(
                availableAudioInputs.lazy.filter(\.isAvailable).map(\.uid)
            )
        )
    }

    private func refreshAudioInputLastKnownNames() {
        var configuration = audioInputConfiguration
        var changed = false

        func refreshed(_ selection: AudioInputSelection?) -> AudioInputSelection? {
            guard var selection,
                  let live = availableAudioInputs.first(where: {
                      $0.uid == selection.uid && $0.isAvailable
                  }) else { return selection }
            if selection.lastKnownName != live.displayName {
                selection.lastKnownName = live.displayName
                changed = true
            }
            return selection
        }

        configuration.primary = refreshed(configuration.primary)
        configuration.secondary = refreshed(configuration.secondary)
        guard changed else { return }
        configuration = configuration.sanitized()
        audioInputConfiguration = configuration
        store.saveAudioInputSwitchConfiguration(configuration)
    }

    func updateSettings(_ new: SafetySettings) {
        // Charging/safety policy changes invalidate the context in which a
        // completion release was authorized, even if the resulting veto/source
        // happens to be unchanged after reconciliation.
        conditionalSleepRelease.cancel()
        let wasAuto = settings.autoEnableWhenCharging
        if new.autoEnableWhenCharging, !wasAuto { resetSystemWakeFailure() }
        settings = new
        store.save(new)
        if !new.autoEnableWhenCharging {
            wakeArbiter.setIntent(.charging, active: false)
        }
        if new.autoEnableWhenCharging {
            if !wasAuto {
                // Opting into auto mode *is* the request to have keep-awake on, so
                // arm it rather than inheriting the current live state — otherwise
                // switching on "Automatically enable when charging" while
                // keep-awake happens to be off (the very case this feature exists
                // for) would visibly do nothing. Also drop any manual auto-off
                // countdown, which would just fight auto mode's own activation.
                armed = true
                store.saveArmed(armed)
                // Charging automation becomes the sole non-Agent owner. A
                // hidden manual request from the previous mode must not keep
                // the Mac awake after power is disconnected or auto is disarmed.
                manualWakeRequested = false
                wakeArbiter.clearManualIntents()
                cancelAutoOff(reconcileWake: false)
            }
            reconcileNow()
        } else if let pending = autoWrite.inFlightTarget {
            // Leaving auto mode with a write still travelling. Its target is where
            // the system is heading, so that's what manual mode inherits — but the
            // transition has to own that outcome with a write of its own, or the
            // auto reply lands afterwards and moves the state in a mode the user
            // has already left.
            //
            // Quiet origin deliberately: the user toggled a mode, not the switch,
            // so a modal about keep-awake would be about a write they never asked
            // for. It also can't be `.user` for a second reason — that origin
            // clears `externalNotice`, which this isn't entitled to do.
            //
            // The reply to this write runs `updateAutoOff`, and auto mode is off
            // in `settings` by now, so the countdown arms exactly as manual mode
            // expects.
            refreshBattery()
            let conditions = SafetySnapshot(battery: currentBattery,
                                            thermalSerious: thermalSerious())
            let settled = AutoEnablePolicy.handoffToManual(pendingTarget: pending,
                                                           conditions: conditions,
                                                           settings: settings)
            autoWrite.clear()
            // Same snapshot to decide and to write: whichever way `settled` went,
            // the check on the way out is guaranteed to permit it, so this write
            // always claims a mutation and always supersedes the auto reply.
            setEnabled(settled, note: nil, origin: .auto, conditions: conditions)
        } else {
            // Leaving auto mode hands activation back to the user, so the auto-off
            // countdown becomes applicable again — re-arm it if one is configured
            // and keep-awake is currently on.
            if wasAuto, isEnabled { armAutoOff() }
            evaluateSafety()
            applyWakeDecision(origin: .auto)
        }
    }

    func updateAISettings(_ new: AIAutomationSettings) {
        // Every automation-policy change revokes an unsubmitted completion
        // release. A changed input-wait delay is recalculated by the state
        // machine from the original wait boundary before a fresh decision.
        conditionalSleepRelease.cancel()
        if new.isEnabled, !aiSettings.isEnabled { resetSystemWakeFailure() }
        aiSettings = new
        store.saveAIAutomationSettings(new)
        agentMachine.updatePolicy(
            maximumTurnDuration: new.maximumDuration,
            completionConfirmation: AIAutomationSettings.completionConfirmation,
            waitingGrace: new.waitingReleaseDelay
        )
        reconcileAgentWake(now: Date())
    }

    /// The main toggle was flipped. In auto mode it sets the armed intent (and
    /// lets `reconcile()` gate the live state); in manual mode it directly turns
    /// keep-awake on/off, surfacing any failure/refusal as an alert.
    func setMasterToggle(_ on: Bool) {
        if on { resetSystemWakeFailure() }
        if settings.autoEnableWhenCharging {
            setArmed(on)
        } else if on, autoOffMinutes > 0 {
            // Repeating the main switch after a timed hold elapsed should honor
            // the duration still shown directly beneath it. The timer itself is
            // the source; keeping a hidden unlimited manual source as well would
            // prevent expiry from ever restoring sleep.
            manualWakeRequested = false
            wakeArbiter.setIntent(.manual, active: false)
            armAutoOff()
        } else {
            // Turning the primary switch off is an explicit release of both
            // manual variants, including a countdown that is still running.
            cancelAutoOff(reconcileWake: false)
            manualWakeRequested = on
            wakeArbiter.setIntent(.manual, active: on)
            applyWakeDecision(origin: .user)
        }
    }

    /// Set the auto-mode armed intent, persist it, and reconcile the live state.
    private func setArmed(_ on: Bool) {
        if on { resetSystemWakeFailure() }
        armed = on
        store.saveArmed(on)
        reconcileNow()
    }

    /// Auto mode: derive the live keep-awake state from `armed` gated by external
    /// power + safety, flipping only the live state (never the `armed` intent).
    /// When conditions aren't met the feature stays armed and the popover's
    /// warning explains why it isn't currently active.
    ///
    /// The poll's entry point. No-ops when auto mode is off, when the effective
    /// state already matches, or while an earlier write is still outstanding or
    /// has already concluded this turn — see `autoWrite`. `origin: .auto` because
    /// this fires unprompted on the timer and must stay silent.
    func reconcile() { reconcile(userDriven: false) }

    /// Reconcile now on behalf of something the user just did — arming, changing
    /// settings — where waiting for the next tick would read as the control doing
    /// nothing.
    ///
    /// Unlike the poll, this may write over a request still in flight, because
    /// the user has since said something newer. It does *not* simply drop the
    /// claim: dropping it loses the pending target, and the decision is then
    /// taken against a state the system has already left. Disarming while an
    /// "on" write is travelling would compare `false` against a still-`false`
    /// `isEnabled`, conclude there was nothing to do, and leave the earlier write
    /// to land unopposed — turning keep-awake on moments after the user turned it
    /// off. Deciding against the effective state instead yields a corrective
    /// write, which supersedes the old reply and, because the helper serialises,
    /// lands last.
    private func reconcileNow() { reconcile(userDriven: true) }

    /// Derive the live keep-awake state from `armed` gated by external power +
    /// safety, flipping only the live state (never the `armed` intent). When
    /// conditions aren't met the feature stays armed and the popover's warning
    /// explains why it isn't currently active.
    ///
    /// Refreshes the battery cache first so the decision and the warning list the
    /// popover renders from it are read off the same sample.
    private func reconcile(userDriven: Bool) {
        guard settings.autoEnableWhenCharging else {
            wakeArbiter.setIntent(.charging, active: false)
            applyWakeDecision(origin: .auto)
            return
        }
        refreshBattery()
        let conditions = SafetySnapshot(battery: currentBattery,
                                        thermalSerious: thermalSerious())
        let active = helperInstalled && armed && AutoEnablePolicy.canActivate(
            battery: conditions.battery,
            thermalSerious: conditions.thermalSerious,
            settings: settings
        )
        wakeArbiter.setIntent(.charging, active: active)
        updateSafetyVetoes(hasAgentWork: !agentMachine.activeSessions(at: Date()).isEmpty)
        applyWakeDecision(origin: .auto)
    }

    /// The claim on auto mode's outstanding write. Held across the helper's async
    /// round trip, so a reply that reads back wrong can't immediately provoke
    /// another write. See `AutoWriteCoordinator`.
    private var autoWrite = AutoWriteCoordinator()

    /// The last-sampled battery state, refreshed by `refreshBattery()`. Shared by
    /// `reconcile()` and `autoWarningReasons` so the two can't disagree.
    private var currentBattery: BatteryInfo {
        BatteryInfo(percent: batteryPercent, onAC: batteryOnAC)
    }

    /// "Keep awake for N minutes" — the whole gesture, in one call.
    ///
    /// Turns keep-awake on when it isn't already, because that is plainly what
    /// asking for fifteen minutes of it means. Making someone flip the switch
    /// first and *then* set a duration is making them do the bookkeeping.
    ///
    /// Note the ordering when it has to enable: the duration is persisted first,
    /// then the write goes out, and the countdown is armed from the write's
    /// confirmation (via `updateAutoOff(for:)`). So if the safety policy refuses
    /// — flat battery, running hot — no timer is left counting down for a state
    /// the Mac never entered.
    func keepAwakeFor(minutes: Int) {
        if minutes > 0 { resetSystemWakeFailure() }
        let request = AutoOff.request(minutes: minutes,
                                      isEnabled: isEnabled,
                                      autoModeOn: settings.autoEnableWhenCharging)
        guard request != .ignoredInAutoMode else { return }
        autoOffMinutes = minutes
        store.saveAutoOffMinutes(minutes)
        switch request {
        case .ignoredInAutoMode:
            break
        case .cancelTimer:
            cancelAutoOff(reconcileWake: false)
            manualWakeRequested = true
            wakeArbiter.setIntent(.manual, active: true)
            applyWakeDecision(origin: .user)
        case .armTimer:
            manualWakeRequested = false
            wakeArbiter.setIntent(.manual, active: false)
            armAutoOff()
        case .enableThenArmTimer:
            manualWakeRequested = false
            wakeArbiter.setIntent(.manual, active: false)
            armAutoOff()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if let err = loginItem.setEnabled(enabled) {
            setPresentationError(.loginItemUpdateFailed, diagnostic: err)
            launchAtLogin = loginItem.isEnabled
        } else {
            // status can lag right after register/unregister; trust the action.
            launchAtLogin = enabled
        }
    }

    // MARK: AI agent integration

    var codexDesktopObserved: Bool { integrationObservations.codexDesktop }
    var codexCLIObserved: Bool { integrationObservations.codexCLI }
    var claudeCodeObserved: Bool { integrationObservations.claudeCode }
    var allAgentSurfacesObserved: Bool {
        codexDesktopObserved && codexCLIObserved && claudeCodeObserved
    }

    func refreshIntegrationHealth() {
        let installer = HookIntegrationInstaller()
        let codexHealth = installer.codexHealth()
        let health = [codexHealth.integration] + HookProvider.allCases
            .filter { $0 != .codex }
            .map { installer.health(for: $0) }
        let configurationHealthy = health.allSatisfy { $0.state == .installed }
        codexLifecycleChannelHealth = CodexLifecycleChannelHealth.evaluate(
            integration: codexHealth,
            eventServerAvailable: eventServerAvailable
        )
        // Preserve the existing meaning for Settings/diagnostics: fully healthy
        // includes the canonical completion relay, even when activity events are
        // independently usable during a third-party notify reorder.
        codexIntegrationHealthy = codexLifecycleChannelHealth.idleEvidenceHealthy
        integrationHealthy = configurationHealthy && eventServerAvailable
        integrationInstalled = health.contains { $0.state != .notInstalled }

        if configurationHealthy, !eventServerAvailable {
            integrationSummary = "Event bridge unavailable"
        } else if integrationHealthy {
            integrationSummary = "Codex hooks + completion relay + Claude hooks installed"
        } else if health.contains(where: { $0.state == .invalidConfiguration || $0.state == .conflict }) {
            integrationSummary = "Configuration needs manual repair"
        } else if health.contains(where: { $0.state == .bridgeMissing || $0.state == .needsRepair }) {
            integrationSummary = "Needs repair"
        } else if integrationInstalled {
            integrationSummary = "Partially installed"
        } else {
            integrationSummary = "Not installed"
        }
    }

    func installAgentIntegrations() {
        do {
            let installer = HookIntegrationInstaller()
            for provider in HookProvider.allCases { _ = try installer.install(provider) }
            refreshIntegrationHealth()
            lastError = "AI integrations installed. Restart Codex after this task so it loads the completion relay, then run one real turn in each supported surface."
        } catch {
            refreshIntegrationHealth()
            if error is HookIntegrationError {
                lastError = error.localizedDescription
            } else {
                setPresentationError(
                    .integrationInstallFailed,
                    diagnostic: error.localizedDescription
                )
            }
        }
    }

    func removeAgentIntegrations() {
        do {
            let installer = HookIntegrationInstaller()
            for provider in HookProvider.allCases { _ = try installer.uninstall(provider) }
            integrationObservations = AgentIntegrationObservations(
                bridgeSchemaVersion: HookBridgePayload.currentSchemaVersion
            )
            store.clearAgentIntegrationObservations()
            refreshIntegrationHealth()
            lastError = "CodeWake hooks and completion relay were removed; unrelated hooks and the prior notification command were preserved."
        } catch {
            refreshIntegrationHealth()
            if error is HookIntegrationError {
                lastError = error.localizedDescription
            } else {
                setPresentationError(
                    .integrationRemoveFailed,
                    diagnostic: error.localizedDescription
                )
            }
        }
    }

    // MARK: Built-in display blackout

    /// Shut off all online displays using macOS while retaining the existing
    /// Helper lease, manual/timed sources, and semantic Agent work unchanged.
    func turnOffAllDisplays() {
        guard canTurnOffAllDisplays else { return }
        MenuBarExtraPanel.dismiss()
        allDisplaysSleepController.request(prepare: { [weak self] completion in
            guard let self,
                  !self.isRestoringNormalSleep,
                  !self.isQuitting else {
                completion(.blocked(.recoveryUnavailable))
                return
            }
            self.displayBlackoutSupervisor.prepareForAllDisplaysSleep(completion: completion)
        }, revalidate: { [weak self] in
            guard let self, !self.isRestoringNormalSleep, !self.isQuitting else {
                return .blocked(.recoveryUnavailable)
            }
            return self.displayBlackoutSupervisor.revalidateAllDisplaysSleepPreparation()
        })
    }

    /// A manual, one-shot action. It never creates or refreshes a wake source;
    /// the existing Helper lease and a fresh SleepDisabled=1 read are mandatory.
    func toggleBuiltInDisplayBlackout() {
        if builtInDisplayBlackoutActive {
            displayBlackoutSupervisor.restore()
            return
        }
        guard !builtInDisplayBlackoutBusy,
              !builtInDisplayBlackoutRecoveryPending,
              !allDisplaysSleepSnapshot.suspendsDisplayAwake,
              !isRestoringNormalSleep,
              !isQuitting else { return }

        let topology = displayTopology.currentState()
        guard topology == .disconnected else {
            handleDisplayTopologyChange(topology)
            return
        }
        guard helperLeaseActive,
              pendingVerification == nil,
              !systemWakeUnavailable,
              power.isSleepDisabled() == true else {
            builtInDisplayBlackoutWarningCanonical = nil
            refreshState()
            return
        }
        guard case .ready = displayBlackoutSupervisor.refreshCapability() else {
            return
        }

        builtInDisplayBlackoutWarningCanonical = nil
        // SwiftUI Button actions run on mouseUp. Starting on the next main-loop
        // turn prevents that initiating click from becoming the watchdog's first
        // post-arm HID event. The watchdog then samples its own precise baseline.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.isRestoringNormalSleep,
                  !self.isQuitting,
                  !self.allDisplaysSleepSnapshot.suspendsDisplayAwake,
                  self.helperLeaseActive,
                  self.pendingVerification == nil,
                  !self.systemWakeUnavailable,
                  self.power.isSleepDisabled() == true else { return }
            let currentTopology = self.displayTopology.currentState()
            guard currentTopology == .disconnected,
                  case .ready = self.displayBlackoutSupervisor.refreshCapability() else {
                self.handleDisplayTopologyChange(currentTopology)
                return
            }
            self.displayBlackoutSupervisor.arm()
        }
    }

    private func applyDisplayBlackoutSnapshot(
        _ snapshot: DisplayBlackoutSupervisor.Snapshot
    ) {
        builtInDisplayBlackoutActive = snapshot.blackoutActive
        builtInDisplayBlackoutBusy = snapshot.busy
        builtInDisplayBlackoutRecoveryPending = snapshot.recoveryPending
        builtInDisplayRecoveryStatus = snapshot.recoveryStatus
        builtInDisplayRecoveryFailure = snapshot.recoveryFailure
        builtInDisplayBlackoutCapability = snapshot.capability

        if let failure = snapshot.recoveryFailure {
            builtInDisplayBlackoutWarningCanonical = failure.message
            return
        }
        if let failureCode = snapshot.failureCode, !failureCode.isEmpty {
            builtInDisplayBlackoutWarningCanonical =
                "Built-in display brightness control is unavailable."
            return
        }
        switch snapshot.lastStatus {
        case .failed, .protocolMismatch, .invalidRequest, .staleGeneration:
            builtInDisplayBlackoutWarningCanonical =
                "Built-in display brightness control is unavailable."
        case .ready, .armed, .restored, .noRecoveryNeeded,
             .externalDisplayConnected, .topologyUnknown,
             .builtInUnavailable, .brightnessUnavailable, nil:
            builtInDisplayBlackoutWarningCanonical = nil
        }
    }

    private func handleDisplayTopologyChange(_ state: ExternalDisplayState) {
        externalDisplayState = state
        builtInDisplayBlackoutCapability =
            displayBlackoutSupervisor.refreshCapability()

        // A screen-parameter notification is also a recovery retry boundary
        // when the external-display summary is unchanged (for example: the
        // built-in panel comes online while the same external display remains).
        // The supervisor coalesces retries while a child/fallback is active.
        if builtInDisplayBlackoutRecoveryPending {
            displayBlackoutSupervisor.retryPendingRecovery()
        }

        switch state {
        case .connected:
            // A positively identified external endpoint ends the operation. The
            // watchdog independently performs the same check, covering the
            // notification-to-write race.
            if builtInDisplayBlackoutActive || builtInDisplayBlackoutBusy {
                displayBlackoutSupervisor.restore()
            }
        case .unknown:
            // Closing the lid can temporarily remove the built-in panel from the
            // online list. Unknown blocks a new arm but is not proof that an
            // external display appeared; HID input remains the restore trigger.
            break
        case .disconnected:
            break
        }
    }

    // MARK: Emergency restore + orderly quit

    /// Clear every current Lidless wake request and restore the normal macOS
    /// sleep policy. This deliberately does not request immediate system sleep.
    func restoreNormalSleep() {
        beginNormalSleepRestore(terminateWhenFinished: false)
    }

    /// The menu's explicit Quit is an orderly transaction: tombstone current
    /// Agent turns first, then wait briefly for the helper to restore its owned
    /// SleepDisabled transition before terminating the process.
    func quitAndRestoreSleep() {
        NSApplication.shared.terminate(nil)
    }

    /// Called by `LidlessAppDelegate.applicationShouldTerminate`. Returning
    /// `.terminateLater` is the only normal AppKit exit path that can actually
    /// wait for the helper transaction; `willTerminate` is already too late.
    func prepareForApplicationTermination(completion: @escaping () -> Void) {
        terminationReadyHandler = completion
        beginNormalSleepRestore(terminateWhenFinished: true)
    }

    private func beginNormalSleepRestore(terminateWhenFinished: Bool) {
        if isRestoringNormalSleep {
            if terminateWhenFinished {
                isQuitting = true
                intentionalQuitPrepared = true
                terminateAfterNormalSleepRestore = true
                scheduleNormalSleepRestoreQuitTimeout(
                    generation: normalSleepRestoreGeneration
                )
            }
            return
        }

        let now = Date()
        let hadKnownLease = helperLeaseActive
        normalSleepRestoreGeneration += 1
        let generation = normalSleepRestoreGeneration
        terminateAfterNormalSleepRestore = terminateWhenFinished
        intentionalQuitPrepared = terminateWhenFinished
        isRestoringNormalSleep = true
        isQuitting = terminateWhenFinished
        allDisplaysSleepController.cancel()
        normalSleepRestoreStatus = nil

        // Quit must never hang on a stale XPC registration. Local tombstones
        // are already durable, and the helper watchdog remains the fallback if
        // this bounded release cannot receive a reply.
        if terminateWhenFinished {
            scheduleNormalSleepRestoreQuitTimeout(generation: generation)
        }

        // Brightness recovery has its own durable journal and bounded fallback.
        // Reach the Helper release only after that transaction has restored the
        // panel or confirmed that recovery must remain pending until it is online.
        displayBlackoutSupervisor.restore { [weak self] _ in
            guard let self,
                  self.normalSleepRestoreGeneration == generation,
                  self.isRestoringNormalSleep else { return }
            self.continueNormalSleepRestore(
                generation: generation,
                now: now,
                hadKnownLease: hadKnownLease
            )
        }
    }

    private func continueNormalSleepRestore(
        generation: Int,
        now: Date,
        hadKnownLease: Bool
    ) {
        guard normalSleepRestoreGeneration == generation,
              isRestoringNormalSleep else { return }
        prepareLocalNormalSleepRestore(at: now)

        guard helperInstalled || helperLeaseActive else {
            let observed = power.isSleepDisabled()
            finishNormalSleepRestore(
                generation: generation,
                status: observed == false ? .alreadyNormal : .failed,
                diagnostic: observed == false
                    ? nil : "No approved helper was available to release SleepDisabled."
            )
            return
        }

        helper.releaseLeaseForPolicyRestore(id: aggregateLeaseID) { [weak self] result in
            guard let self,
                  self.normalSleepRestoreGeneration == generation,
                  self.isRestoringNormalSleep else { return }
            switch result {
            case .cancelled:
                self.finishNormalSleepRestore(
                    generation: generation,
                    status: .failed,
                    diagnostic: "The policy-only helper release was cancelled."
                )
            case .failed(let error):
                self.finishNormalSleepRestore(
                    generation: generation,
                    status: .failed,
                    diagnostic: error
                )
            case .completed(let outcome, let warning):
                guard outcome.leaseReleased else {
                    self.finishNormalSleepRestore(
                        generation: generation,
                        status: .failed,
                        diagnostic: warning ?? outcome.disposition.rawValue
                    )
                    return
                }
                let observed = self.power.isSleepDisabled()
                let status: NormalSleepRestoreStatus
                if outcome.disposition == .preexistingWakeSetting || observed == true {
                    status = .anotherWakeSettingRemains
                } else if observed == false {
                    status = !hadKnownLease || outcome.disposition == .noLease
                        ? .alreadyNormal : .restored
                } else {
                    status = .failed
                }
                self.finishNormalSleepRestore(
                    generation: generation,
                    status: status,
                    diagnostic: status == .failed
                        ? (warning ?? "SleepDisabled could not be read back after release.")
                        : warning
                )
            }
        }
    }

    private func scheduleNormalSleepRestoreQuitTimeout(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self,
                  self.isRestoringNormalSleep,
                  self.terminateAfterNormalSleepRestore,
                  self.normalSleepRestoreGeneration == generation else { return }
            self.finishNormalSleepRestore(
                generation: generation,
                status: .failed,
                diagnostic: "Timed out waiting for the background helper during Quit."
            )
        }
    }

    private func prepareLocalNormalSleepRestore(at now: Date) {
        conditionalSleepRelease.cancel()
        stopDisplayAwakeAssertion()
        // Supersede every acquire/release/read reply issued before the user chose
        // emergency restore. The dedicated restore generation remains the sole
        // authority until this transaction finishes.
        sync.beginMutation()
        helperHealthGeneration += 1
        recoveryLeaseInspectionInFlight = false
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        autoWrite.clear()
        pendingVerification = nil
        verificationNotice = nil

        manualWakeRequested = false
        cancelAutoOff(reconcileWake: false)
        armed = false
        store.saveArmed(false)
        wakeArbiter.clearAllIntents()
        knownAgentSources.removeAll()
        knownActiveAgentTurns.removeAll()
        agentProcessAssociations = AgentProcessAssociationTracker()
        agentProcessScanGate.invalidate()
        latestScannedCodexProcessIdentities = nil
        codexLifecycleObservedProcessIdentities.removeAll()
        pendingAgentRecovery = nil
        agentMachine.manuallyEndCurrentTurns(at: now)
        store.saveAgentRecoverySnapshot(agentMachine.recoverySnapshot(at: now))

        aggregateWakeRequested = false
        consumedCompletionBlockers.removeAll()
        consumedCompletionReleasePending = false
        conditionalReleaseLabel = "FINISHED"
        agentCompletionNotice = nil
        codexCancellationNotice = nil
        wakeSourceSummary = ""
        resetSystemWakeFailure()
        updateAgentPresentation(now: now, hasAgentWork: false, powerAllowed: true)
    }

    private func finishNormalSleepRestore(
        generation: Int,
        status: NormalSleepRestoreStatus,
        diagnostic: String?
    ) {
        guard normalSleepRestoreGeneration == generation else { return }
        normalSleepRestoreGeneration += 1
        let shouldTerminate = terminateAfterNormalSleepRestore
        helperLeaseActive = false
        helperLeaseDeadline = .distantPast
        aggregateWakeRequested = false
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        normalSleepRestoreStatus = status
        if let diagnostic, !diagnostic.isEmpty {
            lastDiagnosticError = diagnostic
        }
        hasConfirmedState = false
        // Keep the mutation gate raised while adopting the read-back. Otherwise
        // a prompt received during release can reacquire between the helper reply
        // and an orderly Quit's `reply(toApplicationShouldTerminate:)`.
        refreshState()

        guard shouldTerminate else {
            isRestoringNormalSleep = false
            isQuitting = false
            // A genuinely new prompt submitted while the emergency release was
            // in flight was intentionally deferred. It may reacquire only now.
            reconcileAgentWake(now: Date())
            return
        }
        terminateAfterNormalSleepRestore = false
        // Keep the gate raised through AppKit's terminate-later reply. A socket
        // event already queued on the main run loop must not reacquire a lease in
        // the tiny interval before `willTerminate` and process exit.
        let shouldRelaunch = relaunchAfterTermination
        relaunchAfterTermination = false
        if shouldRelaunch {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL,
                configuration: config
            ) { _, _ in }
        }
        let ready = terminationReadyHandler
        terminationReadyHandler = nil
        ready?()
    }

    private func startAgentEventServer() {
        do {
            try agentEventServer.start(onEventWithProcess: { [weak self] data, process in
                Task { @MainActor in self?.receiveAgentEvent(data, process: process) }
            })
            eventServerAvailable = true
        } catch {
            eventServerAvailable = false
            integrationSummary = "Event bridge unavailable"
            integrationHealthy = false
            codexIntegrationHealthy = false
            codexLifecycleChannelHealth = .unavailable
            setPresentationError(
                .eventBridgeStartFailed,
                diagnostic: error.localizedDescription
            )
        }
    }

    private func receiveAgentEvent(_ data: Data, process: AgentProcessSnapshot? = nil) {
        // Decode only the privacy-minimized bridge type, then construct the
        // richer internal event ourselves. In particular, socket clients cannot
        // inject `confirmed=true` or the process-exit fallback; those remain
        // reserved for the local libproc monitor. Legacy schema v1/v2 stays
        // accepted while an upgraded app is waiting for hook repair; the state
        // machine gives its Stop a conservative waiting release that is never
        // sleep-eligible. Unknown schemas remain rejected.
        let receivedAt = Date()
        guard let payload = HookBridgePayload.decodeSupported(from: data) else {
            recordAgentEventDiagnostic(
                eventType: "unrecognized",
                receivedAt: receivedAt,
                rejectionCode: "decode_or_schema"
            )
            return
        }
        guard let provider = AgentProvider(rawValue: payload.provider),
              provider != .cursor else {
            recordAgentEventDiagnostic(
                eventType: payload.eventKind.rawValue,
                receivedAt: receivedAt,
                rejectionCode: "unsupported_provider"
            )
            return
        }
        guard let eventKind = AgentEventKind(rawValue: payload.eventKind.rawValue) else {
            recordAgentEventDiagnostic(
                eventType: payload.eventKind.rawValue,
                receivedAt: receivedAt,
                rejectionCode: "unsupported_event"
            )
            return
        }
        let event = AgentEvent(
            schemaVersion: payload.schemaVersion,
            provider: provider,
            sessionID: payload.sessionID,
            turnID: payload.turnID,
            eventKind: eventKind,
            waitingReason: payload.waitingReason.flatMap {
                AgentWaitingReason(rawValue: $0.rawValue)
            },
            backgroundWork: payload.backgroundWork,
            backgroundWorkCount: payload.backgroundWorkCount,
            workToken: payload.workToken,
            stopHookActive: payload.stopHookActive,
            timestamp: Date(timeIntervalSince1970: payload.timestamp)
        )
        let now = receivedAt
        // Hooks are immediate notifications. Reject replayed or far-future
        // events so a malformed local client cannot manufacture a long lease.
        guard event.timestamp >= now.addingTimeInterval(-24 * 60 * 60) else {
            recordAgentEventDiagnostic(
                eventType: eventKind.rawValue,
                receivedAt: receivedAt,
                rejectionCode: "timestamp_too_old"
            )
            return
        }
        guard event.timestamp <= now.addingTimeInterval(5 * 60) else {
            recordAgentEventDiagnostic(
                eventType: eventKind.rawValue,
                receivedAt: receivedAt,
                rejectionCode: "timestamp_in_future"
            )
            return
        }
        // Configuration repair may temporarily run a legacy bridge. It can preserve
        // lifecycle wake protection, but only a real v3 event verifies the
        // current installed integration in Settings.
        if payload.schemaVersion == HookBridgePayload.currentSchemaVersion {
            recordObservedIntegration(provider: provider, process: process)
        }
        let key = AgentSessionKey(provider: provider, sessionID: payload.sessionID)
        if eventKind == .sessionEnded {
            agentProcessAssociations.remove(session: key)
        } else if let process, processProvider(process) == provider {
            agentProcessAssociations.associate(process.identity, with: key)
            lastProcessSnapshots[process.identity] = process
        }
        activatePendingAgentRecovery(for: event, at: now)
        let ingestDisposition = agentMachine.ingest(event)
        if payload.schemaVersion == HookBridgePayload.currentSchemaVersion,
           provider == .codex,
           ingestDisposition == .accepted {
            recordCodexLifecycleProcess(process)
        }
        recordAgentEventDiagnostic(
            eventType: eventKind.rawValue,
            receivedAt: receivedAt,
            rejectionCode: ingestDisposition == .accepted
                ? "none" : ingestDisposition.rawValue
        )
        if ingestDisposition == .accepted,
           (eventKind == .promptSubmitted
                || eventKind == .toolStarted
                || eventKind == .inputReceived) {
            resetSystemWakeFailure()
            agentCompletionNotice = nil
            codexCancellationNotice = nil
            consumedCompletionBlockers.removeAll()
            consumedCompletionLabel = "FINISHED"
            consumedCompletionReleasePending = false
            conditionalReleaseLabel = "FINISHED"
        }
        if ingestDisposition == .accepted,
           eventKind == .turnFailed,
           !agentMachine.activeSessions(at: now).contains(key) {
            // Failure is user-visible even when no agent wake source could ever
            // be established (helper missing, automation disabled, or battery
            // policy). Checking the post-ingest state prevents an older rejected
            // failure event from overwriting a newer continuation's status.
            agentCompletionNotice = "FAILED · system sleep restored"
        }
        reconcileAgentWake(now: now)
    }

    private func recordAgentEventDiagnostic(
        eventType: String,
        receivedAt: Date,
        rejectionCode: String
    ) {
        agentLastEventType = eventType
        agentLastEventReceivedAt = receivedAt
        agentLastEventRejectionCode = rejectionCode
    }

    /// The socket is already bound when this runs, so hook clients can connect,
    /// but the main actor has not yet returned from init and cannot process a
    /// queued event ahead of this bounded recovery gate.
    private func reconcileCodexCancellationsAtLaunch(at now: Date) {
        let activeTurns = codexCancellationObservedTurns(at: now)
        guard !activeTurns.isEmpty else { return }
        let records = codexCancellationObserver.reconcile(activeTurns: activeTurns)
        applyCodexCancellationRecords(records, receivedAt: now, reconcileWake: false)
    }

    /// Captures value-only lifecycle identities on the main actor. The observer
    /// receives this immutable snapshot on a background queue and never reads
    /// AppState or the state machine directly.
    private func codexCancellationObservedTurns(
        at now: Date
    ) -> [CodexCancellationObservedTurn] {
        var states = agentMachine.allTurns(at: now)
        if let pendingAgentRecovery {
            states.append(contentsOf: pendingAgentRecovery.sessions)
        }
        return states.compactMap { state in
            guard state.key.provider == .codex,
                  state.isWakeEligible(at: now),
                  let turnID = state.turnID else { return nil }
            return CodexCancellationObservedTurn(
                sessionID: state.key.sessionID,
                turnID: turnID,
                startedAt: state.turnStartedAt,
                lastEventAt: state.lastEventAt
            )
        }
    }

    /// Applies every exact terminal returned by the observer. Results are never
    /// discarded because a newer scan began: the observer deduplicates before
    /// returning, and an old-turn tombstone is harmless to a newer turn. Whether
    /// the turn is still tracked controls user-visible effects and lease work.
    private func applyCodexCancellationRecords(
        _ records: [CodexCancellationRecord],
        receivedAt: Date,
        reconcileWake: Bool = true
    ) {
        guard !records.isEmpty else { return }
        var appliedTrackedCancellation = false

        for record in records {
            let turnKey = AgentTurnKey(
                provider: .codex,
                sessionID: record.sessionID,
                turnID: record.turnID
            )
            let hadLiveState = agentMachine.state(for: turnKey, at: receivedAt) != nil
            let removedPendingState = removePendingAgentRecovery(turnKey: turnKey)
            let wasTracked = hadLiveState || removedPendingState

            // A successful completion may already be inside the short helper
            // version-probe window. An authoritative interrupt synchronously
            // revokes that token before any state or lease reconciliation.
            if wasTracked { conditionalSleepRelease.cancel() }

            let disposition = agentMachine.ingest(AgentEvent(
                provider: .codex,
                sessionID: record.sessionID,
                turnID: record.turnID,
                eventKind: .turnCancelled,
                timestamp: record.interruptedAt
            ))
            recordAgentEventDiagnostic(
                eventType: AgentEventKind.turnCancelled.rawValue,
                receivedAt: receivedAt,
                rejectionCode: disposition == .accepted
                    ? "none" : disposition.rawValue
            )
            if wasTracked && (disposition == .accepted || removedPendingState) {
                appliedTrackedCancellation = true
            }
        }

        guard appliedTrackedCancellation else { return }
        codexCancellationNotice = "Codex cancellation detected. The cancelled task is no longer counted as active. CodeWake does not request immediate sleep."

        if !hasTrackedAgentWorkIncludingPending(at: receivedAt), reconcileWake {
            prepareCodexCancellationPolicyReleaseNotice()
        }

        if reconcileWake {
            reconcileAgentWake(now: receivedAt)
        } else {
            persistAgentRecoveryIncludingPending(at: receivedAt)
            updateAgentPresentation(
                now: receivedAt,
                hasAgentWork: !agentMachine.activeSessions(at: receivedAt).isEmpty,
                powerAllowed: batteryOnAC || aiSettings.allowOnBattery
            )
        }
    }

    @discardableResult
    private func removePendingAgentRecovery(turnKey: AgentTurnKey) -> Bool {
        guard let recovery = pendingAgentRecovery else { return false }
        let remaining = recovery.sessions.filter { $0.turnKey != turnKey }
        guard remaining.count != recovery.sessions.count else { return false }
        pendingAgentRecovery = remaining.isEmpty
            ? nil
            : AgentStateRecoverySnapshot(
                sessions: remaining,
                tombstones: recovery.tombstones
            )
        return true
    }

    private func hasTrackedAgentWorkIncludingPending(at now: Date) -> Bool {
        if !agentMachine.activeTurns(at: now).isEmpty { return true }
        return pendingAgentRecovery?.sessions.contains {
            $0.isWakeEligible(at: now)
        } == true
    }

    private func persistAgentRecoveryIncludingPending(at now: Date) {
        let current = agentMachine.recoverySnapshot(at: now)
        guard let pendingAgentRecovery else {
            store.saveAgentRecoverySnapshot(current)
            return
        }
        store.saveAgentRecoverySnapshot(AgentStateRecoverySnapshot(
            sessions: current.sessions + pendingAgentRecovery.sessions,
            tombstones: current.tombstones + pendingAgentRecovery.tombstones
        ))
    }

    private func schedulePeriodicCodexCancellationScan() {
        guard !periodicCodexCancellationScanInFlight,
              !recoveryLeaseInspectionInFlight else { return }
        let activeTurns = codexCancellationObservedTurns(at: Date())
        guard !activeTurns.isEmpty else { return }

        periodicCodexCancellationScanInFlight = true
        let observer = codexCancellationObserver
        codexCancellationScanQueue.async { [weak self] in
            let records = observer.reconcile(activeTurns: activeTurns)
            DispatchQueue.main.async {
                guard let self else { return }
                self.periodicCodexCancellationScanInFlight = false
                self.applyCodexCancellationRecords(
                    records,
                    receivedAt: Date()
                )
            }
        }
    }

    /// User-facing refresh keeps product presence and lifecycle semantics
    /// separate. libproc runs off the main actor; only the resulting value types
    /// are applied back to the state machine and UI.
    func refreshCodexStatus() {
        guard !isRefreshingCodexStatus, !isRestoringNormalSleep else { return }
        isRefreshingCodexStatus = true
        let generation = agentProcessScanGate.begin()
        // The helper-recovery gate owns its own final cancellation scan before
        // merging pending state. Avoid a second observer call that could mark a
        // record delivered before that gated result reaches the main actor.
        let activeTurns = recoveryLeaseInspectionInFlight
            ? [] : codexCancellationObservedTurns(at: Date())
        let observer = codexCancellationObserver
        DispatchQueue.global(qos: .userInitiated).async {
            let cancellations = observer.reconcile(activeTurns: activeTurns)
            let scan = AgentProcessMonitor.scan()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let now = Date()
                // Exact cancellation evidence is never rejected by scan
                // generation. The observer already marked it delivered, and a
                // later turn is protected by its different turn ID.
                self.applyCodexCancellationRecords(
                    cancellations,
                    receivedAt: now
                )
                self.applyAgentProcessScanResult(
                    scan,
                    generation: generation,
                    now: now
                )
                if !self.eventServerAvailable {
                    self.startAgentEventServer()
                }
                self.refreshIntegrationHealth()
                self.updateCodexTaskSemanticStatus(now: now)
                self.refreshState()
                self.isRefreshingCodexStatus = false
            }
        }
    }

    private func refreshAgentProcesses() {
        // A user-requested refresh is the stronger freshness boundary. Let it
        // supersede any older periodic scan, and do not let the next timer tick
        // immediately make the manual result stale behind an already-stopped
        // progress indicator.
        guard !isRefreshingCodexStatus else { return }
        let generation = agentProcessScanGate.begin()
        DispatchQueue.global(qos: .utility).async {
            let scan = AgentProcessMonitor.scan()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applyAgentProcessScanResult(
                    scan,
                    generation: generation,
                    now: Date()
                )
            }
        }
    }

    private func applyAgentProcessScanResult(
        _ scan: AgentProcessScan?,
        generation: UInt64,
        now: Date
    ) {
        guard agentProcessScanGate.accepts(generation) else { return }
        guard let scan else {
            // Failed enumeration is unknown, never manufactured exit. Preserve
            // prior snapshots/associations, but revoke the evidence needed for a
            // definitive "No active task" presentation.
            codexProcessPresence = .scanFailed
            latestScannedCodexProcessIdentities = nil
            reconcileAgentWake(now: now)
            return
        }
        applyAgentProcessScan(scan, now: now)
    }

    private func applyAgentProcessScan(_ scan: AgentProcessScan, now: Date) {
        let snapshots = scan.snapshots
        let current = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.identity, $0) })
        var retained = current

        // A PID can disappear between enumeration and proc_pidinfo. If it was
        // still listed but unreadable, retain its last identity for one or more
        // polls instead of manufacturing a confirmed exit. A readable snapshot
        // with the same PID and a different start time proves PID reuse.
        for (identity, old) in lastProcessSnapshots where current[identity] == nil {
            let pidWasReused = scan.startTimesByPID[identity.pid].map {
                $0 != identity.startTimeMicroseconds
            } ?? false
            if scan.listedPIDs.contains(identity.pid), !pidWasReused {
                retained[identity] = old
            }
        }
        for snapshot in snapshots
            where lastProcessSnapshots[snapshot.identity] == nil
                && snapshot.executionSurface.supportsStandaloneDiscovery {
            guard let provider = processProvider(snapshot) else { continue }
            agentMachine.ingest(AgentEvent(
                provider: provider,
                sessionID: processSessionID(snapshot.identity),
                turnID: nil,
                eventKind: .processDiscovered,
                timestamp: now
            ))
        }

        // CPU deltas remain available in `AgentProcessSnapshot` for diagnostics,
        // but they are deliberately not lifecycle events. A shared Codex process
        // can execute several parent/subagent turns, so CPU growth must never
        // revive or refresh any one of them.

        for (identity, old) in lastProcessSnapshots where retained[identity] == nil {
            guard old.executionSurface.supportsStandaloneDiscovery else { continue }
            guard let provider = processProvider(old) else { continue }
            agentMachine.ingest(AgentEvent(
                provider: provider,
                sessionID: processSessionID(identity),
                turnID: nil,
                eventKind: .processExited,
                timestamp: now,
                confirmed: true
            ))
        }

        // Hook sessions use opaque IDs, so process exit is applied only when a
        // socket peer's ancestry tied that exact session to a CLI identity. Two
        // consecutive complete scans must miss every associated process.
        let endedHookSessions = agentProcessAssociations.observe(
            currentIdentities: Set(retained.keys)
        )
        for key in endedHookSessions {
            agentMachine.ingest(AgentEvent(
                provider: key.provider,
                sessionID: key.sessionID,
                turnID: agentMachine.state(for: key, at: now)?.turnID,
                eventKind: .processExited,
                timestamp: now,
                confirmed: true
            ))
        }

        // Never translate provider-wide absence into completion of an unbound
        // opaque hook session. SessionEnd and the hard limit remain its bounds.
        lastProcessSnapshots = retained
        let codexSnapshots = retained.values.filter {
            $0.executionSurface.provider == .codex
        }
        let codexIdentities = Set(codexSnapshots.map(\.identity))
        codexProcessPresence = CodexProcessPresence(snapshots: Array(codexSnapshots))
        latestScannedCodexProcessIdentities = codexIdentities
        codexLifecycleObservedProcessIdentities.formIntersection(codexIdentities)
        reconcileAgentWake(now: now)
    }

    private func processProvider(_ snapshot: AgentProcessSnapshot) -> AgentProvider? {
        switch snapshot.executionSurface.provider {
        case .codex: return .codex
        case .claude: return .claudeCode
        }
    }

    private func recordObservedIntegration(
        provider: AgentProvider,
        process: AgentProcessSnapshot?
    ) {
        var updated = integrationObservations
        switch provider {
        case .codex:
            switch process?.executionSurface {
            case .codexDesktop: updated.codexDesktop = true
            case .codexCLI: updated.codexCLI = true
            case .claudeCodeCLI, nil: break
            }
        case .claudeCode:
            // Runtime verification additionally requires peer ancestry. A
            // same-user local process can reach the mode-0600 socket, so a
            // self-labelled provider field alone is not product-surface proof.
            if process?.executionSurface == .claudeCodeCLI {
                updated.claudeCode = true
            }
        case .cursor:
            return
        }
        guard updated != integrationObservations else { return }
        integrationObservations = updated
        store.saveAgentIntegrationObservations(updated)
    }

    private func recordCodexLifecycleProcess(_ process: AgentProcessSnapshot?) {
        guard let process, processProvider(process) == .codex else {
            // A current-schema event proves a Codex task existed after the last
            // scan, but without peer ancestry it cannot prove which process is
            // covered. Require another successful scan before claiming idle.
            latestScannedCodexProcessIdentities = nil
            agentProcessScanGate.invalidate()
            return
        }
        codexLifecycleObservedProcessIdentities.insert(process.identity)
        guard latestScannedCodexProcessIdentities?.contains(process.identity) == true else {
            latestScannedCodexProcessIdentities = nil
            agentProcessScanGate.invalidate()
            return
        }
    }

    private func processSessionID(_ identity: AgentProcessIdentity) -> String {
        "process-\(identity.pid)-\(identity.startTimeMicroseconds)"
    }

    private func agentTick() {
        let now = Date()
        reconcileAgentWake(now: now)
        schedulePeriodicCodexCancellationScan()
    }

    private func reconcileAgentWake(now: Date) {
        // Persist both newly accepted lifecycle events and any sessions still
        // awaiting the helper's startup answer. Pending sessions remain absent
        // from the live arbiter, but a second crash in this small window must
        // neither resurrect an ended session nor lose a newly working one.
        let currentRecovery = agentMachine.recoverySnapshot(at: now)
        if let pendingAgentRecovery {
            store.saveAgentRecoverySnapshot(AgentStateRecoverySnapshot(
                sessions: currentRecovery.sessions + pendingAgentRecovery.sessions,
                tombstones: currentRecovery.tombstones + pendingAgentRecovery.tombstones
            ))
        } else {
            store.saveAgentRecoverySnapshot(currentRecovery)
        }
        let previousAgentKeys = Set(knownAgentSources.compactMap { source -> AgentSessionKey? in
            guard case .agent(let key) = source else { return nil }
            return key
        })
        let previousAgentTurnKeys = knownActiveAgentTurns
        for source in knownAgentSources { wakeArbiter.setIntent(source, active: false) }
        knownAgentSources.removeAll()

        let activeKeys = agentMachine.activeSessions(at: now)
        let activeTurnKeys = agentMachine.activeTurns(at: now)
        knownActiveAgentTurns = activeTurnKeys
        // A continuation always cancels pending sleep, even when battery/helper
        // policy prevents that session from acquiring a new wake source.
        if !activeKeys.isEmpty {
            conditionalSleepRelease.cancel()
            conditionalReleaseLabel = "FINISHED"
        }
        let agentPowerAllowed = batteryOnAC || aiSettings.allowOnBattery
        if aiSettings.isEnabled, helperInstalled, agentPowerAllowed {
            for key in activeKeys {
                let source = WakeIntentSource.agent(key)
                wakeArbiter.setIntent(source, active: true)
                knownAgentSources.insert(source)
            }
        }

        updateSafetyVetoes(hasAgentWork: !activeKeys.isEmpty)
        let states = agentMachine.allTurns(at: now)
        let completionDecision = AgentSleepReleasePolicy.evaluate(
            previousAgentKeys: previousAgentKeys,
            currentAgentKeys: activeKeys,
            previousAgentTurnKeys: previousAgentTurnKeys,
            currentAgentTurnKeys: activeTurnKeys,
            sessionStates: states,
            requestedWakeSources: wakeArbiter.decision.requestedSources,
            safetyVetoes: wakeArbiter.decision.safetyVetoes,
            now: now
        )
        let shouldRequestSleep: Bool
        switch completionDecision {
        case .requestSleep:
            consumedCompletionBlockers.removeAll()
            consumedCompletionReleasePending = false
            conditionalReleaseLabel = terminalReleaseLabel(
                previousTurnKeys: previousAgentTurnKeys,
                currentTurnKeys: activeTurnKeys,
                states: states,
                now: now
            )
            agentCompletionNotice = "\(conditionalReleaseLabel) · checking lid"
            shouldRequestSleep = true
        case .blocked(let blockers):
            consumedCompletionLabel = terminalReleaseLabel(
                previousTurnKeys: previousAgentTurnKeys,
                currentTurnKeys: activeTurnKeys,
                states: states,
                now: now
            )
            consumedCompletionBlockers = blockers
            consumedCompletionReleasePending = false
            agentCompletionNotice = completionBlockerNotice(blockers)
            shouldRequestSleep = false
        case .noTrigger:
            updateNonSleepTerminalNotice(
                previousAgentKeys: previousAgentKeys,
                currentAgentKeys: activeKeys,
                previousAgentTurnKeys: previousAgentTurnKeys,
                currentAgentTurnKeys: activeTurnKeys,
                states: states,
                now: now
            )
            shouldRequestSleep = false
        }
        updateAgentPresentation(now: now, hasAgentWork: !activeKeys.isEmpty,
                                powerAllowed: agentPowerAllowed)
        applyWakeDecision(
            origin: .agent,
            now: now,
            sleepAfterSuccessfulAgentCompletion: shouldRequestSleep
        )
    }

    private func completionBlockerNotice(
        _ blockers: Set<AgentSleepReleaseBlocker>
    ) -> String {
        var labels: [String] = []
        if blockers.contains(.manual) { labels.append("manual hold") }
        if blockers.contains(.timer) { labels.append("timer") }
        if blockers.contains(.charging) { labels.append("charging hold") }
        if blockers.contains(.safety) { labels.append("safety pause") }
        return "\(consumedCompletionLabel) · \(labels.joined(separator: ", ")) remains"
    }

    /// Cancellation never becomes a conditional sleep request. This notice
    /// state only follows the ordinary aggregate lease until its policy-only
    /// release is confirmed, or explains which independent hold remains.
    private func prepareCodexCancellationPolicyReleaseNotice() {
        consumedCompletionLabel = "Codex task cancelled"
        var blockers: Set<AgentSleepReleaseBlocker> = []
        let sources = wakeArbiter.decision.requestedSources
        if sources.contains(.manual) { blockers.insert(.manual) }
        if sources.contains(.manualTimer) { blockers.insert(.timer) }
        if sources.contains(.charging) { blockers.insert(.charging) }

        consumedCompletionBlockers = blockers
        if blockers.isEmpty {
            consumedCompletionReleasePending = true
            agentCompletionNotice = "Codex task cancelled · restoring system sleep"
        } else {
            consumedCompletionReleasePending = false
            agentCompletionNotice = completionBlockerNotice(blockers)
        }
    }

    private func terminalReleaseLabel(
        previousTurnKeys: Set<AgentTurnKey>,
        currentTurnKeys: Set<AgentTurnKey>,
        states: [AgentSessionState],
        now: Date
    ) -> String {
        let removed = previousTurnKeys.subtracting(currentTurnKeys)
        let stateByTurn = Dictionary(uniqueKeysWithValues: states.compactMap { state in
            state.turnKey.map { ($0, state) }
        })
        return removed.contains { key in
            stateByTurn[key]?.effectiveTerminalDisposition(at: now) == .waitingExpired
        } ? "WAIT EXPIRED" : "FINISHED"
    }

    private func updateNonSleepTerminalNotice(
        previousAgentKeys: Set<AgentSessionKey>,
        currentAgentKeys: Set<AgentSessionKey>,
        previousAgentTurnKeys: Set<AgentTurnKey>,
        currentAgentTurnKeys: Set<AgentTurnKey>,
        states: [AgentSessionState],
        now: Date
    ) {
        // Turn tracking exists even when automation, power policy, or a missing
        // helper prevented a wake source from being acquired. Presentation of
        // an exact terminal must therefore use turn edges, not lease ownership.
        guard !previousAgentTurnKeys.isEmpty,
              currentAgentTurnKeys.isEmpty,
              currentAgentKeys.isEmpty else { return }
        let stateByTurnKey = Dictionary(uniqueKeysWithValues: states.compactMap { state in
            state.turnKey.map { ($0, state) }
        })
        let dispositions = previousAgentTurnKeys
            .subtracting(currentAgentTurnKeys)
            .compactMap {
            stateByTurnKey[$0]?.effectiveTerminalDisposition(at: now)
        }
        if dispositions.contains(.cancelled) {
            prepareCodexCancellationPolicyReleaseNotice()
        } else if dispositions.contains(.failed) {
            agentCompletionNotice = "FAILED · system sleep restored"
        } else if dispositions.contains(.hardLimit) {
            agentCompletionNotice = "LIMIT REACHED · system sleep restored"
        } else if dispositions.contains(.waitingExpired) {
            agentCompletionNotice = "WAIT EXPIRED · system sleep restored"
        } else if dispositions.isEmpty {
            agentCompletionNotice = "SESSION ENDED · system sleep restored"
        }
    }

    private func updateSafetyVetoes(hasAgentWork: Bool) {
        let onBattery = !batteryOnAC
        let globalLowBattery = settings.lowBatteryThreshold > 0
            && onBattery && batteryPercent <= settings.lowBatteryThreshold
        // AI battery mode always retains a 20% floor even if the legacy manual
        // slider is set to Never.
        let aiLowBattery = hasAgentWork && aiSettings.allowOnBattery
            && onBattery && batteryPercent <= 20
        wakeArbiter.setSafetyVeto(
            .thermal,
            active: WakeSafetyPolicy.requiresThermalVeto(
                thermalSerious: thermalSerious(),
                userPauseEnabled: settings.pauseOnHighThermal,
                hasAgentWork: hasAgentWork
            )
        )
        wakeArbiter.setSafetyVeto(.lowBattery, active: globalLowBattery || aiLowBattery)
        wakeArbiter.setSafetyVeto(.powerPolicy,
                                 active: settings.onlyWhileCharging && onBattery)

        let nonAgentRequested = wakeArbiter.decision.requestedSources.contains {
            if case .agent = $0 { return false }
            return true
        }
        wakeArbiter.setSafetyVeto(
            .agentOnBattery,
            active: hasAgentWork && !aiSettings.allowOnBattery && onBattery && !nonAgentRequested
        )
        wakeArbiter.setSafetyVeto(.systemPowerState, active: systemWakeUnavailable)
    }

    private func updateAgentPresentation(now: Date,
                                         hasAgentWork: Bool,
                                         powerAllowed: Bool) {
        let states = agentMachine.allTurns(at: now)
        updateCodexTaskSemanticStatus(now: now, states: states)
        let activeAggregates = agentMachine.sessionAggregates(at: now)
            .filter { $0.activeTurnCount > 0 }
        agentSessionCount = activeAggregates.count
        agentWorkingCount = activeAggregates.filter { $0.workingCount > 0 }.count
        agentWaitingCount = activeAggregates.filter {
            $0.workingCount == 0 && $0.waitingCount > 0
        }.count
        agentFinishingCount = activeAggregates.filter {
            $0.workingCount == 0
                && $0.waitingCount == 0
                && $0.pendingCompletionCount > 0
        }.count

        if hasAgentWork && !helperInstalled {
            agentStatusText = "PAUSED · helper required"
            shouldShowAgentStatus = true
        } else if hasAgentWork && !powerAllowed {
            agentStatusText = "PAUSED · connect power"
            shouldShowAgentStatus = true
        } else if agentSessionCount > 1
                    || [agentWorkingCount, agentWaitingCount, agentFinishingCount]
                        .filter({ $0 > 0 }).count > 1 {
            var parts: [String] = []
            if agentWorkingCount > 0 { parts.append("\(agentWorkingCount) working") }
            if agentWaitingCount > 0 { parts.append("\(agentWaitingCount) waiting") }
            if agentFinishingCount > 0 { parts.append("\(agentFinishingCount) finishing") }
            agentStatusText = parts.joined(separator: " · ")
            shouldShowAgentStatus = true
        } else if agentWorkingCount > 0 {
            agentStatusText = "WORKING"
            shouldShowAgentStatus = true
        } else if agentWaitingCount > 0 {
            let reason = activeAggregates.first?.representativeState.waitingReason
            switch reason {
            case .planConfirmation:
                agentStatusText = "WAITING · plan confirmation"
            case .permission:
                agentStatusText = "WAITING · permission"
            case .userInput, .unknown, nil:
                agentStatusText = "WAITING · input needed"
            }
            shouldShowAgentStatus = true
        } else if agentFinishingCount > 0 {
            agentStatusText = "FINISHING"
            shouldShowAgentStatus = true
        } else if agentMachine.allSessions(at: now).contains(where: { $0.phase == .unknown }) {
            agentStatusText = "Agent discovered"
            shouldShowAgentStatus = true
        } else if let agentCompletionNoticeCanonical {
            agentStatusTextCanonical = agentCompletionNoticeCanonical
            shouldShowAgentStatus = true
        } else {
            agentStatusText = "No AI session"
            shouldShowAgentStatus = false
        }

        let waiting = states.compactMap { state -> Date? in
            guard state.phase == .waitingForInput else { return nil }
            return state.graceDeadline
        }.min()
        if let waiting, waiting > now {
            agentCountdownText = "Input-wait release in: \(AutoOff.formatCountdown(waiting.timeIntervalSince(now)))"
        } else {
            agentCountdownText = ""
        }
    }

    private func updateCodexTaskSemanticStatus(
        now: Date,
        states: [AgentSessionState]? = nil
    ) {
        let summarized = CodexTaskSemanticStatus.summarize(
            sessions: states ?? agentMachine.allTurns(at: now),
            at: now
        )
        let summarizedIsIdle: Bool
        if case .idle = summarized {
            summarizedIsIdle = true
        } else {
            summarizedIsIdle = false
        }
        if summarizedIsIdle, !codexSummaryWasIdle {
            // Completion/idle has the stricter trust boundary. Re-read notify,
            // hooks and Bridge now so a third-party rewrite during this turn
            // cannot inherit the prior snapshot and manufacture trusted idle.
            refreshIntegrationHealth()
        }
        codexSummaryWasIdle = summarizedIsIdle
        let allDetectedProcessesObserved = latestScannedCodexProcessIdentities.map {
            $0.isSubset(of: codexLifecycleObservedProcessIdentities)
        } ?? false
        codexTaskSemanticStatus = summarized.validatedForPresentation(
            lifecycleChannelHealth: codexLifecycleChannelHealth,
            processScanSucceeded: latestScannedCodexProcessIdentities != nil,
            allDetectedProcessesObserved: allDetectedProcessesObserved
        )
    }

    private func updateAgentCompletionNotice(for outcome: HelperReleaseOutcome) {
        consumedCompletionBlockers.removeAll()
        consumedCompletionReleasePending = false
        let label = conditionalReleaseLabel
        switch outcome.disposition {
        case .sleepRequested:
            agentCompletionNotice = "\(label) · sleep requested"
        case .lidOpen:
            agentCompletionNotice =
                "\(label) · system sleep restored; lid was open at completion"
        case .dockedMode:
            agentCompletionNotice =
                "\(label) · system sleep restored; external display was connected at completion"
        case .externalDisplayStateUnknown:
            agentCompletionNotice =
                "\(label) · system sleep restored; display state was unknown at completion"
        case .clamshellBehaviorUnknown, .lidStateUnknown:
            agentCompletionNotice =
                "\(label) · system sleep restored; lid state was unknown at completion"
        case .preexistingWakeSetting:
            agentCompletionNotice = "\(label) · another wake setting remains"
        case .sleepRequestFailed:
            agentCompletionNotice = "\(label) · sleep request failed"
        case .legacyHelper:
            agentCompletionNotice = "\(label) · system sleep restored; helper update required"
        case .releasedWithoutSleep, .noLease:
            agentCompletionNotice = "\(label) · system sleep restored"
        }
        conditionalReleaseLabel = "FINISHED"
        agentCountdownText = ""
    }

    private func refreshConsumedCompletionBlockers(
        using decision: WakeIntentDecision
    ) {
        guard !consumedCompletionBlockers.isEmpty else { return }
        var remaining: Set<AgentSleepReleaseBlocker> = []
        if decision.requestedSources.contains(.manual) { remaining.insert(.manual) }
        if decision.requestedSources.contains(.manualTimer) { remaining.insert(.timer) }
        if decision.requestedSources.contains(.charging) { remaining.insert(.charging) }
        if !decision.safetyVetoes.isEmpty { remaining.insert(.safety) }
        consumedCompletionBlockers = remaining
        if remaining.isEmpty {
            consumedCompletionReleasePending = true
            agentCompletionNotice = "\(consumedCompletionLabel) · restoring system sleep"
        } else {
            consumedCompletionReleasePending = false
            agentCompletionNotice = completionBlockerNotice(remaining)
        }
    }

    private func applyWakeDecision(origin: SetOrigin,
                                   now: Date = Date(),
                                   sleepAfterSuccessfulAgentCompletion: Bool = false) {
        let hasAgentWork = !agentMachine.activeSessions(at: now).isEmpty
        updateSafetyVetoes(hasAgentWork: hasAgentWork)
        let decision = wakeArbiter.decision
        // Permission to submit conditional sleep exists only while *nothing*
        // else asks to wake and no veto or continued session exists. Cancelling
        // here happens before any replacement acquire/ordinary release.
        if hasAgentWork || decision.shouldWake
            || !decision.requestedSources.isEmpty || !decision.safetyVetoes.isEmpty {
            conditionalSleepRelease.cancel()
        }
        refreshConsumedCompletionBlockers(using: decision)
        if !decision.shouldWake,
           !helperLeaseActive,
           !recoveryLeaseInspectionInFlight,
           consumedCompletionReleasePending {
            // The blocker can outlive the AI lease (for example automation was
            // disabled or the lease was already released). In that case there
            // is no helper callback left to finalize the UI: normal system sleep
            // is already restored because Lidless owns no wake transition.
            agentCompletionNotice = "\(consumedCompletionLabel) · system sleep restored"
            consumedCompletionReleasePending = false
        }
        wakeSourceSummary = sourceSummary(decision.activeSources)
        if wakeSourceSummary.isEmpty, isEnabled { wakeSourceSummary = "External/system" }
        // Display-idle ownership is a strictly weaker, app-local derivative of
        // the already-confirmed Helper lease. Reconcile before any helper release
        // (including the five-second completion path), so waiting/finishing and
        // safety transitions restore macOS display policy immediately.
        reconcileDisplayAwake(now: now)
        // Events and timer ticks may continue during emergency restore so their
        // semantic state is not lost, but the restore transaction is the only
        // authority allowed to mutate the helper lease until it completes.
        guard !isRestoringNormalSleep else { return }
        guard !recoveryLeaseInspectionInFlight, !helperRepairInFlight else { return }

        // The first completion tick already owns the only release request. Until
        // it completes or is cancelled, later 1-second ticks must not supersede
        // it with an ordinary release.
        if conditionalSleepRelease.isInFlight { return }

        let nonAgentActive = decision.activeSources.contains {
            if case .agent = $0 { return false }
            return true
        }
        let nextHasHardDeadline = !nonAgentActive
        let nextDecisionDeadline = desiredLeaseDeadline(
            activeSources: decision.activeSources,
            now: now,
            hasUnlimitedSource: nonAgentActive
        )
        let leaseKindChanged = helperLeaseHasHardDeadline != nextHasHardDeadline
        let hardDeadlineChanged = nextHasHardDeadline
            && abs(helperLeaseDeadline.timeIntervalSince(nextDecisionDeadline)) > 0.5
        helperLeaseHasHardDeadline = nextHasHardDeadline
        aggregateDecisionDeadline = nextDecisionDeadline

        if decision.shouldWake == aggregateWakeRequested {
            // A fresh app instance may discover the previous instance's live
            // aggregate lease through getLeaseState. With no current source,
            // release it now instead of waiting for the 90-second watchdog.
            if !decision.shouldWake, helperLeaseActive {
                setEnabled(
                    false,
                    origin: origin,
                    preserveTimedIntentOnRelease: !decision.safetyVetoes.isEmpty,
                    sleepAfterSuccessfulAgentCompletion: sleepAfterSuccessfulAgentCompletion
                )
                return
            }
            // Source composition may change while the aggregate remains on
            // (manual ends while an Agent continues, or another session starts).
            // Update the absolute lease bound without toggling SleepDisabled.
            if decision.shouldWake,
               helperLeaseActive,
               helperInstalled,
               leaseKindChanged || hardDeadlineChanged {
                helperLeaseDeadline = aggregateDecisionDeadline
                helper.updateLease(id: aggregateLeaseID, notAfter: aggregateDecisionDeadline) {
                    [weak self] ok, error in
                    self?.handleLeaseMaintenanceResult(ok: ok, error: error)
                }
            }
            return
        }

        if decision.shouldWake {
            normalSleepRestoreStatus = nil
        }
        aggregateWakeRequested = decision.shouldWake
        setEnabled(
            decision.shouldWake,
            origin: origin,
            preserveTimedIntentOnRelease: !decision.safetyVetoes.isEmpty,
            sleepAfterSuccessfulAgentCompletion: sleepAfterSuccessfulAgentCompletion
        )
    }

    private func desiredLeaseDeadline(activeSources: Set<WakeIntentSource>,
                                      now: Date,
                                      hasUnlimitedSource: Bool) -> Date {
        if hasUnlimitedSource { return now.addingTimeInterval(24 * 60 * 60) }
        let deadlines = agentMachine.allTurns(at: now).compactMap { state -> Date? in
            guard activeSources.contains(.agent(state.key)) else { return nil }
            return state.wakeDeadline(at: now)
        }
        return deadlines.max() ?? now.addingTimeInterval(aiSettings.maximumDuration)
    }

    private func sourceSummary(_ sources: Set<WakeIntentSource>) -> String {
        var labels: [String] = []
        if sources.contains(.manual) { labels.append("Manual hold") }
        if sources.contains(.manualTimer) { labels.append("Manual timer") }
        if sources.contains(.charging) { labels.append("Charging hold") }
        let agents = sources.compactMap { source -> AgentProvider? in
            if case .agent(let key) = source { return key.provider }
            return nil
        }
        let uniqueAgents = Set(agents).sorted { $0.rawValue < $1.rawValue }
        labels.append(contentsOf: uniqueAgents.map(\.displayName))
        return labels.joined(separator: ", ")
    }

    private func thermalSerious() -> Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }

    /// Auto-disable keep-awake if current conditions violate the safety policy.
    func evaluateSafety() {
        refreshBattery()
        let reason = SafetyEvaluator.reasonToDisable(
            battery: currentBattery,
            thermalSerious: thermalSerious(),
            settings: settings
        )
        if let reason { lastError = reason.message }
        updateSafetyVetoes(hasAgentWork: !agentMachine.activeSessions(at: Date()).isEmpty)
        applyWakeDecision(origin: .safety)
    }

    // MARK: Helper lifecycle

    func refreshHelperStatus() {
        helperInstalled = helper.isEnabled
        helperNeedsApproval = helper.requiresApproval
        usingHelper = helperInstalled
        if !helperInstalled {
            conditionalSleepRelease.cancel()
            helperHealthGeneration += 1
            helperRecoveryNotice = nil
            recoveryLeaseInspectionInFlight = false
            // A failed update repair may already have removed the old job while
            // leaving its root journal intact. Preserve provisional Agent state
            // until the persisted repair is resumed and the replacement helper
            // can inspect that journal.
            if pendingAgentRecovery != nil,
               !store.loadHelperRegistrationRepairPending() {
                discardPendingAgentRecovery(at: Date())
            }
        }
    }

    /// Surface durable recovery failures immediately instead of waiting for the
    /// user's next enable attempt. A malformed journal is deliberately retained
    /// by the helper because silently discarding ownership evidence could clear
    /// another tool's system-wide setting.
    private func inspectHelperLeaseHealth() {
        guard helperInstalled, !helperRepairInFlight else { return }
        helperHealthGeneration += 1
        let generation = helperHealthGeneration
        recoveryLeaseInspectionInFlight = pendingAgentRecovery != nil
        helper.getLeaseState { [weak self] state, error in
            guard let self, generation == self.helperHealthGeneration else { return }
            if let error, !error.isEmpty {
                self.recoveryLeaseInspectionInFlight = false
                self.helperRecoveryNotice = "Background helper recovery needs attention: \(error)"
                self.discardPendingAgentRecovery(at: Date())
                return
            }
            self.helperRecoveryNotice = nil
            guard let state else {
                self.recoveryLeaseInspectionInFlight = false
                self.discardPendingAgentRecovery(at: Date())
                return
            }
            guard state["leaseID"] as? String == self.aggregateLeaseID else {
                self.recoveryLeaseInspectionInFlight = false
                self.discardPendingAgentRecovery(at: Date())
                self.helperRecoveryNotice = "The background helper has an unexpected active lease. Reinstall it before continuing."
                return
            }
            guard state["phase"] as? String == HelperLeasePhase.active.rawValue else {
                self.recoveryLeaseInspectionInFlight = false
                self.discardPendingAgentRecovery(at: Date())
                self.helperRecoveryNotice = "The background helper is still restoring a previous keep-awake lease."
                return
            }

            let now = Date()
            guard let notAfter = state["notAfter"] as? NSNumber,
                  let lastHeartbeat = state["lastHeartbeat"] as? NSNumber,
                  notAfter.doubleValue > now.timeIntervalSince1970,
                  now.timeIntervalSince1970 - lastHeartbeat.doubleValue < 90,
                  lastHeartbeat.doubleValue <= now.addingTimeInterval(5 * 60).timeIntervalSince1970 else {
                self.recoveryLeaseInspectionInFlight = false
                self.discardPendingAgentRecovery(at: now)
                self.helperRecoveryNotice = "The background helper is expiring a stale keep-awake lease."
                return
            }

            let leaseDeadline = Date(timeIntervalSince1970: notAfter.doubleValue)
            let pendingCodexTurns = self.codexCancellationObservedTurns(at: now)
            if self.pendingAgentRecovery != nil, !pendingCodexTurns.isEmpty {
                // Keep the lease-mutation gate raised while the final disk check
                // runs. An interrupt can land after the launch scan but before
                // this helper reply, and must win before provisional work is
                // merged back into the live state machine.
                let observer = self.codexCancellationObserver
                self.codexCancellationScanQueue.async { [weak self] in
                    let cancellations = observer.reconcile(
                        activeTurns: pendingCodexTurns
                    )
                    DispatchQueue.main.async {
                        guard let self else { return }
                        let completedAt = Date()
                        // Observer delivery is commit-on-return. Always ingest
                        // exact terminal records even if a newer helper-health
                        // generation superseded only the lease-adoption work.
                        self.applyCodexCancellationRecords(
                            cancellations,
                            receivedAt: completedAt,
                            reconcileWake: false
                        )
                        guard generation == self.helperHealthGeneration else { return }
                        self.recoveryLeaseInspectionInFlight = false
                        guard leaseDeadline > completedAt else {
                            self.discardPendingAgentRecovery(at: completedAt)
                            self.helperRecoveryNotice = "The background helper is expiring a stale keep-awake lease."
                            return
                        }
                        self.mergeRemainingPendingRecoveryAndAdoptHelperLease(
                            deadline: leaseDeadline,
                            at: completedAt
                        )
                    }
                }
                return
            }

            self.recoveryLeaseInspectionInFlight = false
            self.mergeRemainingPendingRecoveryAndAdoptHelperLease(
                deadline: leaseDeadline,
                at: now
            )
        }
    }

    private func mergeRemainingPendingRecoveryAndAdoptHelperLease(
        deadline: Date,
        at now: Date
    ) {
        if let recovery = pendingAgentRecovery {
            mergeAgentRecovery(recovery, at: now)
            pendingAgentRecovery = nil
        }

        // Adopt a live aggregate lease left by an earlier app instance, then
        // reconcile it with this instance's sources. With no source it is
        // released now; with valid work it resumes heartbeat management.
        helperLeaseActive = true
        helperLeaseDeadline = deadline
        reconcileAgentWake(now: now)
        if wakeArbiter.decision.shouldWake, helperLeaseActive {
            manageHeartbeat()
        }
    }

    /// A fresh active-start event recovers only its exact turn. Session/process
    /// observations do not prove semantic work, so every other provisional turn
    /// still requires the helper lease to prove survival.
    private func activatePendingAgentRecovery(for event: AgentEvent, at now: Date) {
        guard let recovery = pendingAgentRecovery else { return }
        let matching = AgentRecoveryActivationPolicy.matchingStates(
            in: recovery,
            for: event
        )
        guard !matching.isEmpty else { return }
        mergeAgentRecovery(
            AgentStateRecoverySnapshot(
                sessions: matching,
                tombstones: []
            ),
            at: now
        )
        let activatedTurnKeys = Set(matching.compactMap(\.turnKey))
        let remaining = recovery.sessions.filter { state in
            guard let turnKey = state.turnKey else { return !matching.contains(state) }
            return !activatedTurnKeys.contains(turnKey)
        }
        pendingAgentRecovery = remaining.isEmpty
            ? nil
            : AgentStateRecoverySnapshot(sessions: remaining, tombstones: [])
    }

    private func discardPendingAgentRecovery(at now: Date) {
        guard let recovery = pendingAgentRecovery else { return }
        let recoverableWaits = recovery.sessions.compactMap { state -> AgentSessionState? in
            guard state.phase == .waitingForInput,
                  state.hardDeadline.map({ now < $0 }) == true else { return nil }
            // No live helper lease means the old wake grace is not evidence for
            // reacquiring. Retain only a non-wake lifecycle shell so a later
            // approval activity can resume under the original hard deadline.
            var nonWake = state
            nonWake.graceDeadline = min(state.graceDeadline ?? now, now)
            return nonWake
        }
        mergeAgentRecovery(
            AgentStateRecoverySnapshot(
                sessions: recoverableWaits,
                tombstones: []
            ),
            at: now
        )
        pendingAgentRecovery = nil
        reconcileAgentWake(now: now)
    }

    /// Merge recovered sessions with lifecycle events already accepted by this
    /// app instance. This closes the startup race where one fresh session event
    /// arrives before the helper has answered about other provisional sessions.
    private func mergeAgentRecovery(_ recovery: AgentStateRecoverySnapshot, at now: Date) {
        let current = agentMachine.recoverySnapshot(at: now)
        agentMachine.restore(
            AgentStateRecoverySnapshot(
                sessions: current.sessions + recovery.sessions,
                tombstones: current.tombstones + recovery.tombstones
            ),
            at: now
        )
    }

    /// The app's current build number (`CFBundleVersion`).
    private var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    private func storeCurrentHelperBuild() {
        store.saveLastHelperBuild(currentBuild)
    }

    /// After an app update the helper binary is re-signed and its launchd job can
    /// keep a stale launch record, so the daemon fails to start (EX_CONFIG) and
    /// XPC calls hang — the toggle then silently does nothing. On the first launch
    /// of a new build, require the exact current helper advertisement. An older
    /// helper can remain reachable after the app updates; treating reachability
    /// as freshness would permanently skip the v2 registration repair.
    private func refreshHelperRegistrationIfUpdated() {
        guard !currentBuild.isEmpty else { return }
        if store.loadHelperRegistrationRepairPending() {
            resumePendingHelperRegistration()
            return
        }
        guard store.loadLastHelperBuild() != currentBuild else { return }
        guard helper.isEnabled else {
            // No daemon exists to advertise its embedded build yet. Leave the
            // build unrecorded; after first-time registration, the next launch
            // proves the exact advertisement before saving it.
            return
        }
        helper.checkCurrentVersion { [weak self] isCurrent, _ in
            guard let self else { return }
            if isCurrent {
                self.storeCurrentHelperBuild()
            } else {
                self.repairHelper()
            }
        }
    }

    /// Continue an update repair that may have been interrupted after launchd
    /// removed the old job. A plain "not enabled" status is not a first-install
    /// signal in this state: the root journal may still own SleepDisabled and
    /// needs a replacement KeepAlive helper to recover it.
    private func resumePendingHelperRegistration() {
        conditionalSleepRelease.cancel()
        guard !helperRepairInFlight else { return }
        if helper.requiresApproval {
            lastError = "Approve CodeWake in System Settings ▸ Login Items to finish repairing the background helper."
            return
        }
        helperRepairInFlight = true
        stopDisplayAwakeAssertion()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        helperHealthGeneration += 1
        helperRecoveryNotice = nil
        if helper.isEnabled {
            helper.checkCurrentVersion { [weak self] isCurrent, _ in
                guard let self else { return }
                self.helperRepairInFlight = false
                if isCurrent {
                    self.store.saveHelperRegistrationRepairPending(false)
                    self.storeCurrentHelperBuild()
                    self.resetSystemWakeFailure()
                    self.inspectHelperLeaseHealth()
                } else {
                    self.repairHelper()
                }
            }
            return
        }
        helper.registerWithRetry { [weak self] error in
            guard let self else { return }
            self.refreshHelperStatus()
            if let error {
                self.helperRepairInFlight = false
                self.lastError = "Background helper repair will retry next launch: \(error.localizedDescription)"
                return
            }
            if self.helper.requiresApproval {
                self.helperRepairInFlight = false
                self.lastError = "Approve CodeWake in System Settings ▸ Login Items to finish repairing the background helper."
                self.helper.openLoginItemsSettings()
                return
            }
            guard self.helperInstalled else {
                self.helperRepairInFlight = false
                self.lastError = "The background helper registration is still unavailable and will retry next launch."
                return
            }
            self.helper.checkCurrentVersion { [weak self] isCurrent, versionError in
                guard let self else { return }
                self.helperRepairInFlight = false
                guard isCurrent else {
                    if let versionError {
                        self.setPresentationError(
                            .helperVersionCheckFailed,
                            diagnostic: versionError
                        )
                    } else {
                        self.lastError = "The replacement helper is not the current version; repair will retry next launch."
                    }
                    return
                }
                self.store.saveHelperRegistrationRepairPending(false)
                self.storeCurrentHelperBuild()
                self.lastError = "Background helper repair resumed successfully."
                self.resetSystemWakeFailure()
                self.inspectHelperLeaseHealth()
            }
        }
    }

    /// Re-read helper status; if it just became usable (the user approved it while
    /// the app was running), pick up its keep-awake state and prompt a restart so
    /// the app fully switches onto the privileged helper.
    func recheckHelper() {
        let wasUsable = helperWasUsable
        refreshHelperStatus()
        helperWasUsable = usingHelper
        if store.loadHelperRegistrationRepairPending() {
            resumePendingHelperRegistration()
            return
        }
        if usingHelper { inspectHelperLeaseHealth() }
        guard !wasUsable, usingHelper else { return }
        refreshState()
        promptRestartAfterHelperEnabled()
    }

    /// Tell the user the helper is now active and offer to relaunch. The privileged
    /// XPC connection is most reliable from a fresh launch, so a restart is the
    /// simplest way to finish setup.
    private func promptRestartAfterHelperEnabled() {
        // If this happened mid-onboarding, resume the flow after the relaunch.
        if onboardingActive { store.saveResumeOnboarding(true) }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = localized(
            "Background helper enabled",
            defaultValue: "Background helper enabled"
        )
        alert.informativeText = localized(
            "Restart CodeWake to finish connecting to the background helper.",
            defaultValue: "Restart CodeWake to finish connecting to the background helper."
        )
        alert.addButton(withTitle: localized("Restart Now", defaultValue: "Restart Now"))
        alert.addButton(withTitle: localized("Later", defaultValue: "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            relaunch()
        }
    }

    /// Spawn a fresh instance of the app, then terminate this one.
    private func relaunch() {
        relaunchAfterTermination = true
        NSApp.terminate(nil)
    }

    func installHelper() {
        conditionalSleepRelease.cancel()
        if store.loadHelperRegistrationRepairPending() {
            if helper.requiresApproval {
                openLoginItems()
            } else {
                resumePendingHelperRegistration()
            }
            return
        }
        helperHealthGeneration += 1
        helperRecoveryNotice = nil
        recoveryLeaseInspectionInFlight = false
        if pendingAgentRecovery != nil {
            discardPendingAgentRecovery(at: Date())
        }
        // If the daemon is already registered and just awaiting approval, don't
        // re-register (that throws once pending and would swallow the open) —
        // just take the user to Login Items.
        if helper.requiresApproval {
            openLoginItems()
            return
        }
        do {
            try helper.register()
            let wasUsable = helperWasUsable
            refreshHelperStatus()
            helperWasUsable = usingHelper
            if helper.requiresApproval {
                lastError = "Approve CodeWake in System Settings ▸ Login Items."
                helper.openLoginItemsSettings()
            } else {
                lastError = nil
                // Rare: registered and immediately usable (already approved). Treat
                // it as the same enable transition the approval path would hit.
                if !wasUsable, usingHelper {
                    refreshState()
                    promptRestartAfterHelperEnabled()
                }
            }
        } catch {
            setPresentationError(
                .helperInstallFailed,
                diagnostic: error.localizedDescription
            )
        }
    }

    /// Open System Settings ▸ Login Items so the user can approve the helper.
    /// Kept separate from `installHelper()` so re-registration can never swallow
    /// the open.
    func openLoginItems() {
        lastError = "Approve CodeWake in System Settings ▸ Login Items."
        helper.openLoginItemsSettings()
        refreshHelperStatus()
    }

    // MARK: State

    /// Read the real `SleepDisabled` flag and bring the UI into step with it.
    ///
    /// Always read directly rather than asking the helper: the XPC reply is a
    /// plain `Bool`, so a `pmset` failure inside the daemon would arrive as a
    /// confident "off". Reading needs no privileges, so there's nothing to gain
    /// by routing it through root — and an unknown stays an unknown.
    func refreshState() {
        let token = sync.beginRead()
        applyObserved(power.isSleepDisabled(), token)
    }

    private func applyObserved(_ observed: Bool?, _ token: StateSync.ReadToken) {
        guard sync.shouldApply(token) else { return }   // superseded by a newer read or a write

        // A write we haven't confirmed owns the interpretation until it resolves:
        // a disagreement here is our own write failing to hold, not somebody
        // else's doing, and mustn't be reported as an external change.
        if let pending = pendingVerification {
            switch StateReconciler.resolve(pending, observed: observed) {
            case .stillUnverified:
                break
            case .confirmed:
                autoWrite.resolved()
                pendingVerification = nil
                verificationNotice = nil
                hasConfirmedState = true
            case .writeMismatch(let actual):
                // Same ordering rule as `applyVerification`: settle the claim
                // before adopting, so the reconcile that adopting triggers can't
                // chase the mismatch with another write in this turn.
                autoWrite.resolved()
                pendingVerification = nil
                verificationNotice = StateReconciler.writeMismatchMessage(actual: actual)
                hasConfirmedState = true
                adoptSystemState(actual)
            }
            return
        }

        switch StateReconciler.reconcile(shown: isEnabled,
                                         hasBaseline: hasConfirmedState,
                                         observed: observed) {
        case .unknown:
            break                                       // keep the last-known state
        case .inSync:
            hasConfirmedState = true                    // no side effects, by construction
        case .adopt(let enabled):
            hasConfirmedState = true
            adoptSystemState(enabled)
        case .drift(let change):
            hasConfirmedState = true
            // Set before adopting: adopting `true` can synchronously trip a safety
            // pause, and the notice should already be in place when it does.
            externalNotice = change.message
            adoptSystemState(change.nowEnabled)
        }
    }

    /// Bring `isEnabled` in line with reality *without* touching the flag, running
    /// the side effects `setEnabled` would have run for this state.
    ///
    /// Only ever reached for a real transition — `reconcile` returns `.inSync`
    /// when the values already agree — so the 30-second poll can't re-arm the
    /// auto-off timer or restart the heartbeat on every pass.
    private func adoptSystemState(_ enabled: Bool) {
        let now = Date()
        let preserveTimer = !enabled && AutoOff.shouldPreserveDuringUnexpectedDisable(
            deadline: autoOffDeadline,
            now: now,
            helperLeaseActive: helperLeaseActive
        )
        isEnabled = enabled
        sync.beginMutation()            // supersede every read and write still in flight
        manageHeartbeat()
        if preserveTimer {
            refreshAutoOffRemaining()
        } else {
            updateAutoOff(for: enabled)
        }
        if !enabled, helperLeaseActive {
            updateSafetyVetoes(hasAgentWork: !agentMachine.activeSessions(at: now).isEmpty)
            if wakeArbiter.decision.shouldWake {
                if !unexpectedDisableReassertionAttempted {
                    unexpectedDisableReassertionAttempted = true
                    // Force a same-ID acquire. HelperService sees the real flag
                    // is now 0, retires the old baseline, and records a fresh
                    // durable 0→1 transaction before writing it back to 1.
                    helperLeaseActive = false
                    aggregateWakeRequested = false
                    manageHeartbeat()
                    applyWakeDecision(origin: .agent)
                } else {
                    systemWakeUnavailable = true
                    lastError = "Keep-awake did not hold after a retry. CodeWake released its lease to avoid reporting unsafe protection."
                    applyWakeDecision(origin: .safety)
                }
            } else {
                // A safety veto or the last source ending while the flag drifted
                // still needs to release the durable helper journal.
                applyWakeDecision(origin: .safety)
            }
        }
        // Auto mode owns the live state, so route through `reconcile()` rather
        // than the manual safety pass: adopting an outside change must be settled
        // by the same rule that set the state in the first place, or the toggle
        // visibly jumps and then falls back a tick later.
        if settings.autoEnableWhenCharging {
            reconcile()
        } else if enabled {
            evaluateSafety()
        }
    }

    /// User flipped the toggle: `.user` origin so any failure or refusal surfaces
    /// a visible alert (not just the easy-to-miss inline note).
    func toggle() {
        setMasterToggle(!masterToggleOn)
    }

    /// Set keep-awake. `note` is shown to the user on a successful change
    /// (used when an auto-pause or the auto-off timer disables it); nil clears
    /// any prior message. When `origin` is `.user` (the user flipped the toggle),
    /// a failure or policy refusal also pops a blocking alert so it can't go
    /// unnoticed; background callers pass their own origin to stay quiet.
    /// `conditions` is the sample a caller already made its decision from. The
    /// safety check below still runs — this is not a bypass — but it runs against
    /// those conditions rather than a fresh reading, so a decision and the write
    /// it authorises can't be judged against different worlds. Callers that have
    /// no decision to be consistent with (the user flipping the switch) omit it
    /// and get the fresh reading, which is what they want.
    func setEnabled(_ target: Bool,
                    note: String? = nil,
                    origin: SetOrigin = .user,
                    conditions: SafetySnapshot? = nil,
                    preserveTimedIntentOnRelease: Bool = false,
                    sleepAfterSuccessfulAgentCompletion: Bool = false) {
        guard !isRestoringNormalSleep else { return }
        if target {
            normalSleepRestoreStatus = nil
        }
        if target {
            // Direct auto-mode handoffs can call setEnabled without first going
            // through applyWakeDecision; they must cancel stale sleep too.
            conditionalSleepRelease.cancel()
        } else if conditionalSleepRelease.isInFlight {
            // A completion release is already waiting on its version probe/XPC
            // reply. Do not turn a repeated tick into a second release.
            return
        }
        guard !helperRepairInFlight else {
            if origin == .user {
                lastError = "The background helper is being reinstalled. Try again in a moment."
            }
            return
        }
        if StateReconciler.clearsExternalNotice(origin) { externalNotice = nil }
        // Any other origin takes the flag away from auto mode: its claim is void
        // and its reply, if one is still in flight, will be rejected as superseded
        // below. Leaving the claim standing would stall auto mode for a tick or
        // two on a reply that is never coming.
        if origin != .auto { autoWrite.clear() }

        // Refuse to enable if it would immediately violate the safety policy.
        // Returns before claiming a mutation, so nothing in flight is disturbed —
        // which is exactly why a caller correcting an outstanding write must pass
        // the conditions it decided from: a refusal here supersedes nothing.
        if target {
            let checked = conditions ?? SafetySnapshot(battery: battery.read(),
                                                       thermalSerious: thermalSerious())
            if let blocker = SafetyEvaluator.reasonToDisable(battery: checked.battery,
                                                             thermalSerious: checked.thermalSerious,
                                                             settings: settings) {
                lastError = blocker.message
                if origin == .user {
                    presentFailureAlert(target: target, message: blocker.blockedMessage)
                }
                // Nothing was dispatched, so release the claim rather than holding
                // it for a write that never happened.
                if origin == .auto { autoWrite.clear() }
                return
            }
        }
        let resultMessage = note

        // A new write supersedes any older one, along with its pending verification.
        pendingVerification = nil
        verificationNotice = nil
        let token = sync.beginMutation()

        if helperInstalled || (!target && helperLeaseActive) {
            // A local mutation supersedes any older asynchronous health reply.
            helperHealthGeneration += 1
            helperRecoveryNotice = nil
            let deadline = leaseDeadline(for: origin)
            let finish: (Bool, String?, HelperReleaseOutcome?, Bool) -> Void = {
                [weak self] ok, err, releaseOutcome, conditionalAuthority in
                guard let self,
                      conditionalAuthority || self.sync.shouldApply(token) else { return }
                if ok {
                    if releaseOutcome?.disposition == .sleepRequestFailed {
                        self.setPresentationError(
                            .systemSleepRequestFailed,
                            diagnostic: err ?? "sleepRequestFailed"
                        )
                    } else {
                        self.lastError = err ?? resultMessage
                    }
                    self.helperLeaseActive = target
                    if target {
                        self.helperLeaseDeadline = deadline
                        self.isEnabled = true
                        self.updateAutoOff(for: true)
                        // Acquiring a lease guarantees the flag should now be on.
                        self.pendingVerification = PendingVerification(target: true)
                        self.verifySetApplied(target: true)
                    } else {
                        if let releaseOutcome {
                            self.updateAgentCompletionNotice(for: releaseOutcome)
                        } else if self.consumedCompletionReleasePending {
                            self.agentCompletionNotice =
                                "\(self.consumedCompletionLabel) · system sleep restored"
                            self.consumedCompletionReleasePending = false
                        }
                        // Releasing means "remove our ownership", not "force the
                        // global flag to zero". If another tool had it enabled
                        // before our lease, the helper correctly restores that
                        // baseline and a true read-back is not a failed write.
                        self.pendingVerification = nil
                        self.verificationNotice = nil
                        if preserveTimedIntentOnRelease,
                           AutoOff.shouldPreserveDuringSafetyPause(
                                deadline: self.autoOffDeadline,
                                now: Date()
                           ) {
                            self.refreshAutoOffRemaining()
                        } else {
                            self.updateAutoOff(for: false)
                        }
                        self.hasConfirmedState = false
                        self.refreshState()
                    }
                    self.reconcileDisplayAwake(now: Date())
                    self.manageHeartbeat()
                } else {
                    // The helper can fail without a message (e.g. a dropped XPC
                    // reply, or the daemon failing to launch after an update);
                    // surface it instead of letting the toggle silently no-op.
                    let message = err ?? "The background helper didn’t respond."
                    self.setPresentationError(
                        .helperWakeUpdateFailed,
                        diagnostic: message
                    )
                    if target {
                        self.aggregateWakeRequested = self.helperLeaseActive
                        // Any automatic acquire failure must stop here. Without
                        // a veto, the 1-second Agent tick can hammer XPC, journal
                        // fsync, and pmset recovery for the full turn limit.
                        // A new prompt or an explicit user enable/repair is the
                        // next bounded retry boundary.
                        self.systemWakeUnavailable = true
                        self.wakeArbiter.setSafetyVeto(.systemPowerState, active: true)
                        self.aggregateWakeRequested = false
                    } else {
                        // Release failure is deliberately not retried every
                        // second. Stop claiming/heartbeating the uncertain lease
                        // and let the helper's durable journal watchdog restore
                        // it. A later real wake source may safely acquire again.
                        let transition = FailedLeaseReleaseTransition.deferToWatchdog
                        self.helperLeaseActive = transition.helperLeaseActive
                        self.aggregateWakeRequested = transition.aggregateWakeRequested
                        if !transition.shouldKeepHeartbeat {
                            self.heartbeatTimer?.invalidate()
                            self.heartbeatTimer = nil
                        }
                    }
                    self.reconcileDisplayAwake(now: Date())
                    if origin == .user {
                        self.presentHelperFailureAlert(
                            message: AppPresentationError.helperWakeUpdateFailed.canonicalMessage
                        )
                    }
                    self.recoverStateAfterFailedWrite()
                }
            }
            if target {
                helper.acquireLease(id: aggregateLeaseID, notAfter: deadline) { ok, error in
                    finish(ok, error, nil, false)
                }
            } else if sleepAfterSuccessfulAgentCompletion {
                guard let releaseToken = conditionalSleepRelease.beginIfIdle() else { return }
                helper.releaseLeaseAndSleepIfEligible(
                    id: aggregateLeaseID,
                    // AI automation never force-sleeps docked/external-display
                    // operation. The helper rechecks topology in the same atomic
                    // release transaction and returns control to macOS.
                    sleepMode: .closedLid,
                    shouldProceed: { [weak self] in
                        self?.conditionalSleepRelease.shouldProceed(releaseToken) == true
                    }
                ) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .cancelled:
                        // Cancellation already cleared or replaced this token;
                        // no helper mutation occurred and no UI state changes.
                        return
                    case .failed(let error):
                        guard self.conditionalSleepRelease.complete(releaseToken) else { return }
                        finish(false, error, nil, true)
                    case .completed(let outcome, let warning):
                        guard self.conditionalSleepRelease.complete(releaseToken) else { return }
                        if outcome.leaseReleased {
                            finish(true, warning, outcome, true)
                        } else {
                            finish(false, warning, nil, true)
                        }
                    }
                }
            } else {
                helper.releaseLease(id: aggregateLeaseID) { ok, error in
                    finish(ok, error, nil, false)
                }
            }
        } else {
            // A raw administrator `pmset` fallback has no durable ownership
            // journal. If the app dies, it can leave SleepDisabled enabled with
            // no safe way to know whether we should clear it. All writes must go
            // through the approved helper; direct reads remain available.
            let message = helperNeedsApproval
                ? "Approve CodeWake in System Settings ▸ Login Items before enabling keep-awake."
                : "Install the CodeWake background helper before enabling keep-awake."
            lastError = message
            aggregateWakeRequested = false
            if target, origin == .user {
                manualWakeRequested = false
                wakeArbiter.setIntent(.manual, active: false)
                cancelAutoOff(reconcileWake: false)
                presentFailureAlert(target: true, message: message)
            }
            recoverStateAfterFailedWrite()
        }
    }

    /// Manual/charging holds have no user-facing hard limit, but the helper
    /// still requires a finite durable deadline. It is rolled forward while the
    /// app is alive. AI deadlines are absolute and are never extended by tool
    /// activity or heartbeat.
    private func leaseDeadline(for origin: SetOrigin, now: Date = Date()) -> Date {
        if origin == .agent {
            if aggregateDecisionDeadline > now { return aggregateDecisionDeadline }
            return now.addingTimeInterval(aiSettings.maximumDuration)
        }
        return now.addingTimeInterval(24 * 60 * 60)
    }

    /// After a write that reported failure we know nothing reliable about the
    /// flag — the write may still have landed. Go re-read it through the normal
    /// reconcile path rather than assigning `isEnabled` directly, so the token,
    /// baseline, and side effects all stay consistent.
    ///
    /// The baseline is dropped first so that read re-establishes it silently: if
    /// the flag did move, that was our own failed write, and blaming an external
    /// actor for it would be plainly wrong.
    private func recoverStateAfterFailedWrite() {
        // Resolve before re-reading: that read can adopt a state and ask auto mode
        // to reconcile, which must not turn into an immediate second attempt at
        // the write that just failed.
        autoWrite.resolved()
        hasConfirmedState = false
        refreshState()
    }

    /// The write reported success — read the flag back to see whether it landed.
    private func verifySetApplied(target: Bool) {
        let token = sync.beginRead()
        let observed = power.isSleepDisabled()
        guard sync.shouldApply(token) else { return }
        applyVerification(StateReconciler.verifyAfterSet(target: target, observed: observed),
                          target: target)
    }

    /// Verification never writes to `lastError`: it keeps its own channel so
    /// clearing a caveat can't wipe a safety note or a helper error.
    private func applyVerification(_ outcome: StateReconciler.VerifyOutcome, target: Bool) {
        // Whatever the outcome, auto mode's write is over. Resolving up front
        // matters most for `.mismatch`, where adopting the contradicting state
        // reconciles again: without this, that reconcile would dispatch a fresh
        // write, whose read-back could mismatch in turn, with no bound but the
        // stack. Deferring costs a tick and cannot loop.
        autoWrite.resolved()
        switch outcome {
        case .verified:
            pendingVerification = nil
            verificationNotice = nil
            hasConfirmedState = true
        case .unverified:
            // Keep `pendingVerification` — the next poll resolves it, and until
            // then the UI says plainly that the state isn't confirmed.
            verificationNotice = StateReconciler.unverifiedMessage(target: target)
        case .mismatch(let actual):
            pendingVerification = nil
            verificationNotice = StateReconciler.writeMismatchMessage(actual: actual)
            hasConfirmedState = true
            adoptSystemState(actual)
        }
    }

    /// Pop a blocking alert when a user-initiated toggle can't be applied, so the
    /// reason is impossible to miss. The inline `lastError` note still persists in
    /// the popover after the alert is dismissed.
    private func presentFailureAlert(target: Bool, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = target
            ? localized("Couldn’t keep your Mac awake", defaultValue: "Couldn’t keep your Mac awake")
            : localized("Couldn’t turn keep-awake off", defaultValue: "Couldn’t turn keep-awake off")
        alert.informativeText = localizePresentation(message)
        alert.addButton(withTitle: localized("OK", defaultValue: "OK"))
        alert.runModal()
    }

    /// The helper is registered but didn't respond — almost always a stale
    /// registration after an app update (launchd refuses to launch the new
    /// binary). Offer a one-click reinstall, which re-registers and refreshes
    /// that record.
    private func presentHelperFailureAlert(message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localized(
            "Couldn’t keep your Mac awake",
            defaultValue: "Couldn’t keep your Mac awake"
        )
        alert.informativeText = L10n.format(
            "helper.failure.reinstall_detail",
            defaultValue: "%@\n\nThis usually happens after an update. Reinstalling the background helper fixes it.",
            language: appLanguage,
            localizePresentation(message)
        )
        alert.addButton(withTitle: localized(
            "Reinstall Helper…",
            defaultValue: "Reinstall Helper…"
        ))
        alert.addButton(withTitle: localized("Cancel", defaultValue: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            repairHelper()
        }
    }

    /// Re-register the privileged helper to refresh launchd's record, then report
    /// the outcome. Used both automatically (after a detected app update) and from
    /// the failure alert's "Reinstall Helper" action.
    func repairHelper() {
        conditionalSleepRelease.cancel()
        guard !helperRepairInFlight else { return }
        helperRepairInFlight = true
        stopDisplayAwakeAssertion()
        guard store.saveHelperRegistrationRepairPending(true) else {
            helperRepairInFlight = false
            lastError = "Couldn’t persist the background-helper recovery marker; no registration was changed."
            manageHeartbeat()
            return
        }
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        helperHealthGeneration += 1
        helperRecoveryNotice = nil
        recoveryLeaseInspectionInFlight = false
        helper.reregister(leaseID: aggregateLeaseID) { [weak self] leaseIsClear, error in
            guard let self else { return }
            if leaseIsClear {
                if self.pendingAgentRecovery != nil {
                    self.discardPendingAgentRecovery(at: Date())
                }
                self.helperLeaseActive = false
                self.helperLeaseDeadline = .distantPast
                self.aggregateWakeRequested = false
                self.pendingVerification = nil
            }
            self.refreshHelperStatus()
            if let error {
                self.helperRepairInFlight = false
                self.setPresentationError(
                    .helperRepairFailed,
                    diagnostic: error.localizedDescription
                )
                self.manageHeartbeat()
            } else if self.helper.requiresApproval {
                self.helperRepairInFlight = false
                self.lastError = "Approve CodeWake in System Settings ▸ Login Items, then try the switch again."
                self.helper.openLoginItemsSettings()
            } else if !self.helperInstalled {
                self.helperRepairInFlight = false
                self.lastError = "The background helper registration is still unavailable and will retry next launch."
            } else {
                self.helper.checkCurrentVersion { [weak self] isCurrent, versionError in
                    guard let self else { return }
                    self.helperRepairInFlight = false
                    guard isCurrent else {
                        if let versionError {
                            self.setPresentationError(
                                .helperVersionCheckFailed,
                                diagnostic: versionError
                            )
                        } else {
                            self.lastError = "The replacement helper is not the current version; repair will retry next launch."
                        }
                        return
                    }
                    self.store.saveHelperRegistrationRepairPending(false)
                    self.storeCurrentHelperBuild()
                    self.lastError = "Background helper reinstalled — try the switch again."
                    self.resetSystemWakeFailure()
                    if leaseIsClear {
                        // Re-apply still-valid manual/charging/Agent intents only
                        // after the replacement helper is live. The old lease is
                        // already gone.
                        self.applyWakeDecision(origin: .user)
                    } else {
                        // The old helper was unreachable, so only the replacement
                        // root process can tell whether a journal survived. Adopt
                        // and release/heartbeat it before making a new lease claim.
                        self.inspectHelperLeaseHealth()
                    }
                }
            }
        }
    }

    private func resetSystemWakeFailure() {
        unexpectedDisableReassertionAttempted = false
        systemWakeUnavailable = false
        wakeArbiter.setSafetyVeto(.systemPowerState, active: false)
    }

    // MARK: Display assertion and Helper heartbeat

    /// Evaluate the pure display policy against current semantic work and the
    /// confirmed aggregate Helper state. This never mutates the Helper lease.
    private func reconcileDisplayAwake(now: Date = Date()) {
        let shouldHold = DisplayAwakePolicy.shouldKeepDisplayAwake(
            preferenceEnabled: keepDisplayAwakeDuringActivity,
            helperLeaseActive: helperLeaseActive,
            systemWakeEnabled: isEnabled,
            isRestoringOrQuitting: isRestoringNormalSleep
                || isQuitting
                || helperRepairInFlight,
            wakeDecision: wakeArbiter.decision,
            agentStates: agentMachine.allTurns(at: now),
            manualDisplaySleepActive: allDisplaysSleepSnapshot.suspendsDisplayAwake,
            now: now
        )
        applyDisplaySleepAssertionResult(
            displaySleepAssertion.reconcile(shouldHold: shouldHold)
        )
    }

    /// Called on the existing 30-second Helper heartbeat cadence. The IOKit
    /// assertion itself expires after 90 seconds, so a stalled or dead app can
    /// never leave an unbounded display hold behind.
    private func renewDisplayAwakeAssertion() {
        applyDisplaySleepAssertionResult(displaySleepAssertion.renewIfNeeded())
    }

    private func stopDisplayAwakeAssertion() {
        applyDisplaySleepAssertionResult(displaySleepAssertion.stop())
    }

    private func applyDisplaySleepAssertionResult(_ result: DisplaySleepAssertionResult) {
        switch result {
        case .failed(.createFailed):
            displayAwakeWarning =
                "Couldn’t keep the screen on. Mac keep-awake remains active."
        case .failed(.releaseFailed):
            displayAwakeWarning =
                "Couldn’t release the screen-on hold immediately. It will expire automatically."
        case .acquired, .renewed, .released:
            displayAwakeWarning = nil
        case .unchanged:
            // Preserve a bounded-retry warning until the controller records a
            // successful edge or proves there is no outstanding error.
            if displaySleepAssertion.lastError == nil {
                displayAwakeWarning = nil
            }
        }
    }

    private func manageHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        reconcileDisplayAwake(now: Date())
        guard !isRestoringNormalSleep else { return }
        guard helperLeaseActive, helperInstalled else { return }
        renewDisplayAwakeAssertion()
        helper.heartbeatLease(id: aggregateLeaseID) { [weak self] ok, error in
            self?.handleLeaseMaintenanceResult(ok: ok, error: error)
        }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.helperLeaseActive else { return }
                let now = Date()
                self.reconcileDisplayAwake(now: now)
                self.renewDisplayAwakeAssertion()
                if self.helperLeaseHasHardDeadline {
                    self.helper.heartbeatLease(id: self.aggregateLeaseID) { [weak self] ok, error in
                        self?.handleLeaseMaintenanceResult(ok: ok, error: error)
                    }
                } else {
                    let deadline = self.leaseDeadline(for: .user)
                    self.helperLeaseDeadline = deadline
                    self.helper.updateLease(id: self.aggregateLeaseID, notAfter: deadline) {
                        [weak self] ok, error in
                        self?.handleLeaseMaintenanceResult(ok: ok, error: error)
                    }
                }
            }
        }
    }

    /// launchd can restart the helper independently of the app. Startup recovery
    /// deliberately drops the old durable lease; a failed heartbeat/update is
    /// therefore also the app's signal to reacquire while an intent is still
    /// valid. Same-ID acquire is idempotent, so this is safe after a lost reply as
    /// well as after a real daemon restart.
    private func handleLeaseMaintenanceResult(ok: Bool, error: String?) {
        guard !isRestoringNormalSleep else { return }
        guard !ok, helperLeaseActive else { return }
        helperLeaseActive = false
        aggregateWakeRequested = false
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        if let error, !error.isEmpty {
            setPresentationError(
                .helperLeaseMaintenanceFailed,
                diagnostic: error
            )
        }
        applyWakeDecision(origin: .agent)
    }

    // MARK: Auto-off timer

    /// Arm when keep-awake turns on, cancel when it turns off.
    private func updateAutoOff(for enabled: Bool) {
        if !enabled { cancelAutoOff(reconcileWake: false) }
    }

    private func armAutoOff() {
        cancelAutoOff(reconcileWake: false)
        // Auto mode manages activation on its own; a countdown would disarm the
        // feature out from under it, so auto-off is inert while auto mode is on.
        guard autoOffMinutes > 0, !settings.autoEnableWhenCharging else { return }
        let deadline = AutoOff.deadline(from: Date(), minutes: autoOffMinutes)
        autoOffDeadline = deadline
        wakeArbiter.setIntent(.manualTimer, active: true)
        refreshAutoOffRemaining()
        // One repeating timer drives both the countdown label and the firing,
        // and only runs while a timer is actually armed.
        autoOffTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoOffTick() }
        }
        applyWakeDecision(origin: .user)
    }

    private func cancelAutoOff(reconcileWake: Bool = true) {
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        autoOffDeadline = nil
        autoOffRemaining = ""
        wakeArbiter.setIntent(.manualTimer, active: false)
        if reconcileWake { applyWakeDecision(origin: .autoOff) }
    }

    private func autoOffTick() {
        guard let deadline = autoOffDeadline else { return }
        if AutoOff.isExpired(deadline: deadline, now: Date()) {
            let minutes = autoOffMinutes
            cancelAutoOff(reconcileWake: false)
            lastError = "Auto-off: \(AutoOff.optionLabel(minutes: minutes)) elapsed."
            applyWakeDecision(origin: .autoOff)
        } else {
            refreshAutoOffRemaining()
        }
    }

    private func refreshAutoOffRemaining() {
        guard let deadline = autoOffDeadline else { autoOffRemaining = ""; return }
        autoOffRemaining = AutoOff.formatCountdown(AutoOff.remaining(deadline: deadline, now: Date()))
    }

    // MARK: Battery + safety guard

    func tick() {
        allDisplaysSleepController.refreshDisplayState()
        // Backstop for the didBecomeActive observer: catch a helper approval even
        // if the app never lost/regained active state.
        recheckHelper()
        // Advance auto mode's write claim. A concluded write reopens here — this
        // is where its retry comes from. One still outstanding does not: this tick
        // may be landing moments after the dispatch, and reopening would put a
        // second write alongside a live first. It reopens a tick later instead,
        // which also bounds how long a lost reply can hold the feature.
        autoWrite.advanceTick()
        // Reconcile with the real flag every tick, not only while enabled:
        // polling only when we think it's on would structurally miss the case
        // where it was turned on behind our back.
        refreshState()
        if settings.autoEnableWhenCharging {
            reconcile()             // refreshes the battery sample itself
        } else {
            refreshBattery()
            evaluateSafety()
        }
        // Configuration is external mutable state. This read-only periodic
        // refresh bounds drift even while Codex remains continuously active or
        // idle; it never installs or rewrites integrations in the background.
        refreshIntegrationHealth()
        refreshAgentProcesses()
    }

    func refreshBattery() {
        let info = battery.read()
        batteryPercent = info.percent
        batteryOnAC = info.onAC
        batteryDescription = "\(info.source) · \(info.percent)%"
    }

    /// Refresh the user-session topology on demand. The monitor also listens for
    /// AppKit screen-parameter changes; this explicit probe makes opening the
    /// popover a final freshness boundary after sleep, login, or a missed event.
    func refreshDisplayState() {
        allDisplaysSleepController.refreshDisplayState()
        _ = displayTopology.currentState()
    }
}
