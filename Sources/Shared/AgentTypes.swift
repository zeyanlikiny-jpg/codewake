import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case codex
    case claudeCode = "claude"
    /// Adapter placeholder only. Lidless AI does not install Cursor hooks in v1.
    case cursor

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        }
    }
}

public struct AgentSessionKey: Hashable, Codable, Sendable {
    public let provider: AgentProvider
    public let sessionID: String

    public init(provider: AgentProvider, sessionID: String) {
        self.provider = provider
        self.sessionID = sessionID
    }
}

/// Stable, privacy-minimized identity for one agent turn. A Codex desktop
/// thread can run its root turn and multiple subagent turns under the same
/// session ID, so session identity alone is not an authoritative work unit.
public struct AgentTurnKey: Hashable, Codable, Sendable {
    public let provider: AgentProvider
    public let sessionID: String
    public let turnID: String

    public init(provider: AgentProvider, sessionID: String, turnID: String) {
        self.provider = provider
        self.sessionID = sessionID
        self.turnID = turnID
    }

    public var sessionKey: AgentSessionKey {
        AgentSessionKey(provider: provider, sessionID: sessionID)
    }
}

public enum AgentTurnRole: String, Codable, Equatable, Sendable {
    case primary
    case auxiliary
    case unknown
}

public enum AgentWaitingReason: String, Codable, Equatable, Sendable {
    case userInput
    case permission
    case planConfirmation
    case unknown
}

/// Content-free result of the latest state-machine ingest. This is safe to
/// expose in diagnostics because it contains no prompt, tool input, or path.
public enum AgentEventIngestDisposition: String, Codable, Equatable, Sendable {
    case accepted
    case duplicate
    case stale
    case invalid
    case tombstoned
    case missingTurn
    case hardExpired
}

public enum AgentEventKind: String, Codable, Sendable {
    case sessionStarted
    case processDiscovered
    case promptSubmitted
    case toolStarted
    case toolFinished
    case inputReceived
    case turnCompleted
    /// v1/v2 compatibility event. New bridges distinguish tool start/finish.
    case activity
    case waitingForInput
    case turnStopped
    case turnFailed
    case turnCancelled
    case backgroundWorkChanged
    case sessionEnded
    case processExited
}

/// Privacy-minimized event sent by the hook bridge. Date uses Unix epoch
/// seconds on the wire; Foundation's default Date encoding uses a different
/// epoch and is therefore deliberately not used.
public struct AgentEvent: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public let provider: AgentProvider
    public let sessionID: String
    public let turnID: String?
    public let eventKind: AgentEventKind
    public let waitingReason: AgentWaitingReason?
    /// v1 compatibility bit. v2 producers additionally send an absolute count
    /// at Stop and a stable opaque token for incremental background events.
    public let backgroundWork: Bool?
    public let backgroundWorkCount: Int?
    public let workToken: String?
    public let stopHookActive: Bool?
    public let timestamp: Date
    public let confirmed: Bool?

    public init(schemaVersion: Int = Self.currentSchemaVersion,
                provider: AgentProvider,
                sessionID: String,
                turnID: String? = nil,
                eventKind: AgentEventKind,
                waitingReason: AgentWaitingReason? = nil,
                backgroundWork: Bool? = nil,
                backgroundWorkCount: Int? = nil,
                workToken: String? = nil,
                stopHookActive: Bool? = nil,
                timestamp: Date,
                confirmed: Bool? = nil) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.sessionID = sessionID
        self.turnID = turnID
        self.eventKind = eventKind
        self.waitingReason = waitingReason
        self.backgroundWork = backgroundWork
        self.backgroundWorkCount = backgroundWorkCount
        self.workToken = workToken
        self.stopHookActive = stopHookActive
        self.timestamp = timestamp
        self.confirmed = confirmed
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, provider, sessionID, turnID, eventKind, waitingReason
        case backgroundWork, backgroundWorkCount, workToken, stopHookActive
        case timestamp, confirmed
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        provider = try values.decode(AgentProvider.self, forKey: .provider)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        turnID = try values.decodeIfPresent(String.self, forKey: .turnID)
        eventKind = try values.decode(AgentEventKind.self, forKey: .eventKind)
        waitingReason = try values.decodeIfPresent(AgentWaitingReason.self, forKey: .waitingReason)
        backgroundWork = try values.decodeIfPresent(Bool.self, forKey: .backgroundWork)
        backgroundWorkCount = try values.decodeIfPresent(Int.self, forKey: .backgroundWorkCount)
        workToken = try values.decodeIfPresent(String.self, forKey: .workToken)
        stopHookActive = try values.decodeIfPresent(Bool.self, forKey: .stopHookActive)
        let unixSeconds = try values.decode(Double.self, forKey: .timestamp)
        guard unixSeconds.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp, in: values, debugDescription: "timestamp must be finite"
            )
        }
        timestamp = Date(timeIntervalSince1970: unixSeconds)
        confirmed = try values.decodeIfPresent(Bool.self, forKey: .confirmed)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(provider, forKey: .provider)
        try values.encode(sessionID, forKey: .sessionID)
        try values.encodeIfPresent(turnID, forKey: .turnID)
        try values.encode(eventKind, forKey: .eventKind)
        try values.encodeIfPresent(waitingReason, forKey: .waitingReason)
        try values.encodeIfPresent(backgroundWork, forKey: .backgroundWork)
        try values.encodeIfPresent(backgroundWorkCount, forKey: .backgroundWorkCount)
        try values.encodeIfPresent(workToken, forKey: .workToken)
        try values.encodeIfPresent(stopHookActive, forKey: .stopHookActive)
        try values.encode(timestamp.timeIntervalSince1970, forKey: .timestamp)
        try values.encodeIfPresent(confirmed, forKey: .confirmed)
    }
}

