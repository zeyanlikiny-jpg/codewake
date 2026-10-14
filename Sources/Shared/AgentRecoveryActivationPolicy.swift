import Foundation

/// Selects provisional crash-recovery state that a fresh lifecycle event is
/// authoritative enough to reactivate. Terminal and observation-only events
/// must never revive a pre-crash wake source.
public enum AgentRecoveryActivationPolicy {
    public static func matchingStates(
        in recovery: AgentStateRecoverySnapshot,
        for event: AgentEvent
    ) -> [AgentSessionState] {
        switch event.eventKind {
        case .promptSubmitted, .toolStarted, .inputReceived:
            break
        case .toolFinished, .turnCompleted, .activity, .waitingForInput,
                .turnStopped, .turnFailed, .turnCancelled, .backgroundWorkChanged,
                .sessionStarted, .sessionEnded, .processDiscovered, .processExited:
            return []
        }

        if let turnID = event.turnID {
            let turnKey = AgentTurnKey(
                provider: event.provider,
                sessionID: event.sessionID,
                turnID: turnID
            )
            return recovery.sessions.filter {
                $0.turnKey == turnKey && event.timestamp >= $0.lastEventAt
            }
        }

        // A session/process observation does not prove that any specific turn
        // is still working. Without a turn ID, recovery must stay provisional
        // until the live helper lease proves continuity or an exact turn start
        // arrives.
        return []
    }
}
