import XCTest

final class WakeIntentArbiterTests: XCTestCase {
    func testPresentationRequiresOwnedLeaseAndPermittedSource() {
        let agent = WakeIntentSource.agent(
            AgentSessionKey(provider: .codex, sessionID: "session")
        )
        var arbiter = WakeIntentArbiter()
        arbiter.setIntent(agent, active: true)

        XCTAssertFalse(
            arbiter.decision.hasVerifiedActiveWakeHold(
                systemKeepAwake: true,
                helperLeaseActive: false
            )
        )
        XCTAssertTrue(
            arbiter.decision.hasVerifiedActiveWakeHold(
                systemKeepAwake: true,
                helperLeaseActive: true
            )
        )

        arbiter.setSafetyVeto(.agentOnBattery, active: true)
        XCTAssertFalse(
            arbiter.decision.hasVerifiedActiveWakeHold(
                systemKeepAwake: true,
                helperLeaseActive: true
            ),
            "An external/system SleepDisabled=1 must not make a vetoed Lidless source green"
        )
    }

    private let agent = WakeIntentSource.agent(
        AgentSessionKey(provider: .codex, sessionID: "session")
    )

    func testAnySourceRequestsWakeAndReleaseIsIndependent() {
        var arbiter = WakeIntentArbiter()
        arbiter.setIntent(.manual, active: true)
        arbiter.setIntent(agent, active: true)
        XCTAssertTrue(arbiter.decision.shouldWake)
        arbiter.setIntent(agent, active: false)
        XCTAssertTrue(arbiter.decision.shouldWake)
        XCTAssertEqual(arbiter.decision.activeSources, [.manual])
    }

    func testLastSourceReleaseRestoresSleepRequest() {
        var arbiter = WakeIntentArbiter()
        arbiter.setIntent(.manualTimer, active: true)
        XCTAssertEqual(arbiter.decision.activeSources, [.manualTimer])
        arbiter.setIntent(.manualTimer, active: false)
        XCTAssertFalse(arbiter.decision.shouldWake)
        XCTAssertTrue(arbiter.decision.activeSources.isEmpty)
    }

    func testSafetyVetoOverridesAllSourcesWithoutDeletingIntent() {
        var arbiter = WakeIntentArbiter()
        arbiter.setIntent(.manual, active: true)
        arbiter.setIntent(agent, active: true)
        arbiter.setSafetyVeto(.thermal, active: true)
        XCTAssertFalse(arbiter.decision.shouldWake)
        XCTAssertTrue(arbiter.decision.activeSources.isEmpty)
        XCTAssertEqual(arbiter.decision.vetoedSources, [.manual, agent])
        XCTAssertEqual(arbiter.decision.requestedSources, [.manual, agent])

        arbiter.setSafetyVeto(.thermal, active: false)
        XCTAssertTrue(arbiter.decision.shouldWake)
    }

    func testRemovingOneVetoDoesNotIgnoreAnother() {
        var arbiter = WakeIntentArbiter()
        arbiter.setIntent(.charging, active: true)
        arbiter.setSafetyVeto(.thermal, active: true)
        arbiter.setSafetyVeto(.lowBattery, active: true)
        arbiter.setSafetyVeto(.thermal, active: false)
        XCTAssertFalse(arbiter.decision.shouldWake)
        XCTAssertEqual(arbiter.decision.safetyVetoes, [.lowBattery])
    }

    func testEnteringChargingAutomationClearsManualSourcesButKeepsAgent() {
        var arbiter = WakeIntentArbiter()
        arbiter.setIntent(.manual, active: true)
        arbiter.setIntent(.manualTimer, active: true)
        arbiter.setIntent(agent, active: true)

        arbiter.clearManualIntents()

        XCTAssertEqual(arbiter.decision.requestedSources, [agent])
        XCTAssertTrue(arbiter.decision.shouldWake)
    }

    func testClearAllIntentsPreservesSafetyVetoes() {
        var arbiter = WakeIntentArbiter()
        arbiter.setIntent(.manual, active: true)
        arbiter.setIntent(agent, active: true)
        arbiter.setSafetyVeto(.thermal, active: true)
        arbiter.setSafetyVeto(.lowBattery, active: true)

        arbiter.clearAllIntents()

        XCTAssertFalse(arbiter.decision.shouldWake)
        XCTAssertTrue(arbiter.decision.requestedSources.isEmpty)
        XCTAssertTrue(arbiter.decision.activeSources.isEmpty)
        XCTAssertTrue(arbiter.decision.vetoedSources.isEmpty)
        XCTAssertEqual(arbiter.decision.safetyVetoes, [.thermal, .lowBattery])

        arbiter.setIntent(.charging, active: true)
        XCTAssertFalse(arbiter.decision.shouldWake)
        XCTAssertEqual(arbiter.decision.requestedSources, [.charging])
        XCTAssertEqual(arbiter.decision.vetoedSources, [.charging])
        XCTAssertEqual(arbiter.decision.safetyVetoes, [.thermal, .lowBattery])
    }

    func testAgentThermalVetoCannotBeDisabledByLegacyPreference() {
        XCTAssertTrue(WakeSafetyPolicy.requiresThermalVeto(
            thermalSerious: true,
            userPauseEnabled: false,
            hasAgentWork: true
        ))
        XCTAssertFalse(WakeSafetyPolicy.requiresThermalVeto(
            thermalSerious: true,
            userPauseEnabled: false,
            hasAgentWork: false
        ))
        XCTAssertTrue(WakeSafetyPolicy.requiresThermalVeto(
            thermalSerious: true,
            userPauseEnabled: true,
            hasAgentWork: false
        ))
    }
}
