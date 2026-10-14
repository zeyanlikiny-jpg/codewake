import Foundation

/// Deterministic lifecycle state machine. Each authoritative work unit is a
/// provider/session/turn tuple. Session-level APIs remain available so wake
/// arbitration can continue to hold one source per root session.
public struct AgentStateMachine: Sendable {
    public static let defaultMaximumTurnDuration: TimeInterval = 4 * 60 * 60
    public static let defaultCompletionConfirmation: TimeInterval = 5
    public static let defaultWaitingGrace: TimeInterval = 5 * 60
    public static let defaultReleaseGrace: TimeInterval = defaultWaitingGrace
    private static let tombstoneRetention: TimeInterval = 24 * 60 * 60
    private static let maximumTombstoneCount = 256

    private struct Tombstone: Sendable {
        let timestamp: Date
        let policy: AgentSessionTombstonePolicy

        init(timestamp: Date,
             policy: AgentSessionTombstonePolicy = .lifecycle) {
            self.timestamp = timestamp
            self.policy = policy
        }
    }

    private enum TombstoneIdentity: Hashable, Sendable {
        case turn(AgentTurnKey)
        case session(AgentSessionKey)
    }

    private var turns: [AgentTurnKey: AgentSessionState] = [:]
    private var placeholders: [AgentSessionKey: AgentSessionState] = [:]
    private var turnTombstones: [AgentTurnKey: Tombstone] = [:]
    private var sessionTombstones: [AgentSessionKey: Tombstone] = [:]
    private var primaryTurns: [AgentSessionKey: AgentTurnKey] = [:]

    private(set) public var maximumTurnDuration: TimeInterval
    private(set) public var completionConfirmation: TimeInterval
    private(set) public var waitingGrace: TimeInterval
    private(set) public var lastIngestDisposition: AgentEventIngestDisposition = .accepted

    public init(maximumTurnDuration: TimeInterval = Self.defaultMaximumTurnDuration,
                completionConfirmation: TimeInterval = Self.defaultCompletionConfirmation,
                waitingGrace: TimeInterval = Self.defaultWaitingGrace) {
        self.maximumTurnDuration = max(1, maximumTurnDuration)
        self.completionConfirmation = max(0, completionConfirmation)
        self.waitingGrace = max(0, waitingGrace)
    }

    /// Source-compatible v0.1 initializer.
    public init(maximumTurnDuration: TimeInterval, releaseGrace: TimeInterval) {
        self.init(maximumTurnDuration: maximumTurnDuration,
                  completionConfirmation: releaseGrace,
                  waitingGrace: releaseGrace)
    }

    public mutating func updatePolicy(maximumTurnDuration: TimeInterval,
                                      completionConfirmation: TimeInterval,
                                      waitingGrace: TimeInterval) {
        self.maximumTurnDuration = max(1, maximumTurnDuration)
        self.completionConfirmation = max(0, completionConfirmation)
        self.waitingGrace = max(0, waitingGrace)
        for key in turns.keys {
            guard var state = turns[key] else { continue }
            if let started = state.turnStartedAt {
                let proposed = started.addingTimeInterval(self.maximumTurnDuration)
                state.hardDeadline = min(state.hardDeadline ?? proposed, proposed)
            }
            if state.phase == .waitingForInput {
                state.graceDeadline = (state.waitingStartedAt ?? state.lastEventAt)
                    .addingTimeInterval(self.waitingGrace)
            } else if state.phase == .pendingCompletion {
                let proposed = state.lastEventAt.addingTimeInterval(self.completionConfirmation)
                state.graceDeadline = min(state.graceDeadline ?? proposed, proposed)
            }
            turns[key] = state
        }
    }

    public mutating func updatePolicy(maximumTurnDuration: TimeInterval,
                                      releaseGrace: TimeInterval) {
        updatePolicy(maximumTurnDuration: maximumTurnDuration,
                     completionConfirmation: releaseGrace,
                     waitingGrace: releaseGrace)
    }

