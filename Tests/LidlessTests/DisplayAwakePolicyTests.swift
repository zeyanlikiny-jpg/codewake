import XCTest

final class DisplayAwakePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testManualAndManualTimerAreEligible() {
        XCTAssertTrue(evaluate(sources: [.manual]))
        XCTAssertTrue(evaluate(sources: [.manualTimer]))
    }

    func testChargingAloneIsNeverEligible() {
        XCTAssertFalse(evaluate(sources: [.charging]))
    }

    func testAllDisplaysSleepTemporarilySuppressesManualAndAgentDisplayHolds() {
        let key = session("working-through-display-sleep")
        let states = [state(key, phase: .working)]
        var arbiter = WakeIntentArbiter()
        arbiter.setIntent(.manual, active: true)
        arbiter.setIntent(.agent(key), active: true)
        let decision = arbiter.decision

        XCTAssertFalse(DisplayAwakePolicy.shouldKeepDisplayAwake(
            preferenceEnabled: true,
            helperLeaseActive: true,
            systemWakeEnabled: true,
            isRestoringOrQuitting: false,
            wakeDecision: decision,
            agentStates: states,
            manualDisplaySleepActive: true,
            now: now
        ))
        XCTAssertTrue(arbiter.decision.shouldWake)
        XCTAssertEqual(arbiter.decision.activeSources, decision.activeSources)
        XCTAssertTrue(evaluate(sources: decision.activeSources, states: states))
    }

    func testWakeAfterAllDisplaysSleepUsesCurrentWorkAndPreference() {
        let key = session("finished-while-displays-asleep")
        XCTAssertFalse(evaluate(
            sources: [.agent(key)],
            states: [state(key, phase: .working)],
            manualDisplaySleepActive: true
        ))
        // Waking the displays is not permission to resurrect a completed task.
        XCTAssertFalse(evaluate(
            sources: [],
            states: [state(key, phase: .finished)]
        ))
        XCTAssertFalse(evaluate(sources: [.manual], preferenceEnabled: false))
        XCTAssertTrue(evaluate(sources: [.manual]))
    }

    func testPreferenceLeaseSystemStateAndRestoreAreMandatoryGates() {
        XCTAssertFalse(evaluate(sources: [.manual], preferenceEnabled: false))
        XCTAssertFalse(evaluate(sources: [.manual], helperLeaseActive: false))
        XCTAssertFalse(evaluate(sources: [.manual], systemWakeEnabled: false))
        XCTAssertFalse(evaluate(sources: [.manual], isRestoringOrQuitting: true))
    }

    func testSafetyVetoExcludesOtherwiseEligibleSources() {
        var arbiter = WakeIntentArbiter()
        arbiter.setIntent(.manual, active: true)
        arbiter.setSafetyVeto(.thermal, active: true)

        XCTAssertFalse(DisplayAwakePolicy.shouldKeepDisplayAwake(
            preferenceEnabled: true,
            helperLeaseActive: true,
            systemWakeEnabled: true,
            isRestoringOrQuitting: false,
            wakeDecision: arbiter.decision,
            agentStates: [],
            now: now
        ))
    }

    func testOnlyEffectiveWorkingAgentPhaseIsEligible() {
        let key = session("agent")
        for phase in [
            AgentSessionPhase.waitingForInput,
            .pendingCompletion,
            .turnStopped,
            .finished,
            .unknown,
            .hardExpired,
        ] {
            XCTAssertFalse(evaluate(
                sources: [.agent(key)],
                states: [state(key, phase: phase)]
            ), "Unexpected display hold for \(phase)")
        }

        XCTAssertTrue(evaluate(
            sources: [.agent(key)],
            states: [state(key, phase: .working)]
        ))
    }

    func testEffectiveHardDeadlineOverridesStoredWorkingPhase() {
        let key = session("expired")
        XCTAssertFalse(evaluate(
            sources: [.agent(key)],
            states: [state(
                key,
                phase: .working,
                hardDeadline: now.addingTimeInterval(-1)
            )]
        ))
    }

    func testAgentSourceMustMatchAWorkingSession() {
        let active = session("active")
        let stale = session("stale")

        XCTAssertFalse(evaluate(
            sources: [.agent(stale)],
            states: [state(active, phase: .working)]
        ))
    }

    func testAnyMatchingConcurrentWorkingTurnKeepsDisplayAwake() {
        let key = session("shared-root")
        XCTAssertTrue(evaluate(
            sources: [.agent(key)],
            states: [
                state(key, turnID: "waiting", phase: .waitingForInput),
                state(key, turnID: "working", phase: .working),
            ]
        ))
    }

    func testMixedChargingAndWorkingAgentSourcesRemainEligible() {
        let key = session("mixed")
        XCTAssertTrue(evaluate(
            sources: [.charging, .agent(key)],
            states: [state(key, phase: .working)]
        ))
    }

    private func evaluate(
        sources: Set<WakeIntentSource>,
        states: [AgentSessionState] = [],
        preferenceEnabled: Bool = true,
        helperLeaseActive: Bool = true,
        systemWakeEnabled: Bool = true,
        isRestoringOrQuitting: Bool = false,
        manualDisplaySleepActive: Bool = false
    ) -> Bool {
        var arbiter = WakeIntentArbiter()
        for source in sources {
            arbiter.setIntent(source, active: true)
        }
        return DisplayAwakePolicy.shouldKeepDisplayAwake(
            preferenceEnabled: preferenceEnabled,
            helperLeaseActive: helperLeaseActive,
            systemWakeEnabled: systemWakeEnabled,
            isRestoringOrQuitting: isRestoringOrQuitting,
            wakeDecision: arbiter.decision,
            agentStates: states,
            manualDisplaySleepActive: manualDisplaySleepActive,
            now: now
        )
    }

    private func session(_ id: String) -> AgentSessionKey {
        AgentSessionKey(provider: .codex, sessionID: id)
    }

    private func state(
        _ key: AgentSessionKey,
        turnID: String = "turn",
        phase: AgentSessionPhase,
        hardDeadline: Date? = nil
    ) -> AgentSessionState {
        AgentSessionState(
            key: key,
            phase: phase,
            turnID: turnID,
            turnStartedAt: now.addingTimeInterval(-10),
            hardDeadline: hardDeadline ?? now.addingTimeInterval(100),
            lastActivityAt: now.addingTimeInterval(-5),
            lastEventAt: now.addingTimeInterval(-5),
            graceDeadline: phase == .waitingForInput || phase == .pendingCompletion
                ? now.addingTimeInterval(100) : nil,
            backgroundWork: false,
            backgroundWorkCount: 0,
            turnStopObserved: false,
            waitingObserved: phase == .waitingForInput,
            lastBackgroundSignalAt: nil,
            lastBackgroundSignalValue: nil
        )
    }
}
