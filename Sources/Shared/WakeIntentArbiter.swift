import Foundation

public enum WakeIntentSource: Hashable, Sendable {
    case manual
    case manualTimer
    case charging
    case agent(AgentSessionKey)
}

public enum WakeSafetyVeto: String, Codable, Hashable, Sendable {
    case thermal
    case lowBattery
    case powerPolicy
    case agentOnBattery
    /// The helper reported success but the global SleepDisabled flag repeatedly
    /// failed read-back. Blocks every source until a fresh explicit attempt.
    case systemPowerState
}

public enum WakeSafetyPolicy {
    /// Serious/critical thermal state is mandatory protection for AI work even
    /// if the legacy manual-mode thermal preference was switched off.
    public static func requiresThermalVeto(
        thermalSerious: Bool,
        userPauseEnabled: Bool,
        hasAgentWork: Bool
    ) -> Bool {
        thermalSerious && (userPauseEnabled || hasAgentWork)
    }
}

public struct WakeIntentDecision: Equatable, Sendable {
    public let shouldWake: Bool
    public let requestedSources: Set<WakeIntentSource>
    public let activeSources: Set<WakeIntentSource>
    public let vetoedSources: Set<WakeIntentSource>
    public let safetyVetoes: Set<WakeSafetyVeto>

    /// Presentation may claim an active Lidless hold only when the global flag,
    /// this app's durable Helper lease, and a currently permitted Lidless source
    /// all agree. A pre-existing hold owned by another tool must not turn a
    /// vetoed or failed Lidless request green.
    public func hasVerifiedActiveWakeHold(
        systemKeepAwake: Bool,
        helperLeaseActive: Bool
    ) -> Bool {
        systemKeepAwake && helperLeaseActive && !activeSources.isEmpty
    }
}

public struct WakeIntentArbiter: Equatable, Sendable {
    private var intents: Set<WakeIntentSource> = []
    private var vetoes: Set<WakeSafetyVeto> = []

    public init() {}

    public mutating func setIntent(_ source: WakeIntentSource, active: Bool) {
        if active { intents.insert(source) } else { intents.remove(source) }
    }

    /// Switching into charging automation transfers control away from both
    /// user-driven manual variants without disturbing independent Agent holds.
    public mutating func clearManualIntents() {
        intents.remove(.manual)
        intents.remove(.manualTimer)
    }

    /// Removes every wake request without weakening any active safety veto.
    public mutating func clearAllIntents() {
        intents.removeAll()
    }

    public mutating func setSafetyVeto(_ veto: WakeSafetyVeto, active: Bool) {
        if active { vetoes.insert(veto) } else { vetoes.remove(veto) }
    }

    public var decision: WakeIntentDecision {
        let permitted = vetoes.isEmpty
        return WakeIntentDecision(
            shouldWake: permitted && !intents.isEmpty,
            requestedSources: intents,
            activeSources: permitted ? intents : [],
            vetoedSources: permitted ? [] : intents,
            safetyVetoes: vetoes
        )
    }
}
