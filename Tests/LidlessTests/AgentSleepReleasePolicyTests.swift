import XCTest

final class AgentSleepReleasePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testFinalSuccessfulCompletionRequestsSleep() {
        let key = session("final")
        XCTAssertEqual(evaluate(
            previous: [key],
            current: [],
            states: [state(key, disposition: .successfulCompletion)]
        ), .requestSleep)
    }

    func testAnotherLiveAgentPreventsFinalTransition() {
        let completed = session("completed")
        let working = session("working")
        XCTAssertEqual(evaluate(
            previous: [completed, working],
            current: [working],
            states: [
                state(completed, disposition: .successfulCompletion),
                state(working, phase: .working, disposition: .none),
            ]
        ), .noTrigger)
    }

    func testWaitingExpiryRequestsSleepButCancellationFailureAndHardLimitDoNot() {
        let waiting = session("waiting")
        XCTAssertEqual(evaluate(
            previous: [waiting],
            current: [],
            states: [state(waiting, disposition: .waitingExpired)]
        ), .requestSleep)

        for (phase, disposition) in [
            (AgentSessionPhase.finished, AgentTerminalDisposition.cancelled),
            (AgentSessionPhase.finished, AgentTerminalDisposition.failed),
            (.hardExpired, .hardLimit),
        ] {
            let key = session(disposition.rawValue)
            XCTAssertEqual(evaluate(
                previous: [key],
                current: [],
                states: [state(key, phase: phase, disposition: disposition)]
            ), .noTrigger)
        }
        XCTAssertFalse(AgentTerminalDisposition.cancelled.isSleepEligible)
    }

    func testLegacyWaitingExpiryOnlyReleasesPolicy() {
        let waiting = session("legacy-waiting")
        XCTAssertEqual(evaluate(
            previous: [waiting],
            current: [],
            states: [state(waiting, disposition: .legacyRelease)]
        ), .noTrigger)
    }

    func testManualTimerChargingAndSafetyAreReportedAsConsumedBlockers() {
        let key = session("blocked")
        XCTAssertEqual(evaluate(
            previous: [key],
            current: [],
            states: [state(key, disposition: .successfulCompletion)],
            requested: [.manual, .manualTimer, .charging],
            vetoes: [.thermal]
        ), .blocked([.manual, .timer, .charging, .safety]))
    }

    func testTurningManualHoldOffLaterCannotReplayOldCompletion() {
        let key = session("manual")
        XCTAssertEqual(evaluate(
            previous: [key],
            current: [],
            states: [state(key, disposition: .successfulCompletion)],
            requested: [.manual]
        ), .blocked([.manual]))

        XCTAssertEqual(evaluate(
            previous: [],
            current: [],
            states: [state(key, disposition: .successfulCompletion)]
        ), .noTrigger)
    }

    func testConditionalTransportFailureCannotReplayCompletionOnLaterTick() {
        let key = session("transport-failed")
        XCTAssertEqual(evaluate(
            previous: [key],
            current: [],
            states: [state(key, disposition: .successfulCompletion)]
        ), .requestSleep)

        // The transport result does not restore an Agent source. A later tick
        // may retry an ordinary lease release, but it has no completion edge and
        // therefore cannot request conditional sleep a second time.
        XCTAssertEqual(evaluate(
            previous: [],
            current: [],
            states: [state(key, disposition: .successfulCompletion)]
        ), .noTrigger)
    }

    func testEveryRemovedFinalSessionMustBeASuccessfulCompletion() {
        let success = session("success")
        let failed = session("failed")
        XCTAssertEqual(evaluate(
            previous: [success, failed],
            current: [],
            states: [
                state(success, disposition: .successfulCompletion),
                state(failed, disposition: .failed),
            ]
        ), .noTrigger)
    }

    func testOnlyTurnsActiveOnFinalEdgeDetermineConditionalSleep() {
        let key = session("shared-root")
        let retired = state(
            key,
            turnID: "retired-primary",
            disposition: .legacyRelease
        )
        let final = state(
            key,
            turnID: "current-primary",
            disposition: .successfulCompletion
        )

        XCTAssertEqual(evaluate(
            previous: [key],
            current: [],
            previousTurns: [tryTurnKey(final)],
            currentTurns: [],
            states: [retired, final]
        ), .requestSleep)
    }

    func testSimultaneousFailedSiblingPreventsConditionalSleep() {
        let key = session("shared-root")
        let success = state(
            key,
            turnID: "primary",
            disposition: .successfulCompletion
        )
        let failed = state(
            key,
            turnID: "child",
            disposition: .failed
        )

        XCTAssertEqual(evaluate(
            previous: [key],
            current: [],
            previousTurns: [tryTurnKey(success), tryTurnKey(failed)],
            currentTurns: [],
            states: [success, failed]
        ), .noTrigger)
    }

    private func evaluate(
        previous: Set<AgentSessionKey>,
        current: Set<AgentSessionKey>,
        previousTurns: Set<AgentTurnKey>? = nil,
        currentTurns: Set<AgentTurnKey>? = nil,
        states: [AgentSessionState],
        requested: Set<WakeIntentSource> = [],
        vetoes: Set<WakeSafetyVeto> = []
    ) -> AgentSleepReleaseDecision {
        AgentSleepReleasePolicy.evaluate(
            previousAgentKeys: previous,
            currentAgentKeys: current,
            previousAgentTurnKeys: previousTurns ?? Set(previous.map {
                AgentTurnKey(
                    provider: $0.provider,
                    sessionID: $0.sessionID,
                    turnID: "turn-\($0.sessionID)"
                )
            }),
            currentAgentTurnKeys: currentTurns ?? Set(current.map {
                AgentTurnKey(
                    provider: $0.provider,
                    sessionID: $0.sessionID,
                    turnID: "turn-\($0.sessionID)"
                )
            }),
            sessionStates: states,
            requestedWakeSources: requested,
            safetyVetoes: vetoes,
            now: now
        )
    }

    private func session(_ id: String) -> AgentSessionKey {
        AgentSessionKey(provider: .codex, sessionID: id)
    }

    private func state(
        _ key: AgentSessionKey,
        turnID: String? = nil,
        phase: AgentSessionPhase = .finished,
        disposition: AgentTerminalDisposition
    ) -> AgentSessionState {
        AgentSessionState(
            key: key,
            phase: phase,
            turnID: turnID ?? "turn-\(key.sessionID)",
            turnStartedAt: now.addingTimeInterval(-10),
            hardDeadline: now.addingTimeInterval(100),
            lastActivityAt: now.addingTimeInterval(-5),
            lastEventAt: now.addingTimeInterval(-5),
            graceDeadline: now,
            backgroundWork: false,
            backgroundWorkCount: 0,
            turnStopObserved: disposition == .successfulCompletion,
            waitingObserved: disposition == .waitingExpired,
            lastBackgroundSignalAt: nil,
            lastBackgroundSignalValue: nil,
            terminalDisposition: disposition
        )
    }

    private func tryTurnKey(_ state: AgentSessionState) -> AgentTurnKey {
        // Test fixtures always provide a turn ID; keep the failure obvious if a
        // future fixture accidentally becomes session-only.
        guard let key = state.turnKey else { fatalError("missing turn key") }
        return key
    }
}
