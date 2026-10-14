import Foundation

/// Runtime capabilities derived from the file-backed Codex integration health
/// plus the live socket server. Activity events and definitive idle evidence are
/// deliberately distinct: a third-party installer may temporarily reorder the
/// completion notify chain without invalidating fresh hook-delivered work.
struct CodexLifecycleChannelHealth: Equatable, Sendable {
    let activityEventsHealthy: Bool
    let idleEvidenceHealthy: Bool

    static let unavailable = CodexLifecycleChannelHealth(
        activityEventsHealthy: false,
        idleEvidenceHealthy: false
    )

    static func evaluate(
        integration: CodexIntegrationHealth,
        eventServerAvailable: Bool
    ) -> CodexLifecycleChannelHealth {
        let activityEventsHealthy = eventServerAvailable
            && integration.hookConfigurationState == .installed
            && integration.installedBridgeMatchesBundledSource
        return CodexLifecycleChannelHealth(
            activityEventsHealthy: activityEventsHealthy,
            idleEvidenceHealthy: activityEventsHealthy
                && integration.completionNotifyConfigurationState == .installed
        )
    }
}

/// Root-task counts used by the Codex status presentation. A root session is
/// counted once even when it contains several primary or auxiliary turns.
public struct CodexTaskSemanticDetails: Equatable, Sendable {
    public let workingCount: Int
    public let waitingCount: Int
    public let finishingCount: Int
    public let unknownCount: Int
    public let waitingReason: AgentWaitingReason?

    public init(
        workingCount: Int,
        waitingCount: Int,
        finishingCount: Int,
        unknownCount: Int,
        waitingReason: AgentWaitingReason?
    ) {
        self.workingCount = workingCount
        self.waitingCount = waitingCount
        self.finishingCount = finishingCount
        self.unknownCount = unknownCount
        self.waitingReason = waitingReason
    }

    public var activeTaskCount: Int {
        workingCount + waitingCount + finishingCount
    }

    public var taskCount: Int {
        activeTaskCount + unknownCount
    }
}

/// Content-free Codex task semantics derived exclusively from lifecycle state.
/// Process presence and CPU usage are intentionally not inputs: a resident
/// Codex process can be idle, and a working task can consume no CPU while a tool
/// or remote service is running.
public enum CodexTaskSemanticStatus: Equatable, Sendable {
    case working(CodexTaskSemanticDetails)
    case waiting(CodexTaskSemanticDetails)
    case finishing(CodexTaskSemanticDetails)
    case idle
    case unknown(CodexTaskSemanticDetails)

    /// Reduces turn-level states to root-task semantics. Within one root task,
    /// the most active turn wins: working, then waiting, finishing, and unknown.
    /// Finished and hard-expired tasks are idle and are not counted.
    public static func summarize(
        sessions: [AgentSessionState],
        at now: Date
    ) -> CodexTaskSemanticStatus {
        let codexSessions = Dictionary(grouping: sessions.lazy.filter {
            $0.key.provider == .codex
        }, by: \AgentSessionState.key)

        var workingCount = 0
        var waitingCount = 0
        var finishingCount = 0
        var unknownCount = 0
        var waitingReasons: [AgentWaitingReason] = []

        for states in codexSessions.values {
            let effectiveStates = states.map { state in
                (state: state, phase: state.effectivePhase(at: now))
            }
            if effectiveStates.contains(where: { $0.phase == .working }) {
                workingCount += 1
                continue
            }

            let waitingStates = effectiveStates.filter { $0.phase == .waitingForInput }
            if !waitingStates.isEmpty {
                waitingCount += 1
                waitingReasons.append(Self.waitingReason(for: waitingStates.map(\.state)))
                continue
            }

            if effectiveStates.contains(where: {
                $0.phase == .pendingCompletion || $0.phase == .turnStopped
            }) {
                finishingCount += 1
                continue
            }

            if effectiveStates.contains(where: { $0.phase == .unknown }) {
                unknownCount += 1
            }
        }

        let details = CodexTaskSemanticDetails(
            workingCount: workingCount,
            waitingCount: waitingCount,
            finishingCount: finishingCount,
            unknownCount: unknownCount,
            waitingReason: Self.mergedWaitingReason(waitingReasons)
        )
        if workingCount > 0 { return .working(details) }
        if waitingCount > 0 { return .waiting(details) }
        if finishingCount > 0 { return .finishing(details) }
        if unknownCount > 0 { return .unknown(details) }
        return .idle
    }