    /// Content-free diagnostic result can be shown without retaining prompts,
    /// tool input, output, or filesystem paths.
    @discardableResult
    public mutating func ingest(_ event: AgentEvent) -> AgentEventIngestDisposition {
        guard (event.schemaVersion == 1
                || event.schemaVersion == 2
                || event.schemaVersion == AgentEvent.currentSchemaVersion),
              isSafeIdentifier(event.sessionID),
              event.turnID.map(isSafeIdentifier) ?? true,
              event.workToken.map(isSafeWorkToken) ?? true,
              event.backgroundWorkCount.map({ (0...1_024).contains($0) }) ?? true,
              isFinite(event.timestamp) else { return finishIngest(.invalid) }

        pruneTombstones(at: event.timestamp)
        let sessionKey = AgentSessionKey(provider: event.provider, sessionID: event.sessionID)
        if event.eventKind == .turnCancelled {
            // Cancellation is an authoritative, exact-turn terminal from the
            // Codex rollout reconciler. Process it before ordinary event
            // ordering so a hook delivered just after the user's interrupt
            // cannot keep the turn alive. A missing turn ID must never fall
            // back to a primary or synthetic turn and cancel unrelated work.
            guard let turnID = event.turnID, !turnID.isEmpty else {
                return finishIngest(.missingTurn)
            }
            let turnKey = AgentTurnKey(provider: event.provider,
                                       sessionID: event.sessionID,
                                       turnID: turnID)
            if turnTombstones[turnKey] != nil {
                return finishIngest(.tombstoned)
            }

            let terminalTimestamp = max(
                event.timestamp,
                turns[turnKey]?.lastEventAt ?? .distantPast
            )
            if var current = turns[turnKey] {
                current.phase = .finished
                current.hardDeadline = nil
                current.lastEventAt = terminalTimestamp
                current.graceDeadline = nil
                current.backgroundWork = false
                current.backgroundWorkCount = 0
                current.backgroundWorkTokens.removeAll()
                current.completedBackgroundWorkTokens.removeAll()
                current.turnStopObserved = true
                current.waitingObserved = false
                current.waitingReason = nil
                current.waitingStartedAt = nil
                current.lastBackgroundSignalAt = nil
                current.lastBackgroundSignalValue = nil
                current.stopHookActive = false
                current.terminalDisposition = .cancelled
                turns[turnKey] = current
            } else if primaryTurns[sessionKey] == turnKey {
                primaryTurns.removeValue(forKey: sessionKey)
            }
            turnTombstones[turnKey] = Tombstone(timestamp: terminalTimestamp)
            pruneTombstones(at: terminalTimestamp)
            return finishIngest(.accepted)
        }

        if event.eventKind == .sessionEnded
            || (event.eventKind == .processExited && event.confirmed == true) {
            let newest = states(for: sessionKey).map(\.lastEventAt).max()
                ?? placeholders[sessionKey]?.lastEventAt ?? .distantPast
            guard event.timestamp >= newest else { return finishIngest(.stale) }
            for turnKey in turns.keys where turnKey.sessionKey == sessionKey {
                turnTombstones[turnKey] = Tombstone(timestamp: event.timestamp)
            }
            turns = turns.filter { $0.key.sessionKey != sessionKey }
            placeholders.removeValue(forKey: sessionKey)
            primaryTurns.removeValue(forKey: sessionKey)
            let existing = sessionTombstones[sessionKey]
            sessionTombstones[sessionKey] = Tombstone(
                timestamp: max(event.timestamp, existing?.timestamp ?? .distantPast),
                // A delayed terminal event confirms that the old session ended;
                // it must not weaken the user's stronger manual-release boundary.
                policy: existing?.policy == .manualRestore ? .manualRestore : .lifecycle
            )
            pruneTombstones(at: event.timestamp)
            return finishIngest(.accepted)
        }
        if event.eventKind == .processExited { return finishIngest(.duplicate) }

        if event.eventKind == .sessionStarted || event.eventKind == .processDiscovered {
            if let tombstone = sessionTombstones[sessionKey] {
                // Process presence is diagnostic, not proof of new semantic
                // work. In particular it must not repopulate a placeholder
                // after the user explicitly restored normal sleep.
                if tombstone.policy == .manualRestore
                    || event.timestamp <= tombstone.timestamp {
                    return finishIngest(.tombstoned)
                }
            }
            if !states(for: sessionKey).isEmpty { return finishIngest(.duplicate) }
            if let existing = placeholders[sessionKey], event.timestamp < existing.lastEventAt {
                return finishIngest(.stale)
            }
            placeholders[sessionKey] = emptyState(sessionKey: sessionKey,
                                                  timestamp: event.timestamp,
                                                  turnID: nil,
                                                  role: .unknown)
            return finishIngest(.accepted)
        }

        guard let resolvedTurnID = resolveTurnID(for: event, sessionKey: sessionKey) else {
            return finishIngest(.missingTurn)
        }
        let turnKey = AgentTurnKey(provider: event.provider,
                                   sessionID: event.sessionID,
                                   turnID: resolvedTurnID)
        let isLegacyActivity = event.eventKind == .activity
            && event.schemaVersion < AgentEvent.currentSchemaVersion

        // A manual end or an earlier terminal snapshot owns this exact turn
        // forever. Check it before reopening a session tombstone so a delayed
        // event for the old turn cannot weaken the session boundary.
        if turnTombstones[turnKey] != nil { return finishIngest(.tombstoned) }
        if let tombstone = sessionTombstones[sessionKey] {
            let isNewer = event.timestamp > tombstone.timestamp
            let canStartAfterEnd: Bool
            switch tombstone.policy {
            case .manualRestore:
                // Emergency restore is intentionally stricter than ordinary
                // crash recovery: an explicit prompt with a non-tombstoned turn
                // is the only proof that the user started new work.
                canStartAfterEnd = isNewer && event.eventKind == .promptSubmitted
            case .lifecycle:
                canStartAfterEnd = isNewer
                    && (event.eventKind == .promptSubmitted
                        || event.eventKind == .toolStarted
                        || (event.eventKind == .activity
                            && !isLegacyActivity
                            && event.confirmed != false))
            }
            guard canStartAfterEnd else { return finishIngest(.tombstoned) }
            sessionTombstones.removeValue(forKey: sessionKey)
        }
        // v1/v2 used one ambiguous `activity` event for several lifecycle
        // edges. It is safe only as a timestamp refresh for a known turn; it
        // cannot establish new work after a rolling bridge upgrade.
        if isLegacyActivity, turns[turnKey] == nil {
            return finishIngest(.missingTurn)
        }
        placeholders.removeValue(forKey: sessionKey)
        var state = turns[turnKey]

        if event.eventKind == .promptSubmitted {
            if let previousPrimary = primaryTurns[sessionKey], previousPrimary != turnKey,
               let previous = turns[previousPrimary], event.timestamp < previous.lastEventAt {
                return finishIngest(.stale)
            }
            if let previousPrimary = primaryTurns[sessionKey], previousPrimary != turnKey,
               let previous = turns[previousPrimary], !previous.backgroundWork {
                // A new user turn supersedes only the previous primary. Remove
                // it behind a per-turn tombstone so delayed Stop/PostToolUse or
                // notify delivery cannot resurrect a ghost task. Independently
                // keyed auxiliary turns remain untouched.
                turns.removeValue(forKey: previousPrimary)
                turnTombstones[previousPrimary] = Tombstone(timestamp: event.timestamp)
                pruneTombstones(at: event.timestamp)
            }
            primaryTurns[sessionKey] = turnKey
        }

        // CPU evidence is diagnostic only and never changes semantic phase or
        // ordering. It also cannot create a turn.
        if event.eventKind == .activity, event.confirmed == false {
            guard var diagnostic = state else { return finishIngest(.missingTurn) }
            diagnostic.lastActivityAt = max(diagnostic.lastActivityAt ?? .distantPast,
                                            event.timestamp)
            turns[turnKey] = diagnostic
            return finishIngest(.accepted)
        }

        let stateWasCreated = state == nil
        if state == nil {
            switch event.eventKind {
            case .toolFinished:
                return finishIngest(.missingTurn)
            case .inputReceived, .promptSubmitted, .toolStarted, .activity,
                    .waitingForInput, .turnCompleted, .turnStopped, .turnFailed,
                    .backgroundWorkChanged:
                if event.eventKind == .backgroundWorkChanged, event.backgroundWork != true {
                    return finishIngest(.missingTurn)
                }
                var recovered = emptyState(sessionKey: sessionKey,
                                           timestamp: event.timestamp,
                                           turnID: resolvedTurnID,
                                           role: event.eventKind == .promptSubmitted
                                                ? .primary : .auxiliary)
                beginRecoveredTurn(&recovered, from: event, turnID: resolvedTurnID)
                state = recovered
            case .turnCancelled, .sessionStarted, .processDiscovered,
                    .sessionEnded, .processExited:
                return finishIngest(.missingTurn)
            }
        }
        guard var current = state else { return finishIngest(.missingTurn) }
        if event.eventKind == .promptSubmitted { current.turnRole = .primary }
        if event.timestamp < current.lastEventAt { return finishIngest(.stale) }
        if isHardExpired(current, at: event.timestamp) {
            current.phase = .hardExpired
            current.terminalDisposition = .hardLimit
            turns[turnKey] = current
            return finishIngest(.hardExpired)
        }

        var disposition: AgentEventIngestDisposition = .accepted
        switch event.eventKind {
        case .promptSubmitted:
            if !stateWasCreated, event.timestamp == current.lastEventAt, current.phase == .working,
               current.turnStartedAt != nil {
                disposition = .duplicate
            } else {
                resumeWorking(&current, at: event.timestamp)
            }

        case .toolStarted:
            resumeWorking(&current, at: event.timestamp)

        case .activity:
            if isLegacyActivity {
                // A legacy activity can refresh an already-working turn, but
                // cannot turn waiting/completed state back into Working.
                if current.phase == .working {
                    current.lastActivityAt = max(current.lastActivityAt ?? .distantPast,
                                                 event.timestamp)
                    current.lastEventAt = event.timestamp
                } else {
                    disposition = .duplicate
                }
            } else {
                resumeWorking(&current, at: event.timestamp)
            }

        case .toolFinished:
            // A late PostToolUse may update an actively-working turn, but it
            // cannot resurrect waiting or terminal state.
            if current.phase == .working {
                current.lastActivityAt = max(current.lastActivityAt ?? .distantPast,
                                             event.timestamp)
                current.lastEventAt = event.timestamp
            } else {
                disposition = .duplicate
            }

        case .inputReceived:
            let wasWaiting = current.waitingObserved
                || current.phase == .waitingForInput
                || current.terminalDisposition == .waitingExpired
            if wasWaiting {
                resumeWorking(&current, at: event.timestamp)
            } else if current.phase == .working {
                current.lastActivityAt = max(current.lastActivityAt ?? .distantPast,
                                             event.timestamp)
                current.lastEventAt = event.timestamp
            } else {
                disposition = .duplicate
            }

        case .waitingForInput:
            // The Codex notify relay can identify a plan after an ordinary Stop
            // hook has already started the five-second completion window. Its
            // later authoritative wait must replace that pending completion.
            if current.phase == .finished && current.terminalDisposition == .failed {
                disposition = .duplicate
            } else {
                let proposed = event.timestamp.addingTimeInterval(waitingGrace)
                let duplicateWait = current.waitingObserved
                    && current.phase == .waitingForInput
                current.lastEventAt = max(current.lastEventAt, event.timestamp)
                current.turnStopObserved = false
                current.waitingObserved = true
                current.waitingReason = event.waitingReason
                    ?? current.waitingReason ?? .unknown
                current.stopHookActive = false
                // v1/v2 cannot prove that a wait came from the v3 notify
                // relay's exact plan/input protocol. Preserve the wait and
                // its configured delay, but make its eventual release
                // policy-only so an upgraded app can never force sleep from
                // legacy evidence.
                if event.schemaVersion < AgentEvent.currentSchemaVersion
                    || current.terminalDisposition == .legacyRelease {
                    current.terminalDisposition = .legacyRelease
                } else {
                    current.terminalDisposition = .waitingExpired
                }
                if current.backgroundWork {
                    current.graceDeadline = nil
                    current.waitingStartedAt = nil
                    current.phase = .working
                } else {
                    if !duplicateWait { current.waitingStartedAt = event.timestamp }
                    let anchored = (current.waitingStartedAt ?? event.timestamp)
                        .addingTimeInterval(waitingGrace)
                    current.graceDeadline = duplicateWait
                        ? min(current.graceDeadline ?? anchored, anchored) : proposed
                    current.phase = .waitingForInput
                }
                if duplicateWait { disposition = .duplicate }
            }

        case .turnCompleted, .turnStopped:
            if current.phase == .finished, current.terminalDisposition == .failed {
                current.stopHookActive = event.stopHookActive ?? current.stopHookActive
                disposition = .duplicate
            } else {
                let stopAlreadyObserved = current.turnStopObserved
                let waitingWasObserved = current.waitingObserved
                current.lastEventAt = max(current.lastEventAt, event.timestamp)
                current.turnStopObserved = !waitingWasObserved
                current.stopHookActive = event.stopHookActive ?? current.stopHookActive
                if waitingWasObserved {
                    if event.schemaVersion < AgentEvent.currentSchemaVersion
                        || current.terminalDisposition == .legacyRelease {
                        current.terminalDisposition = .legacyRelease
                    } else {
                        current.terminalDisposition = .waitingExpired
                    }
                } else if event.eventKind == .turnStopped
                            || event.schemaVersion < AgentEvent.currentSchemaVersion
                            || current.terminalDisposition == .legacyRelease {
                    current.terminalDisposition = .legacyRelease
                } else {
                    current.terminalDisposition = .successfulCompletion
                }
                applyBackgroundSnapshot(from: event,
                                        to: &current,
                                        allowCountIncrease: !stopAlreadyObserved)
                if current.backgroundWork {
                    current.graceDeadline = nil
                    current.phase = .working
                } else if waitingWasObserved {
                    beginWaitingRelease(&current, at: event.timestamp)
                } else if current.terminalDisposition == .legacyRelease {
                    beginLegacyRelease(&current, at: event.timestamp)
                } else {
                    beginPendingCompletion(&current, at: event.timestamp)
                }
                if stopAlreadyObserved { disposition = .duplicate }
            }

        case .turnFailed:
            current.lastEventAt = max(current.lastEventAt, event.timestamp)
            current.graceDeadline = nil
            current.backgroundWork = false
            current.backgroundWorkCount = 0
            current.backgroundWorkTokens.removeAll()
            current.completedBackgroundWorkTokens.removeAll()
            current.turnStopObserved = true
            current.waitingObserved = false
            current.waitingReason = nil
            current.waitingStartedAt = nil
            current.stopHookActive = event.stopHookActive ?? false
            current.terminalDisposition = .failed
            current.phase = .finished

        case .backgroundWorkChanged:
            if current.phase == .finished, current.terminalDisposition == .failed {
                // A failed terminal is authoritative. Late SubagentStop hooks
                // are common during teardown and must never upgrade failure to
                // a successful, sleep-eligible completion.
                disposition = .duplicate
            } else {
                guard applyBackgroundDelta(from: event, to: &current) else {
                    turns[turnKey] = current
                    return finishIngest(.duplicate)
                }
                current.lastEventAt = max(current.lastEventAt, event.timestamp)
                if current.backgroundWork {
                    current.lastActivityAt = max(current.lastActivityAt ?? .distantPast,
                                                 event.timestamp)
                    current.graceDeadline = nil
                    current.phase = .working
                } else if current.turnStopObserved {
                    if current.terminalDisposition == .legacyRelease {
                        beginLegacyRelease(&current, at: event.timestamp)
                    } else {
                        beginPendingCompletion(&current, at: event.timestamp)
                    }
                } else if current.waitingObserved {
                    beginWaitingRelease(&current, at: event.timestamp)
                } else if current.turnRole == .auxiliary,
                          event.backgroundWork == false,
                          event.workToken != nil,
                          current.backgroundWorkCount == 0,
                          !current.completedBackgroundWorkTokens.isEmpty {
                    // Codex SubagentStop is the auxiliary turn's terminal
                    // lifecycle edge. Older bridges represented it only as a
                    // tokenized background decrement, so there may be no
                    // independent root Stop event to move this turn out of
                    // Working. Confirm briefly, then restore policy only: this
                    // compatibility evidence is not strong enough to request
                    // conditional system sleep.
                    beginPolicyOnlyCompletionConfirmation(
                        &current,
                        at: event.timestamp
                    )
                }
            }

        case .turnCancelled, .sessionStarted, .processDiscovered, .sessionEnded,
                .processExited:
            disposition = .duplicate
        }
        turns[turnKey] = current
        return finishIngest(disposition)
    }

