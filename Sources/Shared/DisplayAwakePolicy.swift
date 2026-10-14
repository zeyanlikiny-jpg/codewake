import Foundation

/// Pure policy for the app-owned display-sleep assertion.
///
/// The helper's durable aggregate lease remains the source of truth for system
/// wake. A display assertion is therefore only eligible after that lease and
/// its read-back state are both live. Waiting and completion-confirmation
/// phases deliberately retain the helper lease without retaining the display.
public enum DisplayAwakePolicy {
    public static func shouldKeepDisplayAwake(
        preferenceEnabled: Bool,
        helperLeaseActive: Bool,
        systemWakeEnabled: Bool,
        isRestoringOrQuitting: Bool,
        wakeDecision: WakeIntentDecision,
        agentStates: [AgentSessionState],
        manualDisplaySleepActive: Bool = false,
        now: Date = Date()
    ) -> Bool {
        guard preferenceEnabled,
              helperLeaseActive,
              systemWakeEnabled,
              !isRestoringOrQuitting,
              !manualDisplaySleepActive,
              wakeDecision.shouldWake else {
            return false
        }

        if wakeDecision.activeSources.contains(.manual)
            || wakeDecision.activeSources.contains(.manualTimer) {
            return true
        }

        let workingAgentSessions = Set(agentStates.compactMap { state in
            state.effectivePhase(at: now) == .working ? state.key : nil
        })
        guard !workingAgentSessions.isEmpty else { return false }

        return wakeDecision.activeSources.contains { source in
            guard case .agent(let key) = source else { return false }
            return workingAgentSessions.contains(key)
        }
    }
}