    public var details: CodexTaskSemanticDetails {
        switch self {
        case let .working(details), let .waiting(details),
             let .finishing(details), let .unknown(details):
            return details
        case .idle:
            return CodexTaskSemanticDetails(
                workingCount: 0,
                waitingCount: 0,
                finishingCount: 0,
                unknownCount: 0,
                waitingReason: nil
            )
        }
    }

    /// Converts lifecycle state into a claim safe for the manual status view.
    /// Positive state is current only while its delivery channel is healthy.
    /// An empty state additionally requires a successful process scan and proof
    /// that the completion relay is canonical and every currently detected Codex
    /// process has emitted a lifecycle event; otherwise absence of events cannot
    /// prove that no task exists.
    func validatedForPresentation(
        lifecycleChannelHealth: CodexLifecycleChannelHealth,
        processScanSucceeded: Bool,
        allDetectedProcessesObserved: Bool
    ) -> CodexTaskSemanticStatus {
        guard lifecycleChannelHealth.activityEventsHealthy else {
            return .unknown(details)
        }
        switch self {
        case .working, .waiting, .finishing, .unknown:
            return self
        case .idle:
            return lifecycleChannelHealth.idleEvidenceHealthy
                && processScanSucceeded && allDetectedProcessesObserved
                ? .idle : .unknown(details)
        }
    }

    private static func waitingReason(for states: [AgentSessionState]) -> AgentWaitingReason {
        mergedWaitingReason(states.map { $0.waitingReason ?? .unknown }) ?? .unknown
    }

    private static func mergedWaitingReason(
        _ reasons: [AgentWaitingReason]
    ) -> AgentWaitingReason? {
        guard let first = reasons.first else { return nil }
        return reasons.dropFirst().allSatisfy { $0 == first } ? first : .unknown
    }
}

/// Presentation-only state for the menu-bar icon. Codex colors deliberately
/// consume health-validated semantics rather than process presence or raw
/// lifecycle counts. A separately verified manual hold may still claim green
/// while Codex is idle or unknown.
enum MenuBarIconPresentation: Equatable, Sendable {
    case normal
    case manualActive
    case working
    case attention

    static func resolve(
        isKeepAwakeActive: Bool,
        isManualKeepAwakeActive: Bool,
        codexStatus: CodexTaskSemanticStatus?
    ) -> MenuBarIconPresentation {
        guard isKeepAwakeActive else { return .normal }

        if let codexStatus {
            switch codexStatus {
            case .waiting, .finishing:
                return .attention
            case .working(let details):
                // Attention wins when several root tasks are in different phases.
                if details.waitingCount > 0 || details.finishingCount > 0 {
                    return .attention
                }
                // Codex green still requires every known root task to be working.
                if details.workingCount > 0 && details.unknownCount == 0 {
                    return .working
                }
            case .idle, .unknown:
                break
            }
        }

        return isManualKeepAwakeActive ? .manualActive : .normal
    }
}

/// Framework-neutral semantic color used by the menu status row. Manual holds
/// color the menu-bar logo but do not claim that an Agent task is working.
enum AgentStatusColorRole: Equatable, Sendable {
    case neutral
    case working
    case attention

    static func resolve(
        for presentation: MenuBarIconPresentation
    ) -> AgentStatusColorRole {
        switch presentation {
        case .working:
            return .working
        case .attention:
            return .attention
        case .normal, .manualActive:
            return .neutral
        }
    }
}