public enum AgentSessionPhase: String, Codable, Equatable, Sendable {
    case unknown
    case working
    case waitingForInput
    case pendingCompletion
    /// v1 recovery-only phase. New Stop events use `pendingCompletion`.
    case turnStopped
    case finished
    case hardExpired
}

/// Why a non-working session will (or did) release its wake source. A normal
/// completion or an expired user-input wait can request conditional closed-lid
/// sleep; cancellations, failures, hard limits, and legacy releases restore
/// policy only.
public enum AgentTerminalDisposition: String, Codable, Equatable, Sendable {
    case none
    case successfulCompletion
    case failed
    case cancelled
    case waitingExpired
    case hardLimit
    case legacyRelease

    public var isSleepEligible: Bool {
        self == .successfulCompletion || self == .waitingExpired
    }
}

public struct AgentSessionState: Codable, Equatable, Sendable {
    public let key: AgentSessionKey
    public var turnRole: AgentTurnRole
    public var phase: AgentSessionPhase
    public var turnID: String?
    public var turnStartedAt: Date?
    public var hardDeadline: Date?
    public var lastActivityAt: Date?
    public var lastEventAt: Date
    public var graceDeadline: Date?
    public var backgroundWork: Bool
    /// Absolute, privacy-minimized number of background work items still live.
    public var backgroundWorkCount: Int
    /// Hash-derived opaque tokens make SubagentStart/Stop delivery idempotent
    /// without retaining raw agent IDs, commands, paths, or task content.
    public var backgroundWorkTokens: Set<String>
    /// Bounded tokens already stopped after an absolute snapshot. They prevent
    /// a duplicate stop delivery from decrementing the aggregate twice.
    public var completedBackgroundWorkTokens: Set<String>
    public var turnStopObserved: Bool
    /// A wait event can arrive while background work is still active. Remember
    /// it so the five-minute grace begins only after the final background task
    /// stops, rather than sleeping underneath that work.
    public var waitingObserved: Bool
    public var waitingReason: AgentWaitingReason?
    /// Start of the current wait grace. Kept separate from `lastEventAt` so a
    /// duplicate hook cannot extend the deadline when policy changes.
    public var waitingStartedAt: Date?
    /// Exact hook retries are common after a transient delivery failure. These
    /// two fields make a repeated boolean delta idempotent without retaining a
    /// private task/subagent identifier.
    public var lastBackgroundSignalAt: Date?
    public var lastBackgroundSignalValue: Bool?
    public var stopHookActive: Bool
    public var terminalDisposition: AgentTerminalDisposition