    /// Representative root-session state. Turn-level callers should use the
    /// AgentTurnKey overload or `allTurns(at:)`.
    public func state(for key: AgentSessionKey, at now: Date) -> AgentSessionState? {
        sessionAggregate(for: key, at: now)?.representativeState ?? placeholders[key]
    }

    public func state(for key: AgentTurnKey, at now: Date) -> AgentSessionState? {
        turns[key].map { effectiveCopy($0, at: now) }
    }

    public func activeTurns(at now: Date) -> Set<AgentTurnKey> {
        Set(turns.compactMap { key, value in value.isWakeEligible(at: now) ? key : nil })
    }

    /// WakeIntentSource remains keyed by root session for compatibility.
    public func activeSessions(at now: Date) -> Set<AgentSessionKey> {
        Set(activeTurns(at: now).map(\.sessionKey))
    }

    public func allTurns(at now: Date) -> [AgentSessionState] {
        turns.values.map { effectiveCopy($0, at: now) }.sorted(by: stateSort)
    }

    /// Source-compatible root-session view with one representative per root.
    public func allSessions(at now: Date) -> [AgentSessionState] {
        (sessionAggregates(at: now).map(\.representativeState) + Array(placeholders.values))
            .sorted(by: stateSort)
    }

    public func sessionAggregates(at now: Date) -> [AgentSessionAggregate] {
        let keys = Set(turns.keys.map(\.sessionKey))
        return keys.compactMap { sessionAggregate(for: $0, at: now) }.sorted {
            if $0.key.provider.rawValue != $1.key.provider.rawValue {
                return $0.key.provider.rawValue < $1.key.provider.rawValue
            }
            return $0.key.sessionID < $1.key.sessionID
        }
    }

