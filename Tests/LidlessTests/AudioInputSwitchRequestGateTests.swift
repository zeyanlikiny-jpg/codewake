import XCTest

final class AudioInputSwitchRequestGateTests: XCTestCase {
    func testPresentationAllowsOnlyConfigurationAndReadyActions() {
        XCTAssertTrue(AudioInputSwitchPresentation.needsConfiguration.allowsButtonAction)
        XCTAssertTrue(AudioInputSwitchPresentation.ready("Target").allowsButtonAction)

        let blocked: [AudioInputSwitchPresentation] = [
            .switching,
            .cooldown,
            .currentInputInUse,
            .currentInputActivityUnknown,
            .currentInputReconnecting("Current"),
            .currentInputUnstable,
            .targetReconnecting("Target"),
            .targetUnstable,
            .targetUnavailable("Target")
        ]
        XCTAssertTrue(blocked.allSatisfy { !$0.allowsButtonAction })
    }

    func testStateNoticesSurfaceOnlyWhileTheyMatchLivePresentation() {
        XCTAssertTrue(
            AudioInputSwitchPresentation.currentInputInUse
                .matches(.currentInputInUse)
        )
        XCTAssertTrue(
            AudioInputSwitchPresentation.currentInputActivityUnknown
                .matches(.currentInputActivityUnknown)
        )
        XCTAssertTrue(
            AudioInputSwitchPresentation.targetUnstable
                .matches(.targetUnstable)
        )
        XCTAssertTrue(
            AudioInputSwitchPresentation.targetUnavailable("Offline")
                .matches(.targetUnavailable)
        )

        XCTAssertFalse(
            AudioInputSwitchPresentation.ready("Studio Display")
                .matches(.currentInputInUse)
        )
        XCTAssertFalse(
            AudioInputSwitchPresentation.targetReconnecting("Studio Display")
                .matches(.targetUnavailable)
        )
        XCTAssertFalse(
            AudioInputSwitchPresentation.targetReconnecting("Studio Display")
                .matches(.targetUnstable)
        )
        XCTAssertFalse(
            AudioInputSwitchPresentation.currentInputUnstable
                .matches(.targetUnstable)
        )
    }

    func testCurrentInputConnectionStatePrecedesAvailabilityAndActivity() {
        XCTAssertEqual(
            AudioInputSwitchPresentation.blockingCurrentInputState(
                displayName: "Studio Display",
                stability: .reconnecting,
                observationIsTrustworthy: true,
                isAvailable: false,
                isRunningSomewhere: nil
            ),
            .currentInputReconnecting("Studio Display")
        )
        XCTAssertEqual(
            AudioInputSwitchPresentation.blockingCurrentInputState(
                displayName: "Studio Display",
                stability: .unstable,
                observationIsTrustworthy: true,
                isAvailable: true,
                isRunningSomewhere: false
            ),
            .currentInputUnstable
        )
    }

    func testStableCurrentInputStillFailsClosedForUntrustedOrUnknownActivity() {
        XCTAssertEqual(
            AudioInputSwitchPresentation.blockingCurrentInputState(
                displayName: "MacBook Pro Microphone",
                stability: .stable,
                observationIsTrustworthy: false,
                isAvailable: true,
                isRunningSomewhere: false
            ),
            .currentInputActivityUnknown
        )
        XCTAssertEqual(
            AudioInputSwitchPresentation.blockingCurrentInputState(
                displayName: "MacBook Pro Microphone",
                stability: .stable,
                observationIsTrustworthy: true,
                isAvailable: true,
                isRunningSomewhere: nil
            ),
            .currentInputActivityUnknown
        )
        XCTAssertNil(
            AudioInputSwitchPresentation.blockingCurrentInputState(
                displayName: "MacBook Pro Microphone",
                stability: .stable,
                observationIsTrustworthy: true,
                isAvailable: true,
                isRunningSomewhere: false
            )
        )
    }

    func testFirstActivationStartsGenerationAndMinimumProgressWindow() throws {
        var gate = AudioInputSwitchRequestGate()

        let token = try XCTUnwrap(gate.begin(at: 10))

        XCTAssertEqual(token.generation, 1)
        XCTAssertEqual(token.acceptedAt, 10)
        XCTAssertEqual(token.earliestProgressEnd, 10.25)
        XCTAssertTrue(gate.hasActiveRequest)
        XCTAssertEqual(gate.activeGeneration, 1)
    }

    func testActiveRequestRejectsEveryOverlappingActivation() throws {
        var gate = AudioInputSwitchRequestGate()
        _ = try XCTUnwrap(gate.begin(at: 10))

        XCTAssertNil(gate.begin(at: 10.1))
        XCTAssertNil(gate.begin(at: 20))
    }

    func testFinishedRequestStillSuppressesSecondHalfOfDoubleClickForOneSecond() throws {
        var gate = AudioInputSwitchRequestGate()
        let first = try XCTUnwrap(gate.begin(at: 10))
        XCTAssertTrue(gate.finish(first))

        XCTAssertNil(gate.begin(at: 10.999))

        let second = try XCTUnwrap(gate.begin(at: 11))
        XCTAssertEqual(second.generation, 2)
    }

    func testStaleCompletionCannotReleaseAnotherGeneration() throws {
        var gate = AudioInputSwitchRequestGate()
        let first = try XCTUnwrap(gate.begin(at: 10))
        XCTAssertTrue(gate.finish(first))
        let second = try XCTUnwrap(gate.begin(at: 11))

        XCTAssertFalse(gate.finish(first))
        XCTAssertTrue(gate.hasActiveRequest)
        XCTAssertEqual(gate.activeGeneration, second.generation)
        XCTAssertTrue(gate.finish(second))
        XCTAssertFalse(gate.hasActiveRequest)
    }

    func testRemainingProgressDurationUsesMinimumAndMatchingGeneration() throws {
        var gate = AudioInputSwitchRequestGate()
        let token = try XCTUnwrap(gate.begin(at: 10))

        XCTAssertEqual(gate.remainingProgressDuration(for: token, at: 10), 0.25)
        XCTAssertEqual(gate.remainingProgressDuration(for: token, at: 10.2), 0.05, accuracy: 0.000_001)
        XCTAssertEqual(gate.remainingProgressDuration(for: token, at: 10.25), 0)
        XCTAssertEqual(gate.remainingProgressDuration(for: token, at: 11), 0)

        XCTAssertTrue(gate.finish(token))
        XCTAssertEqual(gate.remainingProgressDuration(for: token, at: 10.1), 0)
    }

    func testRemainingSuppressionDurationSurvivesRequestCompletion() throws {
        var gate = AudioInputSwitchRequestGate()
        let token = try XCTUnwrap(gate.begin(at: 10))
        XCTAssertTrue(gate.finish(token))

        XCTAssertEqual(gate.remainingSuppressionDuration(at: 10.25), 0.75)
        XCTAssertEqual(gate.remainingSuppressionDuration(at: 11), 0)
        XCTAssertEqual(gate.remainingSuppressionDuration(at: 12), 0)
    }

    func testInvalidOrBackwardTimeCannotBypassSuppressionWindow() throws {
        var gate = AudioInputSwitchRequestGate()
        XCTAssertNil(gate.begin(at: .nan))
        let first = try XCTUnwrap(gate.begin(at: 10))
        XCTAssertTrue(gate.finish(first))

        XCTAssertNil(gate.begin(at: 9))
    }
}
