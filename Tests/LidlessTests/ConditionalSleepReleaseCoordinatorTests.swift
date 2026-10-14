import XCTest

final class ConditionalSleepReleaseCoordinatorTests: XCTestCase {
    func testPolicyOnlyRestoreUsesDirectLeaseReleaseWithoutVersionProbe() {
        XCTAssertEqual(
            SleepReleasePreparationGate.action(sleepMode: .never),
            .directLeaseRelease
        )
    }

    func testClosedLidSleepStillNegotiatesConditionalSelectorSupport() {
        XCTAssertEqual(
            SleepReleasePreparationGate.action(sleepMode: .closedLid),
            .probeConditionalSleepSupport
        )
    }

    func testRepeatedTickStartsOnlyOneRelease() {
        var coordinator = ConditionalSleepReleaseCoordinator()
        XCTAssertNotNil(coordinator.beginIfIdle())
        XCTAssertNil(coordinator.beginIfIdle())
        XCTAssertTrue(coordinator.isInFlight)
    }

    func testPromptDuringVersionProbeCancelsBeforeAnyTransportMutation() {
        var coordinator = ConditionalSleepReleaseCoordinator()
        let token = coordinator.beginIfIdle()!
        XCTAssertTrue(coordinator.cancel())

        XCTAssertEqual(
            ConditionalSleepReleaseTransportGate.action(
                advertisement: LidlessHelper.currentVersionAdvertisement,
                shouldProceed: coordinator.shouldProceed(token)
            ),
            .cancelled
        )
        XCTAssertFalse(coordinator.isInFlight)
    }

    func testCodexInterruptRevokesPendingConditionalSleepBeforeTransport() {
        var coordinator = ConditionalSleepReleaseCoordinator()
        let completionToken = coordinator.beginIfIdle()!

        // AppState applies an authoritative turnCancelled edge by cancelling
        // this token before it reconciles the ordinary policy-only release.
        XCTAssertTrue(coordinator.cancel())
        XCTAssertEqual(
            ConditionalSleepReleaseTransportGate.action(
                advertisement: LidlessHelper.currentVersionAdvertisement,
                shouldProceed: coordinator.shouldProceed(completionToken)
            ),
            .cancelled
        )
        XCTAssertFalse(coordinator.isInFlight)
    }

    func testCancellationLeavesCoordinatorReadyForNewAcquire() {
        var coordinator = ConditionalSleepReleaseCoordinator()
        _ = coordinator.beginIfIdle()
        coordinator.cancel()

        XCTAssertFalse(coordinator.isInFlight,
                       "the caller may now submit the continuation acquire")
    }

    func testNormalCompletionIsConsumedExactlyOnce() {
        var coordinator = ConditionalSleepReleaseCoordinator()
        let token = coordinator.beginIfIdle()!
        XCTAssertTrue(coordinator.shouldProceed(token))
        XCTAssertTrue(coordinator.complete(token))
        XCTAssertFalse(coordinator.complete(token))
        XCTAssertFalse(coordinator.isInFlight)
    }

    func testLegacyFallbackIsAlsoCancelledBeforeRelease() {
        XCTAssertEqual(
            ConditionalSleepReleaseTransportGate.action(
                advertisement: "0.1.3",
                shouldProceed: false
            ),
            .cancelled
        )
        XCTAssertEqual(
            ConditionalSleepReleaseTransportGate.action(
                advertisement: "0.1.3",
                shouldProceed: true
            ),
            .legacyRelease
        )
    }

    func testSupersededCallbackCannotClearOrRepeatANewerGeneration() {
        var coordinator = ConditionalSleepReleaseCoordinator()
        let stale = coordinator.beginIfIdle()!
        coordinator.cancel()
        let current = coordinator.beginIfIdle()!

        XCTAssertFalse(coordinator.complete(stale))
        XCTAssertTrue(coordinator.shouldProceed(current))
        XCTAssertNil(coordinator.beginIfIdle(),
                     "a stale callback must not permit a duplicate tick")
        XCTAssertTrue(coordinator.complete(current))
    }

    func testFailedReleaseDefersToWatchdogWithoutTickRetry() {
        let transition = FailedLeaseReleaseTransition.deferToWatchdog

        XCTAssertFalse(transition.helperLeaseActive)
        XCTAssertFalse(transition.aggregateWakeRequested)
        XCTAssertFalse(transition.shouldKeepHeartbeat)
        XCTAssertFalse(transition.needsAnotherIdleRelease,
                       "consecutive idle ticks must not submit release again")
    }

    func testNewWakeSourceCanAcquireAfterFailedRelease() {
        let transition = FailedLeaseReleaseTransition.deferToWatchdog

        XCTAssertTrue(transition.needsAcquire(whenWakeRequested: true))
        XCTAssertFalse(transition.needsAcquire(whenWakeRequested: false))
    }
}