    /// Explicitly retires every currently known work unit. Exact turn
    /// tombstones make delayed lifecycle events harmless, while the session
    /// tombstone covers discovery-only placeholders until genuinely newer work
    /// begins.
    public mutating func manuallyEndCurrentTurns(at timestamp: Date) {
        guard isFinite(timestamp) else { return }

        var endedSessions: [AgentSessionKey: Date] = [:]
        for (turnKey, state) in turns {
            let endedAt = max(timestamp, state.lastEventAt)
            if endedAt >= (turnTombstones[turnKey]?.timestamp ?? .distantPast) {
                turnTombstones[turnKey] = Tombstone(timestamp: endedAt)
            }
            endedSessions[turnKey.sessionKey] = max(
                endedSessions[turnKey.sessionKey] ?? .distantPast,
                endedAt
            )
        }
        for (sessionKey, placeholder) in placeholders {
            endedSessions[sessionKey] = max(
                endedSessions[sessionKey] ?? .distantPast,
                max(timestamp, placeholder.lastEventAt)
            )
        }
        for (sessionKey, endedAt) in endedSessions
        where endedAt >= (sessionTombstones[sessionKey]?.timestamp ?? .distantPast) {
            sessionTombstones[sessionKey] = Tombstone(
                timestamp: endedAt,
                policy: .manualRestore
            )
        }

        turns.removeAll()
        placeholders.removeAll()
        primaryTurns.removeAll()
        pruneTombstones(at: timestamp)
    }

