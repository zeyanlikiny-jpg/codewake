import IOKit.pwr_mgt
import XCTest

@MainActor
final class DisplaySleepAssertionControllerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testAcquireUsesNinetySecondTimeoutAndIsIdempotent() {
        var timeoutValues: [TimeInterval] = []
        var createCount = 0
        let controller = makeController(
            create: { timeout in
                timeoutValues.append(timeout)
                createCount += 1
                return (kIOReturnSuccess, IOPMAssertionID(createCount))
            }
        )

        XCTAssertEqual(controller.reconcile(shouldHold: true), .acquired)
        XCTAssertEqual(controller.reconcile(shouldHold: true), .unchanged)
        XCTAssertEqual(timeoutValues, [90])
        XCTAssertTrue(controller.isHolding)
        XCTAssertNil(controller.lastError)
    }

    func testRenewalWaitsThirtySecondsAndCreatesBeforeReleasingOldID() {
        var current = start
        var nextID: IOPMAssertionID = 10
        var events: [String] = []
        let controller = makeController(
            now: { current },
            create: { _ in
                let id = nextID
                nextID += 1
                events.append("create:\(id)")
                return (kIOReturnSuccess, id)
            },
            release: { id in
                events.append("release:\(id)")
                return kIOReturnSuccess
            }
        )

        XCTAssertEqual(controller.reconcile(shouldHold: true), .acquired)
        current = start.addingTimeInterval(29.9)
        XCTAssertEqual(controller.renewIfNeeded(), .unchanged)
        current = start.addingTimeInterval(30)
        XCTAssertEqual(controller.renewIfNeeded(), .renewed)
        XCTAssertEqual(events, ["create:10", "create:11", "release:10"])
        XCTAssertTrue(controller.isHolding)
    }

    func testCreateFailureIsStableAndRetriesOnlyAtRenewalBoundary() {
        var current = start
        var attempts = 0
        let failure = IOReturn(kIOReturnNoResources)
        let controller = makeController(
            now: { current },
            create: { _ in
                attempts += 1
                return (failure, 0)
            }
        )

        let expected = DisplaySleepAssertionError.createFailed(code: failure)
        XCTAssertEqual(controller.reconcile(shouldHold: true), .failed(expected))
        XCTAssertEqual(controller.lastError, expected)
        XCTAssertEqual(controller.lastError?.presentationKey, "display.assertion.error.create")
        XCTAssertEqual(controller.lastError?.diagnosticCode, "display_assertion_create_failed")
        XCTAssertEqual(controller.lastError?.ioReturn, failure)
        XCTAssertEqual(controller.reconcile(shouldHold: true), .unchanged)
        XCTAssertEqual(attempts, 1)

        current = start.addingTimeInterval(30)
        XCTAssertEqual(controller.renewIfNeeded(), .failed(expected))
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(controller.isHolding)
    }

    func testFailedRenewalKeepsPreviousBoundedAssertion() {
        var current = start
        var attempts = 0
        let failure = IOReturn(kIOReturnNoMemory)
        let controller = makeController(
            now: { current },
            create: { _ in
                attempts += 1
                return attempts == 1
                    ? (kIOReturnSuccess, 42)
                    : (failure, 0)
            }
        )

        XCTAssertEqual(controller.reconcile(shouldHold: true), .acquired)
        current = start.addingTimeInterval(30)
        XCTAssertEqual(
            controller.renewIfNeeded(),
            .failed(.createFailed(code: failure))
        )
        XCTAssertTrue(controller.isHolding)
    }

    func testReleaseAndStopAreIdempotent() {
        var released: [IOPMAssertionID] = []
        let controller = makeController(
            create: { _ in (kIOReturnSuccess, 7) },
            release: { id in
                released.append(id)
                return kIOReturnSuccess
            }
        )

        XCTAssertEqual(controller.reconcile(shouldHold: true), .acquired)
        XCTAssertEqual(controller.reconcile(shouldHold: false), .released)
        XCTAssertEqual(controller.release(), .unchanged)
        XCTAssertEqual(controller.stop(), .unchanged)
        XCTAssertEqual(released, [7])
        XCTAssertFalse(controller.isHolding)
    }

    func testReleaseFailureRetainsIDForBoundedRetry() {
        var current = start
        var releaseAttempts = 0
        let failure = IOReturn(kIOReturnNotPermitted)
        let controller = makeController(
            now: { current },
            create: { _ in (kIOReturnSuccess, 9) },
            release: { _ in
                releaseAttempts += 1
                return releaseAttempts == 1 ? failure : kIOReturnSuccess
            }
        )

        XCTAssertEqual(controller.reconcile(shouldHold: true), .acquired)
        XCTAssertEqual(
            controller.release(),
            .failed(.releaseFailed(code: failure))
        )
        XCTAssertTrue(controller.isHolding)
        XCTAssertEqual(controller.lastError?.presentationKey, "display.assertion.error.release")

        XCTAssertEqual(controller.reconcile(shouldHold: false), .unchanged)
        XCTAssertEqual(controller.release(), .unchanged)
        XCTAssertEqual(releaseAttempts, 1)

        current = start.addingTimeInterval(29.9)
        XCTAssertEqual(controller.reconcile(shouldHold: false), .unchanged)
        XCTAssertEqual(releaseAttempts, 1)

        // Explicit lifecycle cleanup may force one retry inside the backoff.
        XCTAssertEqual(controller.stop(), .released)
        XCTAssertFalse(controller.isHolding)
        XCTAssertEqual(releaseAttempts, 2)
    }

    func testOrdinaryReleaseRetriesAtThirtySecondBoundary() {
        var current = start
        var releaseAttempts = 0
        let failure = IOReturn(kIOReturnNotPermitted)
        let controller = makeController(
            now: { current },
            create: { _ in (kIOReturnSuccess, 15) },
            release: { _ in
                releaseAttempts += 1
                return releaseAttempts == 1 ? failure : kIOReturnSuccess
            }
        )

        XCTAssertEqual(controller.reconcile(shouldHold: true), .acquired)
        XCTAssertEqual(
            controller.reconcile(shouldHold: false),
            .failed(.releaseFailed(code: failure))
        )
        current = start.addingTimeInterval(29.9)
        XCTAssertEqual(controller.reconcile(shouldHold: false), .unchanged)
        XCTAssertEqual(releaseAttempts, 1)

        current = start.addingTimeInterval(30)
        XCTAssertEqual(controller.reconcile(shouldHold: false), .released)
        XCTAssertEqual(releaseAttempts, 2)
        XCTAssertFalse(controller.isHolding)
        XCTAssertNil(controller.lastError)
    }

    func testRenewalReleaseFailureRemainsTrackedUntilStopCleansEveryID() {
        var current = start
        var nextID: IOPMAssertionID = 20
        var releaseAttempts: [IOPMAssertionID: Int] = [:]
        let failure = IOReturn(kIOReturnNotPermitted)
        let controller = makeController(
            now: { current },
            create: { _ in
                defer { nextID += 1 }
                return (kIOReturnSuccess, nextID)
            },
            release: { id in
                releaseAttempts[id, default: 0] += 1
                return id == 20 && releaseAttempts[id] == 1
                    ? failure : kIOReturnSuccess
            }
        )

        XCTAssertEqual(controller.reconcile(shouldHold: true), .acquired)
        current = start.addingTimeInterval(30)
        XCTAssertEqual(
            controller.renewIfNeeded(),
            .failed(.releaseFailed(code: failure))
        )
        XCTAssertTrue(controller.isHolding)
        XCTAssertEqual(controller.lastError, .releaseFailed(code: failure))

        // A normal policy reconciliation must not clear the warning while the
        // failed old ID still coexists with the fresh assertion.
        XCTAssertEqual(controller.reconcile(shouldHold: true), .unchanged)
        XCTAssertEqual(controller.lastError, .releaseFailed(code: failure))

        XCTAssertEqual(controller.stop(), .released)
        XCTAssertEqual(releaseAttempts[20], 2)
        XCTAssertEqual(releaseAttempts[21], 1)
        XCTAssertFalse(controller.isHolding)
        XCTAssertNil(controller.lastError)
    }

    func testStopRetainsWarningWhenOnlySomeTrackedIDsRelease() {
        var current = start
        var nextID: IOPMAssertionID = 30
        var releaseAttempts: [IOPMAssertionID: Int] = [:]
        let failure = IOReturn(kIOReturnNotPermitted)
        let controller = makeController(
            now: { current },
            create: { _ in
                defer { nextID += 1 }
                return (kIOReturnSuccess, nextID)
            },
            release: { id in
                releaseAttempts[id, default: 0] += 1
                return id == 30 && releaseAttempts[id, default: 0] <= 2
                    ? failure : kIOReturnSuccess
            }
        )

        XCTAssertEqual(controller.reconcile(shouldHold: true), .acquired)
        current = start.addingTimeInterval(30)
        XCTAssertEqual(
            controller.renewIfNeeded(),
            .failed(.releaseFailed(code: failure))
        )
        XCTAssertEqual(
            controller.stop(),
            .failed(.releaseFailed(code: failure))
        )
        XCTAssertEqual(releaseAttempts[30], 2)
        XCTAssertEqual(releaseAttempts[31], 1)
        XCTAssertTrue(controller.isHolding)
        XCTAssertEqual(controller.lastError, .releaseFailed(code: failure))

        XCTAssertEqual(controller.reconcile(shouldHold: false), .unchanged)
        XCTAssertEqual(controller.lastError, .releaseFailed(code: failure))
        XCTAssertEqual(controller.stop(), .released)
        XCTAssertEqual(releaseAttempts[30], 3)
        XCTAssertEqual(releaseAttempts[31], 1)
        XCTAssertFalse(controller.isHolding)
        XCTAssertNil(controller.lastError)
    }

    func testFailedReleaseExpiresLocallyAndCanReacquireImmediately() {
        var current = start
        var nextID: IOPMAssertionID = 40
        var released: [IOPMAssertionID] = []
        let failure = IOReturn(kIOReturnNotPermitted)
        let controller = makeController(
            now: { current },
            create: { _ in
                defer { nextID += 1 }
                return (kIOReturnSuccess, nextID)
            },
            release: { id in
                released.append(id)
                return id == 40 ? failure : kIOReturnSuccess
            }
        )

        XCTAssertEqual(controller.reconcile(shouldHold: true), .acquired)
        XCTAssertEqual(
            controller.reconcile(shouldHold: false),
            .failed(.releaseFailed(code: failure))
        )
        XCTAssertTrue(controller.isHolding)

        current = start.addingTimeInterval(90)
        XCTAssertFalse(controller.isHolding)
        XCTAssertNil(controller.lastError)
        XCTAssertEqual(controller.reconcile(shouldHold: true), .acquired)
        XCTAssertTrue(controller.isHolding)
        XCTAssertEqual(released, [40])

        XCTAssertEqual(controller.stop(), .released)
        XCTAssertEqual(released, [40, 41])
    }

    func testDeinitAttemptsToReleaseEveryLiveAssertion() {
        var current = start
        var nextID: IOPMAssertionID = 88
        var released: [IOPMAssertionID] = []
        let failure = IOReturn(kIOReturnNotPermitted)
        var controller: DisplaySleepAssertionController? = makeController(
            now: { current },
            create: { _ in
                defer { nextID += 1 }
                return (kIOReturnSuccess, nextID)
            },
            release: { id in
                released.append(id)
                return id == 88 ? failure : kIOReturnSuccess
            }
        )

        XCTAssertEqual(controller?.reconcile(shouldHold: true), .acquired)
        current = start.addingTimeInterval(30)
        XCTAssertEqual(
            controller?.renewIfNeeded(),
            .failed(.releaseFailed(code: failure))
        )
        controller = nil

        XCTAssertEqual(released, [88, 88, 89])
    }

    private func makeController(
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) },
        create: @escaping (TimeInterval) -> DisplaySleepAssertionAPI.CreateResult = {
            _ in (kIOReturnSuccess, 1)
        },
        release: @escaping (IOPMAssertionID) -> IOReturn = { _ in kIOReturnSuccess }
    ) -> DisplaySleepAssertionController {
        DisplaySleepAssertionController(
            api: DisplaySleepAssertionAPI(create: create, release: release),
            now: now,
            automaticallyRenews: false
        )
    }
}
