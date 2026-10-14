import Foundation

public enum AgentSleepReleaseBlocker: Hashable, Sendable {
    case manual
    case timer
    case charging
    case safety
}

public enum AgentSleepReleaseDecision: Equatable, Sendable {
    /// There was no final, successful agent-source transition in this exact
    /// reconciliation pass. A later manual release must stay in this state and
    /// may never replay an older AI completion.
    case noTrigger
    /// The final successful completion may use the helper's atomic release and
    /// closed-lid sleep transaction.
    case requestSleep
    /// The completion was consumed, but an independent wake source or veto won.
    /// The app can explain the blocker without saving a deferred sleep request.
    case blocked(Set<AgentSleepReleaseBlocker>)
}

public enum AgentSleepReleasePolicy {
    public static func evaluate(
        previousAgentKeys: Set<AgentSessionKey>,
        currentAgentKeys: Set<AgentSessionKey>,
        previousAgentTurnKeys: Set<AgentTurnKey>,
        currentAgentTurnKeys: Set<AgentTurnKey>,
        sessionStates: [AgentSessionState],
        requestedWakeSources: Set<WakeIntentSource>,
        safetyVetoes: Set<WakeSafetyVeto>,
        now: Date
    ) -> AgentSleepReleaseDecision {
        guard !previousAgentKeys.isEmpty, currentAgentKeys.isEmpty else {
            return .noTrigger
        }

        let removedKeys = previousAgentKeys.subtracting(currentAgentKeys)
        guard removedKeys == previousAgentKeys else { return .noTrigger }
        let removedTurnKeys = previousAgentTurnKeys.subtracting(currentAgentTurnKeys)
        guard !removedTurnKeys.isEmpty,
              currentAgentTurnKeys.isEmpty,
              removedTurnKeys == previousAgentTurnKeys else { return .noTrigger }
        let stateByTurnKey = Dictionary(uniqueKeysWithValues: sessionStates.compactMap { state in
            state.turnKey.map { ($0, state) }
        })
        // Only an explicitly sleep-eligible terminal can request conditional
        // sleep. In particular, cancellation is a policy-only release even
        // when it is the final Agent turn removed in this reconciliation pass.
        guard removedTurnKeys.allSatisfy({ key in
            stateByTurnKey[key]?.isConditionalSleepEligibleTerminal(at: now) == true
        }) else {
            return .noTrigger
        }

        var blockers: Set<AgentSleepReleaseBlocker> = []
        if requestedWakeSources.contains(.manual) { blockers.insert(.manual) }
        if requestedWakeSources.contains(.manualTimer) { blockers.insert(.timer) }
        if requestedWakeSources.contains(.charging) { blockers.insert(.charging) }
        if !safetyVetoes.isEmpty { blockers.insert(.safety) }
        return blockers.isEmpty ? .requestSleep : .blocked(blockers)
    }
}