    /// Wake-expired waits remain until their hard deadline so a later user
    /// response can resume the same turn. Other expired work becomes a turn
    /// tombstone and cannot be replayed after restart.
    public func recoverySnapshot(at now: Date) -> AgentStateRecoverySnapshot {
        var active: [AgentSessionState] = []
        var savedTurnTombstones = turnTombstones
        for (turnKey, state) in turns {
            let recoverableFinishedWait = state.phase == .waitingForInput
                && state.hardDeadline.map { now < $0 } == true
            if state.isWakeEligible(at: now) || recoverableFinishedWait {
                active.append(state)
                continue
            }
            let terminalTimestamp: Date
            switch state.effectivePhase(at: now) {
            case .hardExpired: terminalTimestamp = state.hardDeadline ?? state.lastEventAt
            case .finished: terminalTimestamp = state.graceDeadline ?? state.lastEventAt
            default: continue
            }
            if terminalTimestamp >= (savedTurnTombstones[turnKey]?.timestamp ?? .distantPast) {
                savedTurnTombstones[turnKey] = Tombstone(timestamp: terminalTimestamp)
            }
        }

        let cutoff = now.addingTimeInterval(-Self.tombstoneRetention)
        var saved = sessionTombstones.compactMap { key, value in
            value.timestamp >= cutoff
                ? AgentSessionTombstone(
                    key: key,
                    timestamp: value.timestamp,
                    turnID: nil,
                    policy: value.policy
                )
                : nil
        }
        saved.append(contentsOf: savedTurnTombstones.compactMap { key, value in
            value.timestamp >= cutoff
                ? AgentSessionTombstone(key: key.sessionKey,
                                        timestamp: value.timestamp,
                                        turnID: key.turnID)
                : nil
        })
        let boundedTombstones = saved.sorted(by: recoveryTombstoneSort).prefix(
            Self.maximumTombstoneCount
        )
        return AgentStateRecoverySnapshot(
            sessions: active.sorted { $0.lastEventAt > $1.lastEventAt },
            tombstones: Array(boundedTombstones)
        )
    }