    public init(key: AgentSessionKey,
                turnRole: AgentTurnRole = .unknown,
                phase: AgentSessionPhase,
                turnID: String?,
                turnStartedAt: Date?,
                hardDeadline: Date?,
                lastActivityAt: Date?,
                lastEventAt: Date,
                graceDeadline: Date?,
                backgroundWork: Bool,
                backgroundWorkCount: Int,
                backgroundWorkTokens: Set<String> = [],
                completedBackgroundWorkTokens: Set<String> = [],
                turnStopObserved: Bool,
                waitingObserved: Bool,
                waitingReason: AgentWaitingReason? = nil,
                waitingStartedAt: Date? = nil,
                lastBackgroundSignalAt: Date?,
                lastBackgroundSignalValue: Bool?,
                stopHookActive: Bool = false,
                terminalDisposition: AgentTerminalDisposition = .none) {
        self.key = key
        self.turnRole = turnRole
        self.phase = phase
        self.turnID = turnID
        self.turnStartedAt = turnStartedAt
        self.hardDeadline = hardDeadline
        self.lastActivityAt = lastActivityAt
        self.lastEventAt = lastEventAt
        self.graceDeadline = graceDeadline
        self.backgroundWork = backgroundWork
        self.backgroundWorkCount = backgroundWorkCount
        self.backgroundWorkTokens = backgroundWorkTokens
        self.completedBackgroundWorkTokens = completedBackgroundWorkTokens
        self.turnStopObserved = turnStopObserved
        self.waitingObserved = waitingObserved
        self.waitingReason = waitingReason
        self.waitingStartedAt = waitingStartedAt
        self.lastBackgroundSignalAt = lastBackgroundSignalAt
        self.lastBackgroundSignalValue = lastBackgroundSignalValue
        self.stopHookActive = stopHookActive
        self.terminalDisposition = terminalDisposition
    }

    public var turnKey: AgentTurnKey? {
        turnID.map {
            AgentTurnKey(provider: key.provider, sessionID: key.sessionID, turnID: $0)
        }
    }

    public func effectivePhase(at now: Date) -> AgentSessionPhase {
        // An observed terminal remains authoritative. Policy updates may
        // recompute a historical deadline, but they must never relabel a
        // cancellation or failure as a hard-limit expiry later.
        if phase != .finished,
           let hardDeadline, now >= hardDeadline, turnID != nil { return .hardExpired }
        if (phase == .waitingForInput || phase == .pendingCompletion || phase == .turnStopped),
           let graceDeadline, now >= graceDeadline { return .finished }
        return phase
    }

    public func isWakeEligible(at now: Date) -> Bool {
        switch effectivePhase(at: now) {
        case .working, .waitingForInput, .pendingCompletion, .turnStopped:
            return true
        case .unknown, .finished, .hardExpired:
            return false
        }
    }

    public func wakeDeadline(at now: Date) -> Date? {
        guard isWakeEligible(at: now) else { return nil }
        if let graceDeadline,
           phase == .waitingForInput || phase == .pendingCompletion || phase == .turnStopped {
            return min(graceDeadline, hardDeadline ?? graceDeadline)
        }
        return hardDeadline
    }

    public func effectiveTerminalDisposition(at now: Date) -> AgentTerminalDisposition {
        switch effectivePhase(at: now) {
        case .hardExpired:
            return .hardLimit
        case .finished where terminalDisposition == .none:
            return phase == .waitingForInput ? .waitingExpired : .legacyRelease
        default:
            return terminalDisposition
        }
    }

    public func isSleepEligibleCompletion(at now: Date) -> Bool {
        isConditionalSleepEligibleTerminal(at: now)
    }

    public func isConditionalSleepEligibleTerminal(at now: Date) -> Bool {
        effectivePhase(at: now) == .finished
            && effectiveTerminalDisposition(at: now).isSleepEligible
    }

