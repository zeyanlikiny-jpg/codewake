import XCTest

final class AgentStateMachineTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let tokenA = String(repeating: "a", count: 64)
    private let tokenB = String(repeating: "b", count: 64)

    private func event(_ kind: AgentEventKind,
                       session: String = "session-1",
                       turn: String? = "turn-1",
                       seconds: TimeInterval = 0,
                       background: Bool? = nil,
                       backgroundCount: Int? = nil,
                       workToken: String? = nil,
                       stopHookActive: Bool? = nil,
                       confirmed: Bool? = nil,
                       schema: Int = AgentEvent.currentSchemaVersion) -> AgentEvent {
        AgentEvent(schemaVersion: schema,
                   provider: .codex,
                   sessionID: session,
                   turnID: turn,
                   eventKind: kind,
                   backgroundWork: background,
                   backgroundWorkCount: backgroundCount,
                   workToken: workToken,
                   stopHookActive: stopHookActive,
                   timestamp: base.addingTimeInterval(seconds),
                   confirmed: confirmed)
    }

    func testWireDateIsUnixEpochAndRoundTrips() throws {
        let original = event(.promptSubmitted)
        let data = try JSONEncoder().encode(original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["timestamp"] as? Double, base.timeIntervalSince1970)
        XCTAssertNil(object["prompt"])
        XCTAssertNil(object["cwd"])
        XCTAssertEqual(try JSONDecoder().decode(AgentEvent.self, from: data), original)
    }

    func testDiscoveryAloneDoesNotWake() {
        var machine = AgentStateMachine()
        machine.ingest(event(.sessionStarted, turn: nil))
        XCTAssertTrue(machine.activeSessions(at: base).isEmpty)
        XCTAssertEqual(machine.allSessions(at: base).first?.phase, .unknown)
    }

    func testPromptStartsWorkingAndActivityDoesNotExtendHardLimit() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 10)
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.activity, seconds: 90))
        let state = machine.allSessions(at: base.addingTimeInterval(90)).first
        XCTAssertEqual(state?.phase, .working)
        XCTAssertEqual(state?.hardDeadline, base.addingTimeInterval(100))
        XCTAssertTrue(machine.activeSessions(at: base.addingTimeInterval(99)).count == 1)
        XCTAssertTrue(machine.activeSessions(at: base.addingTimeInterval(100)).isEmpty)
    }

    func testAuthoritativeActivityRecoversWhenPromptWasLost() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 10)
        machine.ingest(event(.sessionStarted, turn: nil))
        machine.ingest(event(.activity, seconds: 2))
        let state = machine.allSessions(at: base.addingTimeInterval(2)).first
        XCTAssertEqual(state?.phase, .working)
        XCTAssertEqual(state?.turnID, "turn-1")
        XCTAssertEqual(state?.hardDeadline, base.addingTimeInterval(102))
    }

    func testDifferentTurnActivityRecoversAfterPromptHookWasLost() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 10)
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.turnCompleted, seconds: 2))
        machine.ingest(event(.activity, turn: "turn-2", seconds: 3))

        let state = machine.allSessions(at: base.addingTimeInterval(3)).first
        XCTAssertEqual(state?.phase, .working)
        XCTAssertEqual(state?.turnID, "turn-2")
        XCTAssertEqual(state?.hardDeadline, base.addingTimeInterval(103))
    }

    func testDifferentTurnActivityRecoversAfterStoredWorkingStateHardExpires() {
        var machine = AgentStateMachine(maximumTurnDuration: 10, releaseGrace: 5)
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.activity, turn: "turn-2", seconds: 11))

        let state = machine.allSessions(at: base.addingTimeInterval(11)).first
        XCTAssertEqual(state?.phase, .working)
        XCTAssertEqual(state?.turnID, "turn-2")
        XCTAssertEqual(state?.hardDeadline, base.addingTimeInterval(21))
    }

    func testDifferentTurnActivityCanRecoverPastEndedSessionTombstone() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.sessionEnded, seconds: 2))
        machine.ingest(event(.activity, turn: "turn-2", seconds: 3))

        XCTAssertEqual(machine.activeSessions(at: base.addingTimeInterval(3)).count, 1)
        XCTAssertEqual(machine.allSessions(at: base.addingTimeInterval(3)).first?.turnID, "turn-2")
    }

    func testCPUActivityCannotCreateOrReorderLifecycleState() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 10)
        machine.ingest(event(.activity, seconds: 5, confirmed: false))
        XCTAssertTrue(machine.activeSessions(at: base.addingTimeInterval(5)).isEmpty)

        machine.ingest(event(.promptSubmitted, seconds: 10))
        machine.ingest(event(.activity, seconds: 30, confirmed: false))
        machine.ingest(event(.turnCompleted, seconds: 20))
        let state = machine.allSessions(at: base.addingTimeInterval(21)).first
        XCTAssertEqual(state?.phase, .pendingCompletion)
        XCTAssertEqual(state?.lastEventAt, base.addingTimeInterval(20))
    }

    func testToolActivityCancelsPendingCompletion() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 10)
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.turnCompleted, seconds: 5))
        machine.ingest(event(.activity, seconds: 6))
        let state = machine.allSessions(at: base.addingTimeInterval(6)).first
        XCTAssertEqual(state?.phase, .working)
        XCTAssertNil(state?.graceDeadline)
        XCTAssertEqual(state?.terminalDisposition, AgentTerminalDisposition.none)
    }

    func testSameTurnPromptContinuationCancelsPendingCompletion() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 10)
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.turnCompleted, seconds: 5))
        machine.ingest(event(.promptSubmitted, seconds: 6))

        XCTAssertEqual(
            machine.allSessions(at: base.addingTimeInterval(6)).first?.phase,
            .working
        )
        XCTAssertEqual(machine.activeSessions(at: base.addingTimeInterval(15)).count, 1)
    }

    func testStopKeepsGraceThenFinishes() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 10)
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.turnCompleted, seconds: 5, background: false))
        XCTAssertEqual(
            machine.allSessions(at: base.addingTimeInterval(6)).first?.phase,
            .pendingCompletion
        )
        XCTAssertEqual(machine.activeSessions(at: base.addingTimeInterval(14)).count, 1)
        XCTAssertTrue(machine.activeSessions(at: base.addingTimeInterval(15)).isEmpty)
        XCTAssertEqual(machine.allSessions(at: base.addingTimeInterval(15)).first?.phase, .finished)
    }

    func testWaitingUsesSameReleaseGrace() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 10)
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.waitingForInput, seconds: 4))
        XCTAssertEqual(machine.allSessions(at: base.addingTimeInterval(5)).first?.phase, .waitingForInput)
        XCTAssertTrue(machine.activeSessions(at: base.addingTimeInterval(14)).isEmpty)
    }

    func testProductionCompletionAndWaitingUseDistinctDeadlines() {
        var completed = AgentStateMachine(
            maximumTurnDuration: 1_000,
            completionConfirmation: 5,
            waitingGrace: 300
        )
        completed.ingest(event(.promptSubmitted))
        completed.ingest(event(.turnCompleted, seconds: 1, backgroundCount: 0))
        XCTAssertEqual(
            completed.allSessions(at: base.addingTimeInterval(5.999)).first?.phase,
            .pendingCompletion
        )
        let terminal = completed.allSessions(at: base.addingTimeInterval(6)).first
        XCTAssertEqual(terminal?.phase, .finished)
        XCTAssertEqual(terminal?.terminalDisposition, .successfulCompletion)
        XCTAssertTrue(terminal?.isSleepEligibleCompletion(at: base.addingTimeInterval(6)) == true)

        var waiting = AgentStateMachine(
            maximumTurnDuration: 1_000,
            completionConfirmation: 5,
            waitingGrace: 300
        )
        waiting.ingest(event(.promptSubmitted))
        waiting.ingest(event(.waitingForInput, seconds: 1))
        XCTAssertEqual(waiting.activeSessions(at: base.addingTimeInterval(300)).count, 1)
        let expiredWait = waiting.allSessions(at: base.addingTimeInterval(301)).first
        XCTAssertEqual(expiredWait?.phase, .finished)
        XCTAssertEqual(expiredWait?.terminalDisposition, .waitingExpired)
        XCTAssertTrue(
            expiredWait?.isConditionalSleepEligibleTerminal(
                at: base.addingTimeInterval(301)
            ) == true
        )
    }

    func testStopAfterAskUserDoesNotConvertWaitingIntoCompletion() {
        var machine = AgentStateMachine(
            maximumTurnDuration: 1_000,
            completionConfirmation: 5,
            waitingGrace: 300
        )
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.waitingForInput, seconds: 1))
        machine.ingest(event(.turnCompleted, seconds: 2, backgroundCount: 0))

        let state = machine.allSessions(at: base.addingTimeInterval(2)).first
        XCTAssertEqual(state?.phase, .waitingForInput)
        XCTAssertEqual(state?.graceDeadline, base.addingTimeInterval(301))
        XCTAssertEqual(state?.terminalDisposition, .waitingExpired)
        XCTAssertEqual(machine.activeSessions(at: base.addingTimeInterval(300)).count, 1)
        XCTAssertTrue(machine.activeSessions(at: base.addingTimeInterval(301)).isEmpty)
    }

    func testStopFailureReleasesImmediatelyWithoutSleepEligibility() {
        var machine = AgentStateMachine(
            maximumTurnDuration: 100,
            completionConfirmation: 5,
            waitingGrace: 20
        )
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.turnFailed, seconds: 2, stopHookActive: true))

        XCTAssertTrue(machine.activeSessions(at: base.addingTimeInterval(2)).isEmpty)
        let state = machine.allSessions(at: base.addingTimeInterval(2)).first
        XCTAssertEqual(state?.phase, .finished)
        XCTAssertEqual(state?.terminalDisposition, .failed)
        XCTAssertEqual(state?.stopHookActive, true)
        XCTAssertFalse(state?.isSleepEligibleCompletion(at: base.addingTimeInterval(2)) == true)

        machine.ingest(event(.turnCompleted, seconds: 3, backgroundCount: 0))
        let lateStop = machine.allSessions(at: base.addingTimeInterval(3)).first
        XCTAssertEqual(lateStop?.terminalDisposition, .failed)
        XCTAssertFalse(lateStop?.isSleepEligibleCompletion(at: base.addingTimeInterval(3)) == true)
    }

    func testDuplicateStopCannotExtendCompletionConfirmation() {
        var machine = AgentStateMachine(
            maximumTurnDuration: 100,
            completionConfirmation: 5,
            waitingGrace: 20
        )
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.turnCompleted, seconds: 1, stopHookActive: false))
        machine.ingest(event(.turnCompleted, seconds: 4, stopHookActive: true))

        let state = machine.allSessions(at: base.addingTimeInterval(4)).first
        XCTAssertEqual(state?.graceDeadline, base.addingTimeInterval(6))
        XCTAssertEqual(state?.stopHookActive, true)
        XCTAssertTrue(machine.activeSessions(at: base.addingTimeInterval(6)).isEmpty)
    }

    func testBackgroundWorkKeepsStoppedTurnWorking() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 10)
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.backgroundWorkChanged, seconds: 1, background: true))
        machine.ingest(event(.turnCompleted, seconds: 2, background: true))
        let state = machine.allSessions(at: base.addingTimeInterval(50)).first
        XCTAssertEqual(state?.phase, .working)
        XCTAssertTrue(state?.backgroundWork == true)
    }

    func testBackgroundCompletionAfterStopBeginsGrace() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 10)
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.backgroundWorkChanged, seconds: 1, background: true))
        machine.ingest(event(.turnCompleted, seconds: 2, background: true))
        machine.ingest(event(.backgroundWorkChanged, seconds: 3, background: false))
        XCTAssertEqual(
            machine.allSessions(at: base.addingTimeInterval(4)).first?.phase,
            .pendingCompletion
        )
        XCTAssertEqual(machine.activeSessions(at: base.addingTimeInterval(12)).count, 1)
        XCTAssertTrue(machine.activeSessions(at: base.addingTimeInterval(13)).isEmpty)
    }

    func testWaitingDoesNotReleaseUntilBackgroundWorkFinishes() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 10)
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.backgroundWorkChanged, seconds: 1, background: true))
        machine.ingest(event(.waitingForInput, seconds: 2))
        XCTAssertEqual(machine.allSessions(at: base.addingTimeInterval(50)).first?.phase, .working)
        XCTAssertEqual(machine.activeSessions(at: base.addingTimeInterval(50)).count, 1)

        machine.ingest(event(.backgroundWorkChanged, seconds: 60, background: false))
        XCTAssertEqual(machine.allSessions(at: base.addingTimeInterval(60)).first?.phase, .waitingForInput)
        XCTAssertEqual(machine.activeSessions(at: base.addingTimeInterval(69)).count, 1)
        XCTAssertTrue(machine.activeSessions(at: base.addingTimeInterval(70)).isEmpty)
    }

    func testExactDuplicateBackgroundStartIsIdempotent() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 10)
        machine.ingest(event(.promptSubmitted))
        let start = event(.backgroundWorkChanged, seconds: 1, background: true)
        machine.ingest(start)
        machine.ingest(start)
        machine.ingest(event(.turnCompleted, seconds: 2))
        machine.ingest(event(.backgroundWorkChanged, seconds: 3, background: false))

        let state = machine.allSessions(at: base.addingTimeInterval(3)).first
        XCTAssertEqual(state?.backgroundWorkCount, 0)
        XCTAssertEqual(state?.phase, .pendingCompletion)
    }

    func testParallelBackgroundSignalsReleaseOnlyAfterLastStop() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 10)
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.backgroundWorkChanged, seconds: 1, background: true))
        machine.ingest(event(.backgroundWorkChanged, seconds: 2, background: true))
        machine.ingest(event(.turnCompleted, seconds: 3))
        machine.ingest(event(.backgroundWorkChanged, seconds: 4, background: false))
        XCTAssertEqual(machine.allSessions(at: base.addingTimeInterval(4)).first?.backgroundWorkCount, 1)
        XCTAssertEqual(machine.allSessions(at: base.addingTimeInterval(4)).first?.phase, .working)

        machine.ingest(event(.backgroundWorkChanged, seconds: 5, background: false))
        XCTAssertEqual(machine.allSessions(at: base.addingTimeInterval(5)).first?.backgroundWorkCount, 0)
        XCTAssertEqual(
            machine.allSessions(at: base.addingTimeInterval(5)).first?.phase,
            .pendingCompletion
        )
    }

    func testOpaqueWorkTokensMakeDifferentTimestampRetriesIdempotent() {
        var machine = AgentStateMachine(
            maximumTurnDuration: 100,
            completionConfirmation: 5,
            waitingGrace: 20
        )
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(
            .backgroundWorkChanged, seconds: 1, background: true, workToken: tokenA
        ))
        machine.ingest(event(
            .backgroundWorkChanged, seconds: 2, background: true, workToken: tokenA
        ))
        machine.ingest(event(
            .backgroundWorkChanged, seconds: 3, background: true, workToken: tokenB
        ))
        machine.ingest(event(.turnCompleted, seconds: 4, backgroundCount: 2))
        XCTAssertEqual(machine.allSessions(at: base.addingTimeInterval(4)).first?.backgroundWorkCount, 2)

        machine.ingest(event(
            .backgroundWorkChanged, seconds: 5, background: false, workToken: tokenA
        ))
        machine.ingest(event(
            .backgroundWorkChanged, seconds: 6, background: false, workToken: tokenA
        ))
        XCTAssertEqual(machine.allSessions(at: base.addingTimeInterval(6)).first?.backgroundWorkCount, 1)
        XCTAssertEqual(machine.allSessions(at: base.addingTimeInterval(6)).first?.phase, .working)

        // A retried stale Stop snapshot must not resurrect the task that has
        // already completed. A genuine continuation clears turnStopObserved
        // before a later Stop is allowed to increase the absolute count.
        machine.ingest(event(.turnCompleted, seconds: 6.5, backgroundCount: 2))
        XCTAssertEqual(machine.allSessions(at: base.addingTimeInterval(6.5)).first?.backgroundWorkCount, 1)

        machine.ingest(event(
            .backgroundWorkChanged, seconds: 7, background: false, workToken: tokenB
        ))
        let state = machine.allSessions(at: base.addingTimeInterval(7)).first
        XCTAssertEqual(state?.backgroundWorkCount, 0)
        XCTAssertEqual(state?.phase, .pendingCompletion)
        XCTAssertEqual(state?.graceDeadline, base.addingTimeInterval(12))
    }

    func testAbsoluteStopSnapshotHandlesMissedStartsAndDuplicateStops() {
        var machine = AgentStateMachine(
            maximumTurnDuration: 100,
            completionConfirmation: 5,
            waitingGrace: 20
        )
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.turnCompleted, seconds: 1, backgroundCount: 2))
        machine.ingest(event(
            .backgroundWorkChanged, seconds: 2, background: false, workToken: tokenA
        ))
        machine.ingest(event(
            .backgroundWorkChanged, seconds: 3, background: false, workToken: tokenA
        ))
        XCTAssertEqual(machine.allSessions(at: base.addingTimeInterval(3)).first?.backgroundWorkCount, 1)

        machine.ingest(event(
            .backgroundWorkChanged, seconds: 4, background: false, workToken: tokenB
        ))
        XCTAssertEqual(
            machine.allSessions(at: base.addingTimeInterval(4)).first?.phase,
            .pendingCompletion
        )
    }

    func testLateBackgroundStartCannotReviveCompletedOpaqueToken() {
        var machine = AgentStateMachine(
            maximumTurnDuration: 100,
            completionConfirmation: 5,
            waitingGrace: 20
        )
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.turnCompleted, seconds: 1, backgroundCount: 1))
        machine.ingest(event(
            .backgroundWorkChanged, seconds: 2, background: false, workToken: tokenA
        ))
        let originalDeadline = machine.allSessions(at: base.addingTimeInterval(2)).first?
            .graceDeadline

        machine.ingest(event(
            .backgroundWorkChanged, seconds: 3, background: true, workToken: tokenA
        ))
        let state = machine.allSessions(at: base.addingTimeInterval(3)).first
        XCTAssertEqual(state?.phase, .pendingCompletion)
        XCTAssertEqual(state?.backgroundWorkCount, 0)
        XCTAssertEqual(state?.graceDeadline, originalDeadline)
    }

    func testTokenizedAuxiliaryStopUsesPolicyOnlyCompletionConfirmation() {
        var machine = AgentStateMachine(
            maximumTurnDuration: 100,
            completionConfirmation: 5,
            waitingGrace: 300
        )
        machine.ingest(event(
            .backgroundWorkChanged,
            turn: "child-turn",
            seconds: 1,
            background: true,
            workToken: tokenA
        ))

        XCTAssertEqual(machine.ingest(event(
            .backgroundWorkChanged,
            turn: "child-turn",
            seconds: 2,
            background: false,
            workToken: tokenA
        )), .accepted)

        let confirming = machine.allTurns(at: base.addingTimeInterval(2)).first
        XCTAssertEqual(confirming?.turnRole, .auxiliary)
        XCTAssertEqual(confirming?.phase, .pendingCompletion)
        XCTAssertEqual(confirming?.terminalDisposition, .legacyRelease)
        XCTAssertEqual(confirming?.graceDeadline, base.addingTimeInterval(7))
        XCTAssertEqual(confirming?.backgroundWorkCount, 0)
        XCTAssertEqual(confirming?.completedBackgroundWorkTokens, [tokenA])
        XCTAssertEqual(machine.activeTurns(at: base.addingTimeInterval(6.999)).count, 1)
        XCTAssertTrue(machine.activeTurns(at: base.addingTimeInterval(7)).isEmpty)

        let terminal = machine.allTurns(at: base.addingTimeInterval(7)).first
        XCTAssertEqual(terminal?.phase, .finished)
        XCTAssertEqual(terminal?.terminalDisposition, .legacyRelease)
        XCTAssertFalse(terminal?.isConditionalSleepEligibleTerminal(
            at: base.addingTimeInterval(7)
        ) == true)
        let snapshot = machine.recoverySnapshot(at: base.addingTimeInterval(7))
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertEqual(snapshot.tombstones.map(\.turnID), ["child-turn"])
    }

    func testTokenizedAuxiliaryStopsWaitForLastOutstandingToken() {
        var machine = AgentStateMachine(
            maximumTurnDuration: 100,
            completionConfirmation: 5,
            waitingGrace: 300
        )
        machine.ingest(event(
            .backgroundWorkChanged,
            turn: "child-turn",
            seconds: 1,
            background: true,
            workToken: tokenA
        ))
        machine.ingest(event(
            .backgroundWorkChanged,
            turn: "child-turn",
            seconds: 2,
            background: true,
            workToken: tokenB
        ))
        machine.ingest(event(
            .backgroundWorkChanged,
            turn: "child-turn",
            seconds: 3,
            background: false,
            workToken: tokenA
        ))

        let oneRemaining = machine.allTurns(at: base.addingTimeInterval(3)).first
        XCTAssertEqual(oneRemaining?.phase, .working)
        XCTAssertEqual(oneRemaining?.backgroundWorkCount, 1)
        XCTAssertEqual(oneRemaining?.completedBackgroundWorkTokens, [tokenA])

        machine.ingest(event(
            .backgroundWorkChanged,
            turn: "child-turn",
            seconds: 4,
            background: false,
            workToken: tokenB
        ))
        let confirming = machine.allTurns(at: base.addingTimeInterval(4)).first
        XCTAssertEqual(confirming?.phase, .pendingCompletion)
        XCTAssertEqual(confirming?.terminalDisposition, .legacyRelease)
        XCTAssertEqual(confirming?.graceDeadline, base.addingTimeInterval(9))
        XCTAssertEqual(confirming?.completedBackgroundWorkTokens, [tokenA, tokenB])
    }

    func testTokenizedAuxiliaryStopHonorsPreviouslyObservedWait() {
        var machine = AgentStateMachine(
            maximumTurnDuration: 1_000,
            completionConfirmation: 5,
            waitingGrace: 300
        )
        machine.ingest(event(
            .backgroundWorkChanged,
            turn: "child-turn",
            seconds: 1,
            background: true,
            workToken: tokenA
        ))
        machine.ingest(event(.waitingForInput, turn: "child-turn", seconds: 2))
        machine.ingest(event(
            .backgroundWorkChanged,
            turn: "child-turn",
            seconds: 3,
            background: false,
            workToken: tokenA
        ))

        let waiting = machine.allTurns(at: base.addingTimeInterval(3)).first
        XCTAssertEqual(waiting?.phase, .waitingForInput)
        XCTAssertEqual(waiting?.terminalDisposition, .waitingExpired)
        XCTAssertEqual(waiting?.graceDeadline, base.addingTimeInterval(303))
    }

    func testClaudePromptWithoutPromptIDGetsPrivateSyntheticTurn() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 10)
        machine.ingest(AgentEvent(
            provider: .claudeCode,
            sessionID: "claude-session",
            turnID: nil,
            eventKind: .promptSubmitted,
            timestamp: base
        ))
        let first = machine.allSessions(at: base).first
        XCTAssertEqual(first?.phase, .working)
        XCTAssertEqual(first?.turnID, "local-turn-1700000000000")

        machine.ingest(AgentEvent(
            provider: .claudeCode,
            sessionID: "claude-session",
            turnID: nil,
            eventKind: .turnCompleted,
            timestamp: base.addingTimeInterval(1)
        ))
        machine.ingest(AgentEvent(
            provider: .claudeCode,
            sessionID: "claude-session",
            turnID: nil,
            eventKind: .promptSubmitted,
            timestamp: base.addingTimeInterval(2)
        ))
        XCTAssertEqual(machine.allSessions(at: base.addingTimeInterval(2)).first?.turnID,
                       "local-turn-1700000002000")
    }

    func testFreshIDLessPromptCanReviveSessionAfterEnd() {
        var machine = AgentStateMachine()
        machine.ingest(event(.promptSubmitted, turn: nil))
        machine.ingest(event(.sessionEnded, turn: nil, seconds: 1))
        machine.ingest(event(.promptSubmitted, turn: nil, seconds: 2))
        XCTAssertEqual(machine.activeSessions(at: base.addingTimeInterval(2)).count, 1)
    }

    func testNewPromptCancelsGraceAndStartsNewHardLimit() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 10)
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.turnCompleted, seconds: 5))
        machine.ingest(event(.promptSubmitted, turn: "turn-2", seconds: 8))
        let state = machine.allSessions(at: base.addingTimeInterval(9)).first
        XCTAssertEqual(state?.phase, .working)
        XCTAssertEqual(state?.turnID, "turn-2")
        XCTAssertNil(state?.graceDeadline)
        XCTAssertEqual(state?.hardDeadline, base.addingTimeInterval(108))
    }

    func testSameTurnCannotReviveAfterHardExpiryButNewTurnCan() {
        var machine = AgentStateMachine(maximumTurnDuration: 10, releaseGrace: 5)
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.activity, seconds: 11))
        machine.ingest(event(.promptSubmitted, seconds: 12))
        XCTAssertTrue(machine.activeSessions(at: base.addingTimeInterval(12)).isEmpty)
        XCTAssertEqual(machine.allSessions(at: base.addingTimeInterval(12)).first?.phase, .hardExpired)

        machine.ingest(event(.promptSubmitted, turn: "turn-2", seconds: 13))
        XCTAssertEqual(machine.activeSessions(at: base.addingTimeInterval(13)).count, 1)
    }

    func testSessionEndAndConfirmedProcessExitRemoveImmediately() {
        var machine = AgentStateMachine()
        machine.ingest(event(.promptSubmitted, session: "a"))
        machine.ingest(event(.promptSubmitted, session: "b"))
        machine.ingest(event(.sessionEnded, session: "a", seconds: 1))
        machine.ingest(event(.processExited, session: "b", seconds: 1, confirmed: false))
        XCTAssertEqual(machine.activeSessions(at: base.addingTimeInterval(2)).count, 1)
        machine.ingest(event(.processExited, session: "b", seconds: 2, confirmed: true))
        XCTAssertTrue(machine.activeSessions(at: base.addingTimeInterval(2)).isEmpty)
    }

    func testLateEventCannotReviveEndedSessionOrOlderTurn() {
        var machine = AgentStateMachine()
        machine.ingest(event(.promptSubmitted, seconds: 10))
        machine.ingest(event(.sessionEnded, seconds: 20))
        machine.ingest(event(.activity, seconds: 15))
        XCTAssertTrue(machine.allSessions(at: base.addingTimeInterval(21)).isEmpty)

        machine.ingest(event(.promptSubmitted, turn: "turn-2", seconds: 21))
        machine.ingest(event(.activity, turn: "turn-1", seconds: 22))
        XCTAssertEqual(machine.allSessions(at: base.addingTimeInterval(22)).first?.turnID, "turn-2")
    }

    func testMultipleSessionsAreReferenceCounted() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        machine.ingest(event(.promptSubmitted, session: "a"))
        machine.ingest(event(.promptSubmitted, session: "b"))
        machine.ingest(event(.sessionEnded, session: "a", seconds: 1))
        XCTAssertEqual(machine.activeSessions(at: base.addingTimeInterval(1)).count, 1)
        machine.ingest(event(.turnCompleted, session: "b", seconds: 2))
        XCTAssertEqual(machine.activeSessions(at: base.addingTimeInterval(6)).count, 1)
        XCTAssertTrue(machine.activeSessions(at: base.addingTimeInterval(7)).isEmpty)
    }

    func testPolicyUpdateRecomputesCurrentDeadline() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 10)
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.turnCompleted, seconds: 2))
        machine.updatePolicy(maximumTurnDuration: 20, releaseGrace: 3)
        let state = machine.allSessions(at: base.addingTimeInterval(3)).first
        XCTAssertEqual(state?.hardDeadline, base.addingTimeInterval(20))
        XCTAssertEqual(state?.graceDeadline, base.addingTimeInterval(5))
    }

    func testPolicyIncreaseDoesNotExtendCurrentTurn() {
        var machine = AgentStateMachine(maximumTurnDuration: 20, releaseGrace: 10)
        machine.ingest(event(.promptSubmitted))

        machine.updatePolicy(maximumTurnDuration: 100, releaseGrace: 10)

        let state = machine.allSessions(at: base.addingTimeInterval(5)).first
        XCTAssertEqual(state?.hardDeadline, base.addingTimeInterval(20))
        XCTAssertTrue(machine.activeSessions(at: base.addingTimeInterval(20)).isEmpty)
    }

    func testPolicyIncreaseCannotReviveExpiredCurrentTurn() {
        var machine = AgentStateMachine(maximumTurnDuration: 10, releaseGrace: 5)
        machine.ingest(event(.promptSubmitted))
        XCTAssertTrue(machine.activeSessions(at: base.addingTimeInterval(11)).isEmpty)

        machine.updatePolicy(maximumTurnDuration: 100, releaseGrace: 5)

        let state = machine.allSessions(at: base.addingTimeInterval(11)).first
        XCTAssertEqual(state?.hardDeadline, base.addingTimeInterval(10))
        XCTAssertTrue(machine.activeSessions(at: base.addingTimeInterval(11)).isEmpty)
    }

    func testRecoverySnapshotPreservesOriginalHardDeadline() {
        var original = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 10)
        original.ingest(event(.promptSubmitted))
        let snapshot = original.recoverySnapshot(at: base.addingTimeInterval(10))

        var restored = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 10)
        restored.restore(snapshot, at: base.addingTimeInterval(20))

        XCTAssertEqual(restored.activeSessions(at: base.addingTimeInterval(20)).count, 1)
        XCTAssertEqual(
            restored.allSessions(at: base.addingTimeInterval(20)).first?.hardDeadline,
            base.addingTimeInterval(100)
        )
    }

    func testRestoreNeverExtendsSnapshotBeyondCurrentPolicy() {
        var original = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 10)
        original.ingest(event(.promptSubmitted))
        let snapshot = original.recoverySnapshot(at: base.addingTimeInterval(10))

        var restored = AgentStateMachine(maximumTurnDuration: 50, releaseGrace: 10)
        restored.restore(snapshot, at: base.addingTimeInterval(20))

        XCTAssertEqual(
            restored.allSessions(at: base.addingTimeInterval(20)).first?.hardDeadline,
            base.addingTimeInterval(50)
        )
    }

    func testExpiredRecoveryBecomesTombstoneAndCannotReviveOldTurn() {
        var original = AgentStateMachine(maximumTurnDuration: 10, releaseGrace: 5)
        original.ingest(event(.promptSubmitted))
        let snapshot = original.recoverySnapshot(at: base.addingTimeInterval(11))
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertEqual(snapshot.tombstones.count, 1)

        var restored = AgentStateMachine(maximumTurnDuration: 10, releaseGrace: 5)
        restored.restore(snapshot, at: base.addingTimeInterval(11))
        restored.ingest(event(.activity, seconds: 9))
        XCTAssertTrue(restored.activeSessions(at: base.addingTimeInterval(11)).isEmpty)

        restored.ingest(event(.promptSubmitted, turn: "turn-2", seconds: 12))
        XCTAssertEqual(restored.activeSessions(at: base.addingTimeInterval(12)).count, 1)
    }

    func testActiveSnapshotThatExpiresBeforeRestoreCannotRestartSameTurn() {
        var original = AgentStateMachine(maximumTurnDuration: 10, releaseGrace: 5)
        original.ingest(event(.promptSubmitted))
        let activeSnapshot = original.recoverySnapshot(at: base.addingTimeInterval(1))
        XCTAssertEqual(activeSnapshot.sessions.count, 1)

        var restored = AgentStateMachine(maximumTurnDuration: 10, releaseGrace: 5)
        restored.restore(activeSnapshot, at: base.addingTimeInterval(11))
        restored.ingest(event(.activity, seconds: 12))
        XCTAssertTrue(restored.activeSessions(at: base.addingTimeInterval(12)).isEmpty)

        restored.ingest(event(.promptSubmitted, turn: "turn-2", seconds: 13))
        XCTAssertEqual(restored.activeSessions(at: base.addingTimeInterval(13)).count, 1)
    }

    func testWaitingSnapshotCanResumeSameTurnAfterGraceWithoutExtendingHardLimit() {
        var original = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        original.ingest(event(.promptSubmitted))
        original.ingest(event(.waitingForInput, seconds: 1))
        let snapshot = original.recoverySnapshot(at: base.addingTimeInterval(2))

        var restored = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        restored.restore(snapshot, at: base.addingTimeInterval(7))
        XCTAssertTrue(restored.activeSessions(at: base.addingTimeInterval(7)).isEmpty)

        restored.ingest(event(.activity, seconds: 8))
        let state = restored.allSessions(at: base.addingTimeInterval(8)).first
        XCTAssertEqual(state?.phase, .working)
        XCTAssertEqual(state?.turnID, "turn-1")
        XCTAssertEqual(state?.hardDeadline, base.addingTimeInterval(100))
    }

    func testRestoreKeepsNewestDuplicateAndNewerTombstoneWins() throws {
        var original = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        original.ingest(event(.promptSubmitted))
        var older = try XCTUnwrap(original.allSessions(at: base).first)
        var newer = older
        older.lastEventAt = base.addingTimeInterval(1)
        newer.turnID = "turn-2"
        newer.turnStartedAt = base.addingTimeInterval(2)
        newer.lastEventAt = base.addingTimeInterval(2)
        newer.hardDeadline = base.addingTimeInterval(102)

        var restored = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        restored.restore(
            AgentStateRecoverySnapshot(sessions: [older, newer], tombstones: []),
            at: base.addingTimeInterval(3)
        )
        XCTAssertEqual(restored.allSessions(at: base.addingTimeInterval(3)).first?.turnID, "turn-2")

        restored.restore(
            AgentStateRecoverySnapshot(
                sessions: [newer],
                tombstones: [AgentSessionTombstone(
                    key: newer.key,
                    timestamp: base.addingTimeInterval(3),
                    turnID: "turn-2"
                )]
            ),
            at: base.addingTimeInterval(4)
        )
        XCTAssertTrue(restored.activeSessions(at: base.addingTimeInterval(4)).isEmpty)
    }

    func testUnsupportedOrFutureRecoveryCannotReplaceLiveState() throws {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        machine.ingest(event(.promptSubmitted))
        let live = try XCTUnwrap(machine.allSessions(at: base).first)
        machine.restore(
            AgentStateRecoverySnapshot(
                schemaVersion: 99,
                sessions: [],
                tombstones: []
            ),
            at: base.addingTimeInterval(1)
        )
        XCTAssertEqual(machine.allSessions(at: base.addingTimeInterval(1)).first?.turnID, live.turnID)

        var future = live
        future.turnStartedAt = base.addingTimeInterval(1_000)
        future.lastEventAt = base.addingTimeInterval(1_000)
        future.hardDeadline = base.addingTimeInterval(1_100)
        var empty = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        empty.restore(
            AgentStateRecoverySnapshot(sessions: [future], tombstones: []),
            at: base
        )
        XCTAssertTrue(empty.allSessions(at: base).isEmpty)
    }

    func testV1RecoveryKeepsStoredGraceAndIsNeverSleepEligible() throws {
        var source = AgentStateMachine(maximumTurnDuration: 1_000, releaseGrace: 300)
        source.ingest(event(.promptSubmitted))
        var legacyState = try XCTUnwrap(source.allSessions(at: base).first)
        legacyState.phase = .turnStopped
        legacyState.graceDeadline = base.addingTimeInterval(301)
        legacyState.turnStopObserved = true
        legacyState.terminalDisposition = .successfulCompletion

        let encoded = try JSONEncoder().encode(AgentStateRecoverySnapshot(
            schemaVersion: 1,
            sessions: [legacyState],
            tombstones: []
        ))
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var sessions = try XCTUnwrap(root["sessions"] as? [[String: Any]])
        for key in [
            "backgroundWorkTokens",
            "completedBackgroundWorkTokens",
            "stopHookActive",
            "terminalDisposition",
        ] {
            sessions[0].removeValue(forKey: key)
        }
        root["sessions"] = sessions
        let legacyData = try JSONSerialization.data(withJSONObject: root)
        let legacySnapshot = try JSONDecoder().decode(
            AgentStateRecoverySnapshot.self,
            from: legacyData
        )

        var restored = AgentStateMachine(
            maximumTurnDuration: 1_000,
            completionConfirmation: 5,
            waitingGrace: 300
        )
        restored.restore(legacySnapshot, at: base.addingTimeInterval(10))
        let active = restored.allSessions(at: base.addingTimeInterval(10)).first
        XCTAssertEqual(active?.phase, .turnStopped)
        XCTAssertEqual(active?.graceDeadline, base.addingTimeInterval(301))
        XCTAssertEqual(active?.terminalDisposition, .legacyRelease)

        let finished = restored.allSessions(at: base.addingTimeInterval(301)).first
        XCTAssertEqual(finished?.phase, .finished)
        XCTAssertFalse(finished?.isSleepEligibleCompletion(at: base.addingTimeInterval(301)) == true)
    }

    func testV1AgentEventIsAcceptedDuringBridgeRepair() {
        var machine = AgentStateMachine(
            maximumTurnDuration: 1_000,
            completionConfirmation: 5,
            waitingGrace: 300
        )
        machine.ingest(event(.promptSubmitted, schema: 1))
        XCTAssertEqual(machine.activeSessions(at: base).count, 1)
        machine.ingest(event(.turnStopped, seconds: 1, background: false, schema: 1))

        let legacy = machine.allSessions(at: base.addingTimeInterval(1)).first
        XCTAssertEqual(legacy?.phase, .turnStopped)
        XCTAssertEqual(legacy?.graceDeadline, base.addingTimeInterval(301))
        XCTAssertEqual(legacy?.terminalDisposition, .legacyRelease)
        let finished = machine.allSessions(at: base.addingTimeInterval(301)).first
        XCTAssertFalse(finished?.isSleepEligibleCompletion(at: base.addingTimeInterval(301)) == true)
    }

    func testV2TurnStoppedRemainsLegacyAndCannotForceSleepDuringRepair() {
        var machine = AgentStateMachine(
            maximumTurnDuration: 1_000,
            completionConfirmation: 5,
            waitingGrace: 300
        )
        machine.ingest(event(.promptSubmitted, schema: 2))
        machine.ingest(event(.turnStopped, seconds: 1, background: false, schema: 2))

        let legacy = machine.allSessions(at: base.addingTimeInterval(1)).first
        XCTAssertEqual(legacy?.phase, .turnStopped)
        XCTAssertEqual(legacy?.graceDeadline, base.addingTimeInterval(301))
        XCTAssertEqual(legacy?.terminalDisposition, .legacyRelease)
        XCTAssertFalse(
            machine.allSessions(at: base.addingTimeInterval(301)).first?
                .isSleepEligibleCompletion(at: base.addingTimeInterval(301)) == true
        )
    }

    func testV1AndV2WaitingEventsKeepDelayButCanOnlyReleasePolicy() throws {
        for schema in [1, 2] {
            var machine = AgentStateMachine(
                maximumTurnDuration: 1_000,
                completionConfirmation: 5,
                waitingGrace: 300
            )
            XCTAssertEqual(machine.ingest(event(.promptSubmitted, schema: schema)), .accepted)
            XCTAssertEqual(
                machine.ingest(event(.waitingForInput, seconds: 1, schema: schema)),
                .accepted
            )

            let waiting = try XCTUnwrap(
                machine.allSessions(at: base.addingTimeInterval(1)).first
            )
            XCTAssertEqual(waiting.phase, .waitingForInput, "schema \(schema)")
            XCTAssertEqual(waiting.waitingStartedAt, base.addingTimeInterval(1),
                           "schema \(schema)")
            XCTAssertEqual(waiting.graceDeadline, base.addingTimeInterval(301),
                           "schema \(schema)")
            XCTAssertEqual(waiting.terminalDisposition, .legacyRelease, "schema \(schema)")
            XCTAssertEqual(machine.activeSessions(at: base.addingTimeInterval(300)).count, 1,
                           "schema \(schema)")

            let expired = try XCTUnwrap(
                machine.allSessions(at: base.addingTimeInterval(301)).first
            )
            XCTAssertEqual(expired.phase, .finished, "schema \(schema)")
            XCTAssertEqual(expired.terminalDisposition, .legacyRelease, "schema \(schema)")
            XCTAssertFalse(expired.isConditionalSleepEligibleTerminal(
                at: base.addingTimeInterval(301)
            ), "schema \(schema)")
        }
    }

    func testLegacyWaitWithBackgroundWorkAndLateStopRemainsReleaseOnly() throws {
        for schema in [1, 2] {
            var machine = AgentStateMachine(
                maximumTurnDuration: 1_000,
                completionConfirmation: 5,
                waitingGrace: 300
            )
            machine.ingest(event(.promptSubmitted, schema: schema))
            machine.ingest(event(.waitingForInput, seconds: 1, schema: schema))
            machine.ingest(event(
                .backgroundWorkChanged,
                seconds: 2,
                background: true,
                workToken: tokenA,
                schema: schema
            ))
            machine.ingest(event(.turnCompleted, seconds: 3, schema: schema))
            machine.ingest(event(
                .backgroundWorkChanged,
                seconds: 4,
                background: false,
                workToken: tokenA,
                schema: schema
            ))

            let waiting = try XCTUnwrap(machine.allSessions(
                at: base.addingTimeInterval(4)
            ).first)
            XCTAssertEqual(waiting.phase, .waitingForInput, "schema \(schema)")
            XCTAssertEqual(waiting.graceDeadline, base.addingTimeInterval(301),
                           "schema \(schema)")
            XCTAssertEqual(waiting.terminalDisposition, .legacyRelease, "schema \(schema)")

            let expired = try XCTUnwrap(machine.allSessions(
                at: base.addingTimeInterval(301)
            ).first)
            XCTAssertEqual(expired.phase, .finished, "schema \(schema)")
            XCTAssertEqual(expired.terminalDisposition, .legacyRelease, "schema \(schema)")
            XCTAssertFalse(expired.isConditionalSleepEligibleTerminal(
                at: base.addingTimeInterval(301)
            ), "schema \(schema)")
        }
    }

    func testV1AndV2WaitingRecoveryKeepsDeadlineButMigratesToReleaseOnly() throws {
        for schema in [1, 2] {
            var source = AgentStateMachine(
                maximumTurnDuration: 1_000,
                completionConfirmation: 5,
                waitingGrace: 300
            )
            source.ingest(event(.promptSubmitted))
            source.ingest(event(.waitingForInput, seconds: 1))
            let current = try XCTUnwrap(source.allSessions(
                at: base.addingTimeInterval(1)
            ).first)

            let encoded = try JSONEncoder().encode(AgentStateRecoverySnapshot(
                schemaVersion: schema,
                sessions: [current],
                tombstones: []
            ))
            var root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            var sessions = try XCTUnwrap(root["sessions"] as? [[String: Any]])
            sessions[0].removeValue(forKey: "turnRole")
            sessions[0].removeValue(forKey: "waitingStartedAt")
            sessions[0].removeValue(forKey: "waitingObserved")
            sessions[0].removeValue(forKey: "terminalDisposition")
            if schema == 1 {
                sessions[0].removeValue(forKey: "backgroundWorkTokens")
                sessions[0].removeValue(forKey: "completedBackgroundWorkTokens")
                sessions[0].removeValue(forKey: "stopHookActive")
            }
            root["sessions"] = sessions
            let legacy = try JSONDecoder().decode(
                AgentStateRecoverySnapshot.self,
                from: JSONSerialization.data(withJSONObject: root)
            )

            var restored = AgentStateMachine(
                maximumTurnDuration: 1_000,
                completionConfirmation: 5,
                waitingGrace: 300
            )
            restored.restore(legacy, at: base.addingTimeInterval(10))

            let waiting = try XCTUnwrap(restored.allSessions(
                at: base.addingTimeInterval(10)
            ).first)
            XCTAssertEqual(waiting.phase, .waitingForInput, "schema \(schema)")
            XCTAssertTrue(waiting.waitingObserved, "schema \(schema)")
            XCTAssertEqual(waiting.waitingStartedAt, base.addingTimeInterval(1),
                           "schema \(schema)")
            XCTAssertEqual(waiting.graceDeadline, base.addingTimeInterval(301),
                           "schema \(schema)")
            XCTAssertEqual(waiting.terminalDisposition, .legacyRelease, "schema \(schema)")

            let expired = try XCTUnwrap(restored.allSessions(
                at: base.addingTimeInterval(301)
            ).first)
            XCTAssertEqual(expired.phase, .finished, "schema \(schema)")
            XCTAssertEqual(expired.terminalDisposition, .legacyRelease, "schema \(schema)")
            XCTAssertFalse(expired.isConditionalSleepEligibleTerminal(
                at: base.addingTimeInterval(301)
            ), "schema \(schema)")
        }
    }

    func testLegacyActivityOnlyRefreshesAnAlreadyWorkingTurn() {
        var working = AgentStateMachine(maximumTurnDuration: 1_000, releaseGrace: 300)
        working.ingest(event(.promptSubmitted))
        XCTAssertEqual(
            working.ingest(event(.activity, seconds: 1, schema: 2)),
            .accepted
        )
        let refreshed = working.allSessions(at: base.addingTimeInterval(1)).first
        XCTAssertEqual(refreshed?.phase, .working)
        XCTAssertEqual(refreshed?.lastEventAt, base.addingTimeInterval(1))

        var waiting = AgentStateMachine(maximumTurnDuration: 1_000, releaseGrace: 300)
        waiting.ingest(event(.promptSubmitted))
        waiting.ingest(event(.waitingForInput, seconds: 2))
        let waitingDeadline = waiting.allSessions(at: base.addingTimeInterval(2)).first?
            .graceDeadline
        XCTAssertEqual(
            waiting.ingest(event(.activity, seconds: 3, schema: 2)),
            .duplicate
        )
        let stillWaiting = waiting.allSessions(at: base.addingTimeInterval(3)).first
        XCTAssertEqual(stillWaiting?.phase, .waitingForInput)
        XCTAssertEqual(stillWaiting?.graceDeadline, waitingDeadline)
        XCTAssertEqual(stillWaiting?.lastEventAt, base.addingTimeInterval(2))

        var completed = AgentStateMachine(
            maximumTurnDuration: 1_000,
            completionConfirmation: 5,
            waitingGrace: 300
        )
        completed.ingest(event(.promptSubmitted))
        completed.ingest(event(.turnCompleted, seconds: 2))
        let completionDeadline = completed.allSessions(at: base.addingTimeInterval(2)).first?
            .graceDeadline
        XCTAssertEqual(
            completed.ingest(event(.activity, seconds: 3, schema: 1)),
            .duplicate
        )
        let stillCompleted = completed.allSessions(at: base.addingTimeInterval(3)).first
        XCTAssertEqual(stillCompleted?.phase, .pendingCompletion)
        XCTAssertEqual(stillCompleted?.graceDeadline, completionDeadline)
        XCTAssertEqual(stillCompleted?.lastEventAt, base.addingTimeInterval(2))

        var missing = AgentStateMachine(maximumTurnDuration: 1_000, releaseGrace: 300)
        XCTAssertEqual(
            missing.ingest(event(.activity, schema: 2)),
            .missingTurn
        )
        XCTAssertTrue(missing.allSessions(at: base).isEmpty)
    }

    func testLateBackgroundStopCannotUpgradeFailedTurnToSuccessfulCompletion() {
        var machine = AgentStateMachine(
            maximumTurnDuration: 1_000,
            completionConfirmation: 5,
            waitingGrace: 300
        )
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(
            .backgroundWorkChanged,
            seconds: 1,
            background: true,
            workToken: tokenA
        ))
        machine.ingest(event(.turnFailed, seconds: 2))

        XCTAssertEqual(
            machine.ingest(event(
                .backgroundWorkChanged,
                seconds: 3,
                background: false,
                workToken: tokenA
            )),
            .duplicate
        )
        let failed = machine.allSessions(at: base.addingTimeInterval(3)).first
        XCTAssertEqual(failed?.phase, .finished)
        XCTAssertEqual(failed?.terminalDisposition, .failed)
        XCTAssertNil(failed?.graceDeadline)
        XCTAssertEqual(failed?.lastEventAt, base.addingTimeInterval(2))
        XCTAssertFalse(
            failed?.isConditionalSleepEligibleTerminal(
                at: base.addingTimeInterval(3)
            ) == true
        )
    }

    func testUnknownSchemaIsIgnored() {
        var machine = AgentStateMachine()
        machine.ingest(event(.promptSubmitted, schema: 99))
        XCTAssertTrue(machine.allSessions(at: base).isEmpty)
    }

    func testSameSessionDifferentTurnsRemainIndependentAndAggregateToOneWakeSource() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        machine.ingest(event(.promptSubmitted, turn: "root-turn"))
        machine.ingest(event(.toolStarted, turn: "child-turn", seconds: 1))

        XCTAssertEqual(machine.allTurns(at: base.addingTimeInterval(1)).count, 2)
        XCTAssertEqual(machine.activeTurns(at: base.addingTimeInterval(1)).count, 2)
        XCTAssertEqual(machine.activeSessions(at: base.addingTimeInterval(1)).count, 1)
        XCTAssertEqual(machine.sessionAggregates(at: base.addingTimeInterval(1)).first?.workingCount, 2)

        machine.ingest(event(.turnCompleted, turn: "child-turn", seconds: 2))
        XCTAssertEqual(machine.activeSessions(at: base.addingTimeInterval(7)).count, 1)
        XCTAssertEqual(
            machine.state(
                for: AgentTurnKey(provider: .codex,
                                  sessionID: "session-1",
                                  turnID: "root-turn"),
                at: base.addingTimeInterval(7)
            )?.phase,
            .working
        )
    }

    func testIndependentRootTasksExposeWorkingAndWaitingPartitions() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 20)
        machine.ingest(event(.promptSubmitted, session: "working-root", turn: "working"))
        machine.ingest(event(.promptSubmitted, session: "waiting-root", turn: "waiting"))
        machine.ingest(event(
            .waitingForInput,
            session: "waiting-root",
            turn: "waiting",
            seconds: 1
        ))

        let aggregates = Dictionary(uniqueKeysWithValues: machine.sessionAggregates(
            at: base.addingTimeInterval(1)
        ).map { ($0.key.sessionID, $0) })
        XCTAssertEqual(aggregates.count, 2)
        XCTAssertEqual(aggregates["working-root"]?.workingCount, 1)
        XCTAssertEqual(aggregates["working-root"]?.waitingCount, 0)
        XCTAssertEqual(aggregates["waiting-root"]?.workingCount, 0)
        XCTAssertEqual(aggregates["waiting-root"]?.waitingCount, 1)
        XCTAssertEqual(machine.activeSessions(at: base.addingTimeInterval(1)).count, 2)
    }

    func testNewPrimaryTurnRetiresPreviousPrimaryButKeepsAuxiliaryTurn() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        machine.ingest(event(.promptSubmitted, turn: "root-1"))
        machine.ingest(event(.toolStarted, turn: "child", seconds: 1))
        machine.ingest(event(.promptSubmitted, turn: "root-2", seconds: 2))

        let states = Dictionary(uniqueKeysWithValues: machine.allTurns(
            at: base.addingTimeInterval(2)
        ).compactMap { state in state.turnID.map { ($0, state) } })
        XCTAssertNil(states["root-1"])
        XCTAssertEqual(states["child"]?.phase, .working)
        XCTAssertEqual(states["root-2"]?.phase, .working)
        XCTAssertEqual(machine.activeSessions(at: base.addingTimeInterval(2)).count, 1)
        XCTAssertEqual(
            machine.ingest(event(.toolStarted, turn: "root-1", seconds: 3)),
            .tombstoned
        )
    }

    func testLateToolFinishedCannotResurrectCompletedTurn() {
        var machine = AgentStateMachine(
            maximumTurnDuration: 100,
            completionConfirmation: 5,
            waitingGrace: 20
        )
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.turnCompleted, seconds: 1))
        let originalDeadline = machine.allSessions(at: base.addingTimeInterval(1)).first?
            .graceDeadline

        XCTAssertEqual(machine.ingest(event(.toolFinished, seconds: 2)), .duplicate)
        let state = machine.allSessions(at: base.addingTimeInterval(2)).first
        XCTAssertEqual(state?.phase, .pendingCompletion)
        XCTAssertEqual(state?.graceDeadline, originalDeadline)
        XCTAssertTrue(machine.activeSessions(at: base.addingTimeInterval(6)).isEmpty)
    }

    func testInputReceivedResumesWaitingTurnAndClearsWaitReason() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 10)
        machine.ingest(event(.promptSubmitted))
        machine.ingest(AgentEvent(
            provider: .codex,
            sessionID: "session-1",
            turnID: "turn-1",
            eventKind: .waitingForInput,
            waitingReason: .planConfirmation,
            timestamp: base.addingTimeInterval(1)
        ))
        XCTAssertEqual(machine.allSessions(at: base.addingTimeInterval(1)).first?.waitingReason,
                       .planConfirmation)

        machine.ingest(event(.inputReceived, seconds: 2))
        let resumed = machine.allSessions(at: base.addingTimeInterval(2)).first
        XCTAssertEqual(resumed?.phase, .working)
        XCTAssertNil(resumed?.waitingReason)
        XCTAssertNil(resumed?.graceDeadline)
    }

    func testPlanNotifyReplacesEarlierOrdinaryCompletionWindow() {
        var machine = AgentStateMachine(
            maximumTurnDuration: 100,
            completionConfirmation: 5,
            waitingGrace: 20
        )
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.turnCompleted, seconds: 1))
        XCTAssertEqual(
            machine.allSessions(at: base.addingTimeInterval(1)).first?.phase,
            .pendingCompletion
        )

        let result = machine.ingest(AgentEvent(
            provider: .codex,
            sessionID: "session-1",
            turnID: "turn-1",
            eventKind: .waitingForInput,
            waitingReason: .planConfirmation,
            timestamp: base.addingTimeInterval(2)
        ))

        XCTAssertEqual(result, .accepted)
        let waiting = machine.allSessions(at: base.addingTimeInterval(2)).first
        XCTAssertEqual(waiting?.phase, .waitingForInput)
        XCTAssertEqual(waiting?.waitingReason, .planConfirmation)
        XCTAssertEqual(waiting?.graceDeadline, base.addingTimeInterval(22))
    }

    func testDuplicateAndOutOfOrderEventsReportPrivacySafeDisposition() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        let prompt = event(.promptSubmitted)
        XCTAssertEqual(machine.ingest(prompt), .accepted)
        XCTAssertEqual(machine.ingest(prompt), .duplicate)
        XCTAssertEqual(machine.lastIngestDisposition, .duplicate)
        XCTAssertEqual(machine.ingest(event(.turnCompleted, seconds: 5)), .accepted)
        XCTAssertEqual(machine.ingest(event(.toolStarted, seconds: 4)), .stale)
        XCTAssertEqual(machine.ingest(event(.toolFinished, seconds: 6)), .duplicate)
    }

    func testCancellationPreemptsStaleOrderingAndTombstonesExactTurn() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.toolStarted, seconds: 10))

        // Rollout reconciliation can observe the interrupt before a hook event
        // already queued on the socket. Cancellation remains authoritative even
        // though its source timestamp is older than the last accepted hook.
        XCTAssertEqual(machine.ingest(event(.turnCancelled, seconds: 5)), .accepted)

        let turnKey = AgentTurnKey(
            provider: .codex,
            sessionID: "session-1",
            turnID: "turn-1"
        )
        let cancelled = machine.state(for: turnKey, at: base.addingTimeInterval(10))
        XCTAssertEqual(cancelled?.phase, .finished)
        XCTAssertEqual(cancelled?.terminalDisposition, .cancelled)
        XCTAssertEqual(cancelled?.lastEventAt, base.addingTimeInterval(10))
        XCTAssertNil(cancelled?.hardDeadline)
        XCTAssertTrue(machine.activeTurns(at: base.addingTimeInterval(10)).isEmpty)

        machine.updatePolicy(
            maximumTurnDuration: 20,
            completionConfirmation: 5,
            waitingGrace: 5
        )
        let afterUpdatedDeadline = machine.state(
            for: turnKey,
            at: base.addingTimeInterval(30)
        )
        XCTAssertEqual(afterUpdatedDeadline?.phase, .finished)
        XCTAssertEqual(afterUpdatedDeadline?.terminalDisposition, .cancelled)

        XCTAssertEqual(machine.ingest(event(.toolFinished, seconds: 11)), .tombstoned)
        XCTAssertEqual(machine.ingest(event(.toolStarted, seconds: 12)), .tombstoned)
        XCTAssertEqual(machine.ingest(event(.turnCompleted, seconds: 13)), .tombstoned)
        XCTAssertEqual(
            machine.state(for: turnKey, at: base.addingTimeInterval(13))?
                .terminalDisposition,
            .cancelled
        )

        let snapshot = machine.recoverySnapshot(at: base.addingTimeInterval(13))
        XCTAssertEqual(snapshot.schemaVersion, 3)
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertEqual(snapshot.tombstones.count, 1)
        XCTAssertEqual(snapshot.tombstones.first?.turnID, "turn-1")

        var restored = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        restored.restore(snapshot, at: base.addingTimeInterval(14))
        XCTAssertEqual(restored.ingest(event(.toolStarted, seconds: 15)), .tombstoned)
        XCTAssertTrue(restored.activeTurns(at: base.addingTimeInterval(15)).isEmpty)
    }

    func testCancellationWithoutStateCreatesOnlyExactTurnTombstone() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)

        XCTAssertEqual(
            machine.ingest(event(.turnCancelled, turn: nil, seconds: 1)),
            .missingTurn
        )
        XCTAssertEqual(
            machine.ingest(event(.turnCancelled, turn: "missing-prompt", seconds: 2)),
            .accepted
        )
        XCTAssertTrue(machine.allTurns(at: base.addingTimeInterval(2)).isEmpty)
        let snapshot = machine.recoverySnapshot(at: base.addingTimeInterval(2))
        XCTAssertEqual(snapshot.tombstones.map(\.turnID), ["missing-prompt"])
        XCTAssertFalse(snapshot.tombstones.contains { $0.turnID == nil })

        XCTAssertEqual(machine.ingest(event(
            .promptSubmitted,
            turn: "missing-prompt",
            seconds: 3
        )), .tombstoned)
        XCTAssertEqual(machine.ingest(event(
            .promptSubmitted,
            turn: "new-turn",
            seconds: 3
        )), .accepted)
        XCTAssertEqual(machine.activeTurns(at: base.addingTimeInterval(3)).map(\.turnID),
                       ["new-turn"])
    }

    func testCancellationPreservesSiblingTurnsInSharedSession() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        machine.ingest(event(.promptSubmitted, turn: "root"))
        machine.ingest(event(.toolStarted, turn: "child", seconds: 1))

        XCTAssertEqual(machine.ingest(event(
            .turnCancelled,
            turn: "root",
            seconds: 2
        )), .accepted)

        let states = Dictionary(uniqueKeysWithValues: machine.allTurns(
            at: base.addingTimeInterval(2)
        ).compactMap { state in state.turnID.map { ($0, state) } })
        XCTAssertEqual(states["root"]?.phase, .finished)
        XCTAssertEqual(states["root"]?.terminalDisposition, .cancelled)
        XCTAssertEqual(states["child"]?.phase, .working)
        XCTAssertEqual(machine.activeTurns(at: base.addingTimeInterval(2)).map(\.turnID),
                       ["child"])
        XCTAssertEqual(machine.ingest(event(
            .toolStarted,
            turn: "root",
            seconds: 3
        )), .tombstoned)
        XCTAssertEqual(machine.ingest(event(
            .toolStarted,
            turn: "child",
            seconds: 3
        )), .accepted)
    }

    func testCancellationTombstonesAreLimitedTo24HoursAnd256Entries() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        for index in 0..<300 {
            XCTAssertEqual(machine.ingest(event(
                .turnCancelled,
                session: "bounded",
                turn: "cancelled-\(index)",
                seconds: TimeInterval(index)
            )), .accepted)
        }

        let bounded = machine.recoverySnapshot(at: base.addingTimeInterval(299))
        XCTAssertEqual(bounded.tombstones.count, 256)
        XCTAssertTrue(bounded.tombstones.contains { $0.turnID == "cancelled-299" })
        XCTAssertFalse(bounded.tombstones.contains { $0.turnID == "cancelled-0" })

        let afterRetention = 24 * 60 * 60 + 300.0
        XCTAssertEqual(machine.ingest(event(
            .turnCancelled,
            session: "bounded",
            turn: "fresh-cancellation",
            seconds: afterRetention
        )), .accepted)
        let expired = machine.recoverySnapshot(
            at: base.addingTimeInterval(afterRetention)
        )
        XCTAssertEqual(expired.tombstones.map(\.turnID), ["fresh-cancellation"])
        XCTAssertEqual(machine.ingest(event(
            .promptSubmitted,
            session: "bounded",
            turn: "cancelled-299",
            seconds: afterRetention + 1
        )), .accepted)
    }

    func testV3RecoveryPreservesIndependentTurnsAndDropsExpiredCompletion() {
        var original = AgentStateMachine(
            maximumTurnDuration: 100,
            completionConfirmation: 5,
            waitingGrace: 20
        )
        original.ingest(event(.promptSubmitted, turn: "root"))
        original.ingest(event(.toolStarted, turn: "child", seconds: 1))
        original.ingest(event(.turnCompleted, turn: "child", seconds: 2))
        let snapshot = original.recoverySnapshot(at: base.addingTimeInterval(8))

        XCTAssertEqual(snapshot.schemaVersion, 3)
        XCTAssertEqual(snapshot.sessions.map(\.turnID), ["root"])
        XCTAssertEqual(snapshot.tombstones.map(\.turnID), ["child"])

        var restored = AgentStateMachine(
            maximumTurnDuration: 100,
            completionConfirmation: 5,
            waitingGrace: 20
        )
        restored.restore(snapshot, at: base.addingTimeInterval(8))
        XCTAssertEqual(restored.allTurns(at: base.addingTimeInterval(8)).map(\.turnID), ["root"])
        XCTAssertEqual(restored.activeSessions(at: base.addingTimeInterval(8)).count, 1)
        XCTAssertEqual(restored.ingest(event(.toolStarted, turn: "child", seconds: 9)),
                       .tombstoned)
    }

    func testWaitingPolicyChangeReanchorsToInitialWaitNotDuplicateEvent() {
        var machine = AgentStateMachine(
            maximumTurnDuration: 1_000,
            completionConfirmation: 5,
            waitingGrace: 300
        )
        machine.ingest(event(.promptSubmitted))
        machine.ingest(event(.waitingForInput, seconds: 10))
        machine.ingest(event(.waitingForInput, seconds: 100))

        machine.updatePolicy(
            maximumTurnDuration: 1_000,
            completionConfirmation: 5,
            waitingGrace: 60
        )
        let state = machine.allSessions(at: base.addingTimeInterval(20)).first
        XCTAssertEqual(state?.waitingStartedAt, base.addingTimeInterval(10))
        XCTAssertEqual(state?.graceDeadline, base.addingTimeInterval(70))
        XCTAssertTrue(machine.activeSessions(at: base.addingTimeInterval(70)).isEmpty)
    }

    func testV3RecoveryPreservesTwoActiveTurnsUnderOneRoot() {
        var original = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        original.ingest(event(.promptSubmitted, turn: "root"))
        original.ingest(event(.toolStarted, turn: "child", seconds: 1))

        let snapshot = original.recoverySnapshot(at: base.addingTimeInterval(2))
        XCTAssertEqual(Set(snapshot.sessions.compactMap(\.turnID)), Set(["root", "child"]))

        var restored = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        restored.restore(snapshot, at: base.addingTimeInterval(2))
        XCTAssertEqual(restored.activeTurns(at: base.addingTimeInterval(2)).count, 2)
        XCTAssertEqual(restored.activeSessions(at: base.addingTimeInterval(2)).count, 1)
        XCTAssertEqual(restored.sessionAggregates(at: base.addingTimeInterval(2)).first?.workingCount,
                       2)
    }

    func testRestoreTombstonesPersistedAuxiliaryZeroCountTokenGhost() throws {
        var source = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        source.ingest(event(
            .backgroundWorkChanged,
            turn: "child-turn",
            seconds: 1,
            background: true,
            workToken: tokenA
        ))
        var ghost = try XCTUnwrap(source.allTurns(at: base.addingTimeInterval(1)).first)
        ghost.phase = .working
        ghost.lastEventAt = base.addingTimeInterval(2)
        ghost.graceDeadline = nil
        ghost.backgroundWork = false
        ghost.backgroundWorkCount = 0
        ghost.backgroundWorkTokens = []
        ghost.completedBackgroundWorkTokens = [tokenA]
        ghost.turnStopObserved = false
        ghost.waitingObserved = false
        ghost.terminalDisposition = .none

        var restored = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        restored.restore(
            AgentStateRecoverySnapshot(sessions: [ghost], tombstones: []),
            at: base.addingTimeInterval(3)
        )

        XCTAssertTrue(restored.allTurns(at: base.addingTimeInterval(3)).isEmpty)
        XCTAssertTrue(restored.activeTurns(at: base.addingTimeInterval(3)).isEmpty)
        let migrated = restored.recoverySnapshot(at: base.addingTimeInterval(3))
        XCTAssertEqual(migrated.tombstones.map(\.turnID), ["child-turn"])
        XCTAssertEqual(migrated.tombstones.first?.timestamp, base.addingTimeInterval(2))
        XCTAssertEqual(restored.ingest(event(
            .toolStarted,
            turn: "child-turn",
            seconds: 4
        )), .tombstoned)
    }

    func testRestoreDoesNotDiscardPrimaryZeroCountTokenState() throws {
        var source = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        source.ingest(event(.promptSubmitted, turn: "root-turn"))
        var primary = try XCTUnwrap(source.allTurns(at: base).first)
        primary.completedBackgroundWorkTokens = [tokenA]

        var restored = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        restored.restore(
            AgentStateRecoverySnapshot(sessions: [primary], tombstones: []),
            at: base.addingTimeInterval(1)
        )

        XCTAssertEqual(restored.activeTurns(at: base.addingTimeInterval(1)).count, 1)
        XCTAssertEqual(restored.allTurns(at: base.addingTimeInterval(1)).first?.turnRole,
                       .primary)
    }

    func testManualEndTombstonesTurnsAndDiscoveryPlaceholders() {
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        machine.ingest(event(.promptSubmitted, turn: "root-turn"))
        machine.ingest(event(
            .backgroundWorkChanged,
            turn: "child-turn",
            seconds: 1,
            background: true,
            workToken: tokenA
        ))
        machine.ingest(event(
            .processDiscovered,
            session: "placeholder-session",
            turn: nil,
            seconds: 1
        ))

        machine.manuallyEndCurrentTurns(at: base.addingTimeInterval(2))

        XCTAssertTrue(machine.allTurns(at: base.addingTimeInterval(2)).isEmpty)
        XCTAssertTrue(machine.allSessions(at: base.addingTimeInterval(2)).isEmpty)
        let snapshot = machine.recoverySnapshot(at: base.addingTimeInterval(2))
        XCTAssertEqual(
            Set(snapshot.tombstones.compactMap(\.turnID)),
            Set(["root-turn", "child-turn"])
        )
        XCTAssertTrue(snapshot.tombstones.contains {
            $0.key.sessionID == "placeholder-session" && $0.turnID == nil
        })

        XCTAssertEqual(machine.ingest(event(
            .toolStarted,
            turn: "root-turn",
            seconds: 3
        )), .tombstoned)
        XCTAssertEqual(machine.ingest(event(
            .backgroundWorkChanged,
            turn: "child-turn",
            seconds: 3,
            background: false,
            workToken: tokenA
        )), .tombstoned)
        XCTAssertEqual(machine.ingest(event(
            .processDiscovered,
            session: "placeholder-session",
            turn: nil,
            seconds: 1.5
        )), .tombstoned)
        XCTAssertTrue(machine.allSessions(at: base.addingTimeInterval(3)).isEmpty)

        XCTAssertEqual(machine.ingest(event(
            .promptSubmitted,
            turn: "new-root-turn",
            seconds: 4
        )), .accepted)
        XCTAssertEqual(machine.activeTurns(at: base.addingTimeInterval(4)).count, 1)
        XCTAssertEqual(machine.ingest(event(
            .toolStarted,
            turn: "root-turn",
            seconds: 5
        )), .tombstoned)
        XCTAssertEqual(machine.allTurns(at: base.addingTimeInterval(5)).map(\.turnID),
                       ["new-root-turn"])
    }

    func testManualRestorePolicySurvivesRecoveryAndRejectsDelayedUnknownTurns() throws {
        var source = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        source.ingest(event(.promptSubmitted, turn: "retired-root"))
        source.manuallyEndCurrentTurns(at: base.addingTimeInterval(2))

        let saved = source.recoverySnapshot(at: base.addingTimeInterval(2))
        let savedBoundary = try XCTUnwrap(saved.tombstones.first {
            $0.key.sessionID == "session-1" && $0.turnID == nil
        })
        XCTAssertEqual(savedBoundary.policy, .manualRestore)

        let encoded = try JSONEncoder().encode(saved)
        let roundTripped = try JSONDecoder().decode(
            AgentStateRecoverySnapshot.self,
            from: encoded
        )
        XCTAssertEqual(roundTripped.tombstones.first {
            $0.key.sessionID == "session-1" && $0.turnID == nil
        }?.policy, .manualRestore)

        var restored = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        restored.restore(roundTripped, at: base.addingTimeInterval(3))

        XCTAssertEqual(restored.ingest(event(
            .processDiscovered,
            turn: nil,
            seconds: 4
        )), .tombstoned)
        XCTAssertEqual(restored.ingest(event(
            .sessionStarted,
            turn: nil,
            seconds: 4
        )), .tombstoned)
        XCTAssertEqual(restored.ingest(event(
            .toolStarted,
            turn: "late-unknown-tool",
            seconds: 4
        )), .tombstoned)
        XCTAssertEqual(restored.ingest(event(
            .activity,
            turn: "late-unknown-activity",
            seconds: 4
        )), .tombstoned)
        XCTAssertEqual(restored.ingest(event(
            .inputReceived,
            turn: "late-unknown-input",
            seconds: 4
        )), .tombstoned)
        XCTAssertEqual(restored.ingest(event(
            .backgroundWorkChanged,
            turn: "late-unknown-child",
            seconds: 4,
            background: true,
            workToken: tokenA
        )), .tombstoned)
        XCTAssertEqual(restored.ingest(event(
            .turnCompleted,
            turn: "late-unknown-terminal",
            seconds: 4
        )), .tombstoned)
        XCTAssertTrue(restored.activeTurns(at: base.addingTimeInterval(4)).isEmpty)

        // A delayed session terminal may advance the boundary, but it cannot
        // downgrade the manual prompt-only policy.
        XCTAssertEqual(restored.ingest(event(
            .sessionEnded,
            turn: nil,
            seconds: 4.5
        )), .accepted)
        let afterTerminal = restored.recoverySnapshot(at: base.addingTimeInterval(4.5))
        let preservedBoundary = try XCTUnwrap(afterTerminal.tombstones.first {
            $0.key.sessionID == "session-1" && $0.turnID == nil
        })
        XCTAssertEqual(preservedBoundary.policy, .manualRestore)
        XCTAssertEqual(preservedBoundary.timestamp, base.addingTimeInterval(4.5))
        XCTAssertEqual(restored.ingest(event(
            .toolStarted,
            turn: "late-after-terminal",
            seconds: 5
        )), .tombstoned)

        // The retired exact turn remains blocked; only an explicit prompt with
        // a genuinely new turn ID opens the session for future work.
        XCTAssertEqual(restored.ingest(event(
            .promptSubmitted,
            turn: "retired-root",
            seconds: 5
        )), .tombstoned)
        XCTAssertEqual(restored.ingest(event(
            .promptSubmitted,
            turn: "fresh-root",
            seconds: 5
        )), .accepted)
        XCTAssertEqual(restored.activeTurns(at: base.addingTimeInterval(5)).map(\.turnID),
                       ["fresh-root"])
    }

    func testLegacyTombstoneWithoutPolicyKeepsLifecycleRecoveryBehavior() throws {
        let snapshot = AgentStateRecoverySnapshot(
            sessions: [],
            tombstones: [AgentSessionTombstone(
                key: AgentSessionKey(provider: .codex, sessionID: "session-1"),
                timestamp: base,
                turnID: nil,
                policy: .manualRestore
            )]
        )
        let encoded = try JSONEncoder().encode(snapshot)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var tombstones = try XCTUnwrap(root["tombstones"] as? [[String: Any]])
        tombstones[0].removeValue(forKey: "policy")
        root["tombstones"] = tombstones
        let legacy = try JSONDecoder().decode(
            AgentStateRecoverySnapshot.self,
            from: JSONSerialization.data(withJSONObject: root)
        )

        XCTAssertEqual(legacy.tombstones.first?.policy, .lifecycle)
        var restored = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        restored.restore(legacy, at: base.addingTimeInterval(1))
        XCTAssertEqual(restored.ingest(event(
            .toolStarted,
            turn: "recovered-missed-prompt",
            seconds: 2
        )), .accepted)
        XCTAssertEqual(restored.activeTurns(at: base.addingTimeInterval(2)).count, 1)
    }

    func testV2RecoveryMigratesExistingTurnIDAsPrimary() throws {
        var source = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        source.ingest(event(.promptSubmitted, turn: "legacy-turn"))
        let current = try XCTUnwrap(source.allSessions(at: base).first)
        let encoded = try JSONEncoder().encode(AgentStateRecoverySnapshot(
            schemaVersion: 2,
            sessions: [current],
            tombstones: []
        ))
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var sessions = try XCTUnwrap(root["sessions"] as? [[String: Any]])
        sessions[0].removeValue(forKey: "turnRole")
        sessions[0].removeValue(forKey: "waitingStartedAt")
        root["sessions"] = sessions
        let legacy = try JSONDecoder().decode(
            AgentStateRecoverySnapshot.self,
            from: JSONSerialization.data(withJSONObject: root)
        )

        var restored = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 5)
        restored.restore(legacy, at: base.addingTimeInterval(1))
        let state = try XCTUnwrap(restored.allSessions(at: base.addingTimeInterval(1)).first)
        XCTAssertEqual(state.turnID, "legacy-turn")
        XCTAssertEqual(state.turnRole, .primary)
        XCTAssertEqual(restored.activeSessions(at: base.addingTimeInterval(1)).count, 1)
    }
}