    /// Restores v3 turn snapshots and migrates v1/v2 one-state-per-session
    /// snapshots using their existing turn IDs.
    public mutating func restore(_ snapshot: AgentStateRecoverySnapshot, at now: Date) {
        guard (1...AgentStateRecoverySnapshot.currentSchemaVersion)
            .contains(snapshot.schemaVersion) else { return }
        turns.removeAll()
        placeholders.removeAll()
        turnTombstones.removeAll()
        sessionTombstones.removeAll()
        primaryTurns.removeAll()
        let futureLimit = now.addingTimeInterval(5 * 60)
        var seenTurns: Set<AgentTurnKey> = []
        var seenLegacySessions: Set<AgentSessionKey> = []

        for candidate in snapshot.sessions
            .sorted(by: { $0.lastEventAt > $1.lastEventAt }).prefix(128) {
            guard candidate.key.provider != .cursor,
                  isSafeIdentifier(candidate.key.sessionID),
                  let turnID = candidate.turnID, isSafeIdentifier(turnID),
                  let started = candidate.turnStartedAt,
                  let storedHard = candidate.hardDeadline,
                  isFinite(started), isFinite(storedHard), isFinite(candidate.lastEventAt),
                  started <= futureLimit, candidate.lastEventAt <= futureLimit,
                  storedHard > started,
                  candidate.backgroundWorkTokens.count <= 1_024,
                  candidate.completedBackgroundWorkTokens.count <= 1_024,
                  candidate.backgroundWorkTokens.allSatisfy(isSafeWorkToken),
                  candidate.completedBackgroundWorkTokens.allSatisfy(isSafeWorkToken) else {
                continue
            }
            let turnKey = AgentTurnKey(provider: candidate.key.provider,
                                       sessionID: candidate.key.sessionID,
                                       turnID: turnID)
            guard seenTurns.insert(turnKey).inserted else { continue }
            if snapshot.schemaVersion < 3,
               !seenLegacySessions.insert(candidate.key).inserted { continue }

            var state = candidate
            if snapshot.schemaVersion < 3 {
                state.turnRole = .primary
                if state.phase == .turnStopped || state.phase == .pendingCompletion {
                    state.phase = .turnStopped
                    state.terminalDisposition = .legacyRelease
                } else if state.phase == .waitingForInput {
                    // Legacy snapshots retain their original wait anchor and
                    // deadline, but expiry is release-only. Older snapshots
                    // may not have persisted the explicit observation bit.
                    state.waitingObserved = true
                    state.waitingStartedAt = state.waitingStartedAt ?? state.lastEventAt
                    state.terminalDisposition = .legacyRelease
                }
            }
            if isPersistedAuxiliaryBackgroundGhost(state) {
                // v0.2.3 could persist a tokenized SubagentStop as an
                // auxiliary Working turn with zero remaining work. It is an
                // already-terminal compatibility artifact, not recoverable
                // work, so retire it immediately on upgrade.
                turnTombstones[turnKey] = Tombstone(timestamp: state.lastEventAt)
                continue
            }
            state.hardDeadline = min(storedHard,
                                     started.addingTimeInterval(maximumTurnDuration))
            guard state.hardDeadline.map({ $0 > now }) == true else {
                turnTombstones[turnKey] = Tombstone(
                    timestamp: state.hardDeadline ?? state.lastEventAt)
                continue
            }
            switch state.phase {
            case .working:
                state.graceDeadline = nil
            case .waitingForInput:
                guard let grace = state.graceDeadline, isFinite(grace) else { continue }
                state.graceDeadline = min(grace, state.hardDeadline!)
            case .pendingCompletion, .turnStopped:
                guard let grace = state.graceDeadline, isFinite(grace) else { continue }
                state.graceDeadline = min(grace, state.hardDeadline!)
                guard state.graceDeadline! > now else {
                    turnTombstones[turnKey] = Tombstone(timestamp: state.graceDeadline!)
                    continue
                }
            case .unknown, .finished, .hardExpired:
                continue
            }
            state.backgroundWorkCount = min(max(0, state.backgroundWorkCount), 1_024)
            state.backgroundWork = state.backgroundWorkCount > 0
            turns[turnKey] = state
            if state.turnRole == .primary || snapshot.schemaVersion < 3 {
                if let existing = primaryTurns[state.key],
                   let existingState = turns[existing],
                   existingState.lastEventAt > state.lastEventAt {
                    // Retain the newer primary marker.
                } else {
                    primaryTurns[state.key] = turnKey
                }
            }
        }

        let cutoff = now.addingTimeInterval(-Self.tombstoneRetention)
        for value in snapshot.tombstones
            .sorted(by: recoveryTombstoneSort).prefix(Self.maximumTombstoneCount) {
            guard value.key.provider != .cursor,
                  isSafeIdentifier(value.key.sessionID),
                  value.turnID.map(isSafeIdentifier) ?? true,
                  isFinite(value.timestamp), value.timestamp >= cutoff,
                  value.timestamp <= futureLimit else { continue }
            // v1/v2 tombstones were session-scoped even though they retained a
            // turn ID. v3 nil is a session boundary; v3 non-nil is per-turn.
            if snapshot.schemaVersion < 3 || value.turnID == nil {
                let newest = states(for: value.key).map(\.lastEventAt).max() ?? .distantPast
                if value.timestamp >= newest {
                    turns = turns.filter { $0.key.sessionKey != value.key }
                    primaryTurns.removeValue(forKey: value.key)
                    let existing = sessionTombstones[value.key]
                    let policy: AgentSessionTombstonePolicy =
                        existing?.policy == .manualRestore || value.policy == .manualRestore
                        ? .manualRestore : .lifecycle
                    let timestamp = max(
                        value.timestamp,
                        existing?.timestamp ?? .distantPast
                    )
                    sessionTombstones[value.key] = Tombstone(
                        timestamp: timestamp,
                        policy: policy
                    )
                }
            } else if let turnKey = value.turnKey {
                if let state = turns[turnKey], value.timestamp >= state.lastEventAt {
                    turns.removeValue(forKey: turnKey)
                    if primaryTurns[value.key] == turnKey {
                        primaryTurns.removeValue(forKey: value.key)
                    }
                }
                if value.timestamp >= (turnTombstones[turnKey]?.timestamp ?? .distantPast) {
                    turnTombstones[turnKey] = Tombstone(timestamp: value.timestamp)
                }
            }
        }
        pruneTombstones(at: now)
    }

    private mutating func finishIngest(
        _ disposition: AgentEventIngestDisposition
    ) -> AgentEventIngestDisposition {
        lastIngestDisposition = disposition
        return disposition
    }

    private func resolveTurnID(for event: AgentEvent,
                               sessionKey: AgentSessionKey) -> String? {
        if let turnID = event.turnID, !turnID.isEmpty { return turnID }
        if event.eventKind == .promptSubmitted {
            if let primary = primaryTurns[sessionKey],
               let state = turns[primary], state.phase == .working,
               !isHardExpired(state, at: event.timestamp) { return primary.turnID }
            return syntheticTurnID(for: event)
        }
        if let primary = primaryTurns[sessionKey] { return primary.turnID }
        if let latest = states(for: sessionKey).max(by: { $0.lastEventAt < $1.lastEventAt }) {
            return latest.turnID
        }
        switch event.eventKind {
        case .toolStarted, .activity, .inputReceived, .waitingForInput,
                .turnCompleted, .turnStopped, .turnFailed:
            return syntheticTurnID(for: event)
        case .backgroundWorkChanged where event.backgroundWork == true:
            return syntheticTurnID(for: event)
        default:
            return nil
        }
    }