    private enum CodingKeys: String, CodingKey {
        case key, turnRole, phase, turnID, turnStartedAt, hardDeadline, lastActivityAt
        case lastEventAt, graceDeadline, backgroundWork, backgroundWorkCount
        case backgroundWorkTokens, completedBackgroundWorkTokens
        case turnStopObserved, waitingObserved, waitingReason, waitingStartedAt
        case lastBackgroundSignalAt, lastBackgroundSignalValue
        case stopHookActive, terminalDisposition
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPhase = try values.decode(AgentSessionPhase.self, forKey: .phase)
        let legacyDisposition: AgentTerminalDisposition
        switch decodedPhase {
        case .waitingForInput: legacyDisposition = .waitingExpired
        case .turnStopped: legacyDisposition = .legacyRelease
        case .hardExpired: legacyDisposition = .hardLimit
        default: legacyDisposition = .none
        }
        let legacyCount = try values.decodeIfPresent(Int.self, forKey: .backgroundWorkCount)
            ?? ((try values.decodeIfPresent(Bool.self, forKey: .backgroundWork)) == true ? 1 : 0)
        self.init(
            key: try values.decode(AgentSessionKey.self, forKey: .key),
            turnRole: try values.decodeIfPresent(AgentTurnRole.self, forKey: .turnRole)
                ?? .unknown,
            phase: decodedPhase,
            turnID: try values.decodeIfPresent(String.self, forKey: .turnID),
            turnStartedAt: try values.decodeIfPresent(Date.self, forKey: .turnStartedAt),
            hardDeadline: try values.decodeIfPresent(Date.self, forKey: .hardDeadline),
            lastActivityAt: try values.decodeIfPresent(Date.self, forKey: .lastActivityAt),
            lastEventAt: try values.decode(Date.self, forKey: .lastEventAt),
            graceDeadline: try values.decodeIfPresent(Date.self, forKey: .graceDeadline),
            backgroundWork: legacyCount > 0,
            backgroundWorkCount: legacyCount,
            backgroundWorkTokens: try values.decodeIfPresent(
                Set<String>.self, forKey: .backgroundWorkTokens
            ) ?? [],
            completedBackgroundWorkTokens: try values.decodeIfPresent(
                Set<String>.self, forKey: .completedBackgroundWorkTokens
            ) ?? [],
            turnStopObserved: try values.decodeIfPresent(Bool.self, forKey: .turnStopObserved)
                ?? false,
            waitingObserved: try values.decodeIfPresent(Bool.self, forKey: .waitingObserved)
                ?? false,
            waitingReason: try values.decodeIfPresent(
                AgentWaitingReason.self, forKey: .waitingReason
            ),
            waitingStartedAt: try values.decodeIfPresent(
                Date.self, forKey: .waitingStartedAt
            ) ?? (decodedPhase == .waitingForInput
                    ? (try values.decode(Date.self, forKey: .lastEventAt)) : nil),
            lastBackgroundSignalAt: try values.decodeIfPresent(
                Date.self, forKey: .lastBackgroundSignalAt
            ),
            lastBackgroundSignalValue: try values.decodeIfPresent(
                Bool.self, forKey: .lastBackgroundSignalValue
            ),
            stopHookActive: try values.decodeIfPresent(Bool.self, forKey: .stopHookActive)
                ?? false,
            terminalDisposition: try values.decodeIfPresent(
                AgentTerminalDisposition.self, forKey: .terminalDisposition
            ) ?? legacyDisposition
        )
    }
}

/// Privacy-minimized durable state used only to survive an app crash/relaunch.
/// It contains the same opaque IDs and lifecycle timestamps already accepted
/// from hooks, never prompts, paths, commands, output, or source content.
public enum AgentSessionTombstonePolicy: String, Codable, Equatable, Sendable {
    /// A normal lifecycle boundary may recover from a newer authoritative start
    /// when an earlier prompt hook was lost.
    case lifecycle
    /// The user explicitly restored normal sleep. Only a genuinely newer prompt
    /// may start another turn; delayed activity from the retired session cannot.
    case manualRestore
}

public struct AgentSessionTombstone: Codable, Equatable, Sendable {
    public let key: AgentSessionKey
    public let timestamp: Date
    public let turnID: String?
    public let policy: AgentSessionTombstonePolicy

    public init(key: AgentSessionKey,
                timestamp: Date,
                turnID: String?,
                policy: AgentSessionTombstonePolicy = .lifecycle) {
        self.key = key
        self.timestamp = timestamp
        self.turnID = turnID
        self.policy = policy
    }

    public var turnKey: AgentTurnKey? {
        turnID.map {
            AgentTurnKey(provider: key.provider, sessionID: key.sessionID, turnID: $0)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case key, timestamp, turnID, policy
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try values.decode(AgentSessionKey.self, forKey: .key),
            timestamp: try values.decode(Date.self, forKey: .timestamp),
            turnID: try values.decodeIfPresent(String.self, forKey: .turnID),
            policy: try values.decodeIfPresent(
                AgentSessionTombstonePolicy.self,
                forKey: .policy
            ) ?? .lifecycle
        )
    }
}

public struct AgentSessionAggregate: Equatable, Sendable {
    public let key: AgentSessionKey
    public let workingCount: Int
    public let waitingCount: Int
    public let pendingCompletionCount: Int
    public let visibleTurnCount: Int
    public let activeTurnCount: Int
    public let representativeState: AgentSessionState
}

public struct AgentStateRecoverySnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public let sessions: [AgentSessionState]
    public let tombstones: [AgentSessionTombstone]

    public init(schemaVersion: Int = Self.currentSchemaVersion,
                sessions: [AgentSessionState],
                tombstones: [AgentSessionTombstone]) {
        self.schemaVersion = schemaVersion
        self.sessions = sessions
        self.tombstones = tombstones
    }
}