    private func emptyState(sessionKey: AgentSessionKey,
                            timestamp: Date,
                            turnID: String?,
                            role: AgentTurnRole) -> AgentSessionState {
        AgentSessionState(key: sessionKey,
                          turnRole: role,
                          phase: .unknown,
                          turnID: turnID,
                          turnStartedAt: nil,
                          hardDeadline: nil,
                          lastActivityAt: nil,
                          lastEventAt: timestamp,
                          graceDeadline: nil,
                          backgroundWork: false,
                          backgroundWorkCount: 0,
                          turnStopObserved: false,
                          waitingObserved: false,
                          waitingReason: nil,
                          waitingStartedAt: nil,
                          lastBackgroundSignalAt: nil,
                          lastBackgroundSignalValue: nil)
    }

    private func beginRecoveredTurn(_ state: inout AgentSessionState,
                                    from event: AgentEvent,
                                    turnID: String) {
        state.turnID = turnID
        state.turnStartedAt = event.timestamp
        state.hardDeadline = event.timestamp.addingTimeInterval(maximumTurnDuration)
        state.lastActivityAt = event.timestamp
        state.lastEventAt = event.timestamp
        state.graceDeadline = nil
        state.backgroundWork = false
        state.backgroundWorkCount = 0
        state.backgroundWorkTokens.removeAll()
        state.completedBackgroundWorkTokens.removeAll()
        state.turnStopObserved = false
        state.waitingObserved = false
        state.waitingReason = nil
        state.waitingStartedAt = nil
        state.lastBackgroundSignalAt = nil
        state.lastBackgroundSignalValue = nil
        state.stopHookActive = false
        state.terminalDisposition = .none
        state.phase = .working
    }

    private func resumeWorking(_ state: inout AgentSessionState, at date: Date) {
        state.phase = .working
        state.graceDeadline = nil
        state.turnStopObserved = false
        state.waitingObserved = false
        state.waitingReason = nil
        state.waitingStartedAt = nil
        state.stopHookActive = false
        state.terminalDisposition = .none
        state.lastActivityAt = max(state.lastActivityAt ?? .distantPast, date)
        state.lastEventAt = max(state.lastEventAt, date)
    }

    private func beginPendingCompletion(_ state: inout AgentSessionState, at date: Date) {
        let proposed = date.addingTimeInterval(completionConfirmation)
        state.graceDeadline = state.phase == .pendingCompletion
            ? min(state.graceDeadline ?? proposed, proposed) : proposed
        state.phase = .pendingCompletion
        state.terminalDisposition = .successfulCompletion
    }

    private func beginPolicyOnlyCompletionConfirmation(
        _ state: inout AgentSessionState,
        at date: Date
    ) {
        let proposed = date.addingTimeInterval(completionConfirmation)
        state.graceDeadline = state.phase == .pendingCompletion
            ? min(state.graceDeadline ?? proposed, proposed) : proposed
        state.phase = .pendingCompletion
        state.terminalDisposition = .legacyRelease
    }

    private func beginLegacyRelease(_ state: inout AgentSessionState, at date: Date) {
        let proposed = date.addingTimeInterval(waitingGrace)
        state.graceDeadline = state.phase == .turnStopped
            ? min(state.graceDeadline ?? proposed, proposed) : proposed
        state.phase = .turnStopped
        state.terminalDisposition = .legacyRelease
    }

    private func beginWaitingRelease(_ state: inout AgentSessionState, at date: Date) {
        // Background work may temporarily move an observed wait back to the
        // working phase. When that work drains, the delay still belongs to the
        // first wait observation; do not silently grant a second full grace.
        if state.waitingStartedAt == nil {
            state.waitingStartedAt = date
        }
        let proposed = (state.waitingStartedAt ?? date).addingTimeInterval(waitingGrace)
        state.graceDeadline = state.phase == .waitingForInput
            ? min(state.graceDeadline ?? proposed, proposed) : proposed
        state.phase = .waitingForInput
        if state.terminalDisposition != .legacyRelease {
            state.terminalDisposition = .waitingExpired
        }
    }

    private func applyBackgroundSnapshot(from event: AgentEvent,
                                         to state: inout AgentSessionState,
                                         allowCountIncrease: Bool) {
        if let count = event.backgroundWorkCount {
            let bounded = min(max(0, count), 1_024)
            state.backgroundWorkCount = allowCountIncrease
                ? bounded : min(state.backgroundWorkCount, bounded)
            if count == 0 {
                state.backgroundWorkTokens.removeAll()
                state.completedBackgroundWorkTokens.removeAll()
            }
        } else if let active = event.backgroundWork {
            if active, allowCountIncrease {
                state.backgroundWorkCount = max(1, state.backgroundWorkCount)
            } else if !active {
                state.backgroundWorkCount = 0
                state.backgroundWorkTokens.removeAll()
                state.completedBackgroundWorkTokens.removeAll()
            }
        }
        state.backgroundWork = state.backgroundWorkCount > 0
    }

    private func applyBackgroundDelta(from event: AgentEvent,
                                      to state: inout AgentSessionState) -> Bool {
        guard let active = event.backgroundWork else { return false }
        if let token = event.workToken {
            if active {
                guard !state.backgroundWorkTokens.contains(token),
                      !state.completedBackgroundWorkTokens.contains(token) else { return false }
                if state.backgroundWorkTokens.count < 1_024 {
                    state.backgroundWorkTokens.insert(token)
                }
                state.backgroundWorkCount = min(1_024, state.backgroundWorkCount + 1)
            } else {
                guard !state.completedBackgroundWorkTokens.contains(token) else { return false }
                state.backgroundWorkTokens.remove(token)
                if state.completedBackgroundWorkTokens.count < 1_024 {
                    state.completedBackgroundWorkTokens.insert(token)
                }
                state.backgroundWorkCount = max(0, state.backgroundWorkCount - 1)
            }
        } else {
            if state.lastBackgroundSignalAt == event.timestamp,
               state.lastBackgroundSignalValue == event.backgroundWork { return false }
            state.lastBackgroundSignalAt = event.timestamp
            state.lastBackgroundSignalValue = event.backgroundWork
            state.backgroundWorkCount = active
                ? min(1_024, state.backgroundWorkCount + 1)
                : max(0, state.backgroundWorkCount - 1)
        }
        state.backgroundWork = state.backgroundWorkCount > 0
        return true
    }

    private func sessionAggregate(for key: AgentSessionKey,
                                  at now: Date) -> AgentSessionAggregate? {
        let values = states(for: key).map { effectiveCopy($0, at: now) }
        guard !values.isEmpty else { return nil }
        let representative = values.max { lhs, rhs in
            let leftRank = phaseRank(lhs.phase)
            let rightRank = phaseRank(rhs.phase)
            return leftRank == rightRank
                ? lhs.lastEventAt < rhs.lastEventAt : leftRank < rightRank
        }!
        return AgentSessionAggregate(
            key: key,
            workingCount: values.filter { $0.phase == .working }.count,
            waitingCount: values.filter { $0.phase == .waitingForInput }.count,
            pendingCompletionCount: values.filter {
                $0.phase == .pendingCompletion || $0.phase == .turnStopped
            }.count,
            visibleTurnCount: values.filter { $0.phase != .finished }.count,
            activeTurnCount: values.filter { $0.isWakeEligible(at: now) }.count,
            representativeState: representative)
    }

    private func states(for key: AgentSessionKey) -> [AgentSessionState] {
        turns.compactMap { $0.key.sessionKey == key ? $0.value : nil }
    }

    private func effectiveCopy(_ state: AgentSessionState, at now: Date) -> AgentSessionState {
        var copy = state
        copy.phase = state.effectivePhase(at: now)
        copy.terminalDisposition = state.effectiveTerminalDisposition(at: now)
        return copy
    }

    private func phaseRank(_ phase: AgentSessionPhase) -> Int {
        switch phase {
        case .working: return 6
        case .waitingForInput: return 5
        case .pendingCompletion: return 4
        case .turnStopped: return 3
        case .unknown: return 2
        case .hardExpired: return 1
        case .finished: return 0
        }
    }

    private func stateSort(_ lhs: AgentSessionState, _ rhs: AgentSessionState) -> Bool {
        if lhs.key.provider.rawValue != rhs.key.provider.rawValue {
            return lhs.key.provider.rawValue < rhs.key.provider.rawValue
        }
        if lhs.key.sessionID != rhs.key.sessionID { return lhs.key.sessionID < rhs.key.sessionID }
        return (lhs.turnID ?? "") < (rhs.turnID ?? "")
    }

    private func isHardExpired(_ state: AgentSessionState, at date: Date) -> Bool {
        state.hardDeadline.map { date >= $0 } ?? false
    }

    private func isPersistedAuxiliaryBackgroundGhost(
        _ state: AgentSessionState
    ) -> Bool {
        state.turnRole == .auxiliary
            && state.phase == .working
            && !state.backgroundWork
            && state.backgroundWorkCount == 0
            && state.backgroundWorkTokens.isEmpty
            && !state.completedBackgroundWorkTokens.isEmpty
            && !state.turnStopObserved
            && !state.waitingObserved
    }

    private func isFinite(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite }

    private mutating func pruneTombstones(at now: Date) {
        guard isFinite(now) else { return }
        let cutoff = now.addingTimeInterval(-Self.tombstoneRetention)
        turnTombstones = turnTombstones.filter { $0.value.timestamp >= cutoff }
        sessionTombstones = sessionTombstones.filter { $0.value.timestamp >= cutoff }

        guard turnTombstones.count + sessionTombstones.count
                > Self.maximumTombstoneCount else { return }
        var candidates = turnTombstones.map {
            (identity: TombstoneIdentity.turn($0.key), timestamp: $0.value.timestamp)
        }
        candidates.append(contentsOf: sessionTombstones.map {
            (identity: TombstoneIdentity.session($0.key), timestamp: $0.value.timestamp)
        })
        let retained = Set(candidates.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return tombstoneSortKey(lhs.identity) < tombstoneSortKey(rhs.identity)
        }.prefix(Self.maximumTombstoneCount).map(\.identity))
        turnTombstones = turnTombstones.filter {
            retained.contains(.turn($0.key))
        }
        sessionTombstones = sessionTombstones.filter {
            retained.contains(.session($0.key))
        }
    }

    private func recoveryTombstoneSort(
        _ lhs: AgentSessionTombstone,
        _ rhs: AgentSessionTombstone
    ) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
        let left = lhs.turnKey.map(TombstoneIdentity.turn) ?? .session(lhs.key)
        let right = rhs.turnKey.map(TombstoneIdentity.turn) ?? .session(rhs.key)
        return tombstoneSortKey(left) < tombstoneSortKey(right)
    }

    private func tombstoneSortKey(_ identity: TombstoneIdentity) -> String {
        switch identity {
        case .session(let key):
            return "0|\(key.provider.rawValue)|\(key.sessionID)"
        case .turn(let key):
            return "1|\(key.provider.rawValue)|\(key.sessionID)|\(key.turnID)"
        }
    }

    private func syntheticTurnID(for event: AgentEvent) -> String {
        let milliseconds = Int64((event.timestamp.timeIntervalSince1970 * 1_000).rounded())
        return "local-turn-\(milliseconds)"
    }

    private func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.contains("\0")
    }

    private func isSafeWorkToken(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}
