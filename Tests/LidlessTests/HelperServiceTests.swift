import XCTest

final class HelperServiceTests: XCTestCase {
    private let now: TimeInterval = 1_700_000_000
    private let bootID = "BOOT-CURRENT"
    private let leaseID = "com.kenny.lidlessai.aggregate-wake"

    private struct ServiceReply {
        let ok: Bool
        let error: String?
    }

    private final class TestClock {
        var now: TimeInterval

        init(now: TimeInterval) {
            self.now = now
        }
    }

    private final class PowerProbe {
        var state: Bool?
        var writes: [Bool] = []
        var failNextValue: Bool?
        var onWrite: ((Bool) -> Void)?

        init(state: Bool?) {
            self.state = state
        }

        func read() -> Bool? {
            state
        }

        func write(_ disabled: Bool) -> HelperService.PowerWriteResult {
            onWrite?(disabled)
            writes.append(disabled)
            if failNextValue == disabled {
                failNextValue = nil
                return (false, "Injected pmset failure")
            }
            state = disabled
            return (true, nil)
        }
    }

    private final class SleepProbe {
        var state: HelperClamshellState
        var reads = 0
        var requests = 0
        var requestResult: HelperService.PowerWriteResult = (true, nil)
        var onRead: (() -> Void)?
        var onRequest: (() -> Void)?

        init(isClosed: Bool?, causesSleep: Bool?) {
            state = HelperClamshellState(isClosed: isClosed, causesSleep: causesSleep)
        }

        func read() -> HelperClamshellState {
            reads += 1
            onRead?()
            return state
        }

        func request() -> HelperService.PowerWriteResult {
            requests += 1
            onRequest?()
            return requestResult
        }
    }

    func testAcquirePersistsPendingBeforePowerWriteThenActivates() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: false)
        var phaseObservedAtEnable: HelperLeasePhase?
        power.onWrite = { disabled in
            guard disabled else { return }
            phaseObservedAtEnable = try? fixture.store.load()?.phase
        }
        let service = makeService(fixture: fixture, power: power)

        let reply = acquire(service, notAfter: now + 600)

        XCTAssertTrue(reply.ok, reply.error ?? "acquire failed")
        XCTAssertEqual(phaseObservedAtEnable, .pending)
        XCTAssertEqual(power.writes, [true])
        let journal = try XCTUnwrap(fixture.store.load())
        XCTAssertEqual(journal.phase, .active)
        XCTAssertEqual(journal.leaseID, leaseID)
        XCTAssertFalse(journal.baselineEnabled)
        XCTAssertTrue(journal.changedByUs)
        XCTAssertEqual(journal.lastHeartbeat, now)
        XCTAssertEqual(journal.notAfter, now + 600)
    }

    func testFirstDirectorySyncFailurePreventsPowerMutation() throws {
        let injected = NSError(
            domain: "HelperServiceTests",
            code: 9001,
            userInfo: [NSLocalizedDescriptionKey: "Injected parent-directory sync failure"]
        )
        let fixture = makeFixture(directorySynchronizer: { _ in throw injected })
        defer { fixture.remove() }
        let power = PowerProbe(state: false)
        let service = makeService(fixture: fixture, power: power)

        let reply = acquire(service, notAfter: now + 600)

        XCTAssertFalse(reply.ok)
        XCTAssertTrue(reply.error?.contains("Injected parent-directory sync failure") == true)
        XCTAssertTrue(power.writes.isEmpty, "pmset must not run before directory ownership is durable")
        XCTAssertEqual(power.state, false)
        XCTAssertNil(try fixture.store.load())
    }

    func testInterruptedEmptyDirectoryStillRequiresParentSyncBeforePowerMutation() throws {
        let injected = NSError(
            domain: "HelperServiceTests",
            code: 9002,
            userInfo: [NSLocalizedDescriptionKey: "Injected empty-directory sync failure"]
        )
        let fixture = makeFixture(directorySynchronizer: { _ in throw injected })
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let power = PowerProbe(state: false)
        let service = makeService(fixture: fixture, power: power)

        let reply = acquire(service, notAfter: now + 600)

        XCTAssertFalse(reply.ok)
        XCTAssertTrue(reply.error?.contains("Injected empty-directory sync failure") == true)
        XCTAssertTrue(power.writes.isEmpty)
        XCTAssertEqual(power.state, false)
        XCTAssertNil(try fixture.store.load())
    }

    func testReleaseRestoresOwnedTransitionAndRemovesJournal() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: false)
        let service = makeService(fixture: fixture, power: power)
        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)
        var phaseObservedAtDisable: HelperLeasePhase?
        power.onWrite = { disabled in
            guard !disabled else { return }
            phaseObservedAtDisable = try? fixture.store.load()?.phase
        }

        let reply = release(service)

        XCTAssertTrue(reply.ok, reply.error ?? "release failed")
        XCTAssertEqual(phaseObservedAtDisable, .releasing)
        XCTAssertEqual(power.writes, [true, false])
        XCTAssertEqual(power.state, false)
        XCTAssertNil(try fixture.store.load())
    }

    func testPreexistingEnabledBaselineIsNeverDisabledOnRelease() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: true)
        let service = makeService(fixture: fixture, power: power)

        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)
        let active = try XCTUnwrap(fixture.store.load())
        XCTAssertTrue(active.baselineEnabled)
        XCTAssertFalse(active.changedByUs)

        let reply = release(service)
        XCTAssertTrue(reply.ok, reply.error ?? "release failed")
        XCTAssertTrue(power.writes.isEmpty, "a pre-existing SleepDisabled=1 must never be cleared")
        XCTAssertEqual(power.state, true)
        XCTAssertNil(try fixture.store.load())
    }

    func testConditionalReleaseSleepsAfterOwnedRestoreAndDurableRemoval() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: false)
        let sleep = SleepProbe(isClosed: true, causesSleep: true)
        let service = makeService(fixture: fixture, power: power, sleep: sleep)
        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)

        sleep.onRead = {
            XCTAssertEqual(power.state, false, "normal sleep must be restored before reading the lid")
            XCTAssertNil(try? fixture.store.load(), "journal removal must be durable before lid evaluation")
        }
        sleep.onRequest = {
            XCTAssertEqual(power.state, false)
            XCTAssertNil(try? fixture.store.load())
        }

        let reply = releaseAndSleep(service, mode: .closedLid)

        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.outcome, HelperReleaseOutcome(
            leaseReleased: true,
            restoredOwnedTransition: true,
            lidClosed: true,
            clamshellCausesSleep: true,
            sleepAttempted: true,
            sleepRequestAccepted: true,
            disposition: .sleepRequested
        ))
        XCTAssertEqual(power.writes, [true, false])
        XCTAssertEqual(sleep.reads, 1)
        XCTAssertEqual(sleep.requests, 1)
    }

    func testConditionalReleaseNeverSleepsForPreexistingWakeSetting() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: true)
        let sleep = SleepProbe(isClosed: true, causesSleep: true)
        let service = makeService(fixture: fixture, power: power, sleep: sleep)
        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)

        let reply = releaseAndSleep(service, mode: .closedLidIncludingDocked)

        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.outcome?.disposition, .preexistingWakeSetting)
        XCTAssertEqual(reply.outcome?.restoredOwnedTransition, false)
        XCTAssertEqual(sleep.reads, 0)
        XCTAssertEqual(sleep.requests, 0)
        XCTAssertTrue(power.writes.isEmpty)
        XCTAssertNil(try fixture.store.load())
    }

    func testPolicyOnlyReleaseRestoresOwnedTransitionWithoutReadingLid() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: false)
        let sleep = SleepProbe(isClosed: true, causesSleep: true)
        let service = makeService(fixture: fixture, power: power, sleep: sleep)
        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)

        let reply = releaseAndSleep(service, mode: .never)

        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.outcome?.disposition, .releasedWithoutSleep)
        XCTAssertEqual(reply.outcome?.leaseReleased, true)
        XCTAssertEqual(reply.outcome?.restoredOwnedTransition, true)
        XCTAssertEqual(power.writes, [true, false])
        XCTAssertEqual(sleep.reads, 0)
        XCTAssertEqual(sleep.requests, 0)
        XCTAssertNil(try fixture.store.load())
    }

    func testConditionalReleaseWithOpenLidOnlyRestoresNormalSleep() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: false)
        let sleep = SleepProbe(isClosed: false, causesSleep: true)
        let service = makeService(fixture: fixture, power: power, sleep: sleep)
        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)

        let reply = releaseAndSleep(service, mode: .closedLid)

        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.outcome?.disposition, .lidOpen)
        XCTAssertEqual(reply.outcome?.lidClosed, false)
        XCTAssertEqual(sleep.requests, 0)
        XCTAssertEqual(power.writes, [true, false])
    }

    func testConditionalReleaseDefaultPreservesDockedMode() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: false)
        let sleep = SleepProbe(isClosed: true, causesSleep: false)
        let service = makeService(fixture: fixture, power: power, sleep: sleep)
        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)

        let reply = releaseAndSleep(service, mode: .closedLid)

        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.outcome?.disposition, .dockedMode)
        XCTAssertEqual(reply.outcome?.clamshellCausesSleep, false)
        XCTAssertEqual(sleep.requests, 0)
    }

    func testConditionalReleaseNeverSleepsWhileExternalDisplayIsOnline() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: false)
        let sleep = SleepProbe(isClosed: true, causesSleep: true)
        let service = makeService(
            fixture: fixture,
            power: power,
            sleep: sleep,
            externalDisplayConnected: { true }
        )
        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)

        let reply = releaseAndSleep(service, mode: .closedLid)

        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.outcome?.disposition, .dockedMode)
        XCTAssertEqual(reply.outcome?.leaseReleased, true)
        XCTAssertEqual(sleep.reads, 0)
        XCTAssertEqual(sleep.requests, 0)
        XCTAssertEqual(power.writes, [true, false])
    }

    func testLegacyDockedModeCannotBypassExternalDisplaySafety() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: false)
        let sleep = SleepProbe(isClosed: true, causesSleep: false)
        let service = makeService(
            fixture: fixture,
            power: power,
            sleep: sleep,
            externalDisplayConnected: { true }
        )
        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)

        let reply = releaseAndSleep(service, mode: .closedLidIncludingDocked)

        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.outcome?.disposition, .dockedMode)
        XCTAssertEqual(reply.outcome?.leaseReleased, true)
        XCTAssertEqual(sleep.reads, 0)
        XCTAssertEqual(sleep.requests, 0)
        XCTAssertEqual(power.writes, [true, false])
    }

    func testDisplayHotPlugBeforeSleepRequestDegradesToReleaseOnly() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: false)
        let sleep = SleepProbe(isClosed: true, causesSleep: true)
        var displayChecks = 0
        let service = makeService(
            fixture: fixture,
            power: power,
            sleep: sleep,
            externalDisplayConnected: {
                displayChecks += 1
                return displayChecks >= 2
            }
        )
        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)

        let reply = releaseAndSleep(service, mode: .closedLid)

        XCTAssertNil(reply.error)
        XCTAssertEqual(displayChecks, 2)
        XCTAssertEqual(reply.outcome?.disposition, .dockedMode)
        XCTAssertEqual(reply.outcome?.leaseReleased, true)
        XCTAssertEqual(sleep.reads, 1)
        XCTAssertEqual(sleep.requests, 0)
        XCTAssertEqual(power.writes, [true, false])
    }

    func testConditionalReleaseFailsClosedWhenDisplayTopologyIsUnknown() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: false)
        let sleep = SleepProbe(isClosed: true, causesSleep: true)
        let service = makeService(
            fixture: fixture,
            power: power,
            sleep: sleep,
            externalDisplayConnected: { nil }
        )
        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)

        let reply = releaseAndSleep(service, mode: .closedLid)

        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.outcome?.disposition, .externalDisplayStateUnknown)
        XCTAssertEqual(reply.outcome?.leaseReleased, true)
        XCTAssertEqual(sleep.reads, 0)
        XCTAssertEqual(sleep.requests, 0)
        XCTAssertEqual(power.writes, [true, false])
    }

    func testConditionalReleaseCanSleepInDockedModeWhenExplicitlyAllowed() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: false)
        let sleep = SleepProbe(isClosed: true, causesSleep: false)
        let service = makeService(fixture: fixture, power: power, sleep: sleep)
        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)

        let reply = releaseAndSleep(service, mode: .closedLidIncludingDocked)

        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.outcome?.disposition, .sleepRequested)
        XCTAssertEqual(reply.outcome?.sleepRequestAccepted, true)
        XCTAssertEqual(sleep.requests, 1)
    }

    func testConditionalReleaseFailsClosedForUnknownLidState() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: false)
        let sleep = SleepProbe(isClosed: nil, causesSleep: nil)
        let service = makeService(fixture: fixture, power: power, sleep: sleep)
        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)

        let reply = releaseAndSleep(service, mode: .closedLidIncludingDocked)

        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.outcome?.disposition, .lidStateUnknown)
        XCTAssertEqual(sleep.requests, 0)
        XCTAssertNil(try fixture.store.load())
    }

    func testConditionalReleaseDoesNotSleepWhenRestoreFails() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: false)
        let sleep = SleepProbe(isClosed: true, causesSleep: true)
        let service = makeService(fixture: fixture, power: power, sleep: sleep)
        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)
        power.failNextValue = false

        let reply = releaseAndSleep(service, mode: .closedLid)

        XCTAssertNil(reply.outcome)
        XCTAssertTrue(reply.error?.contains("Injected pmset failure") == true)
        XCTAssertEqual(sleep.reads, 0)
        XCTAssertEqual(sleep.requests, 0)
        XCTAssertEqual(try fixture.store.load()?.phase, .releasing)
    }

    func testConditionalReleaseDoesNotSleepWhenJournalRemovalIsNotDurable() throws {
        let injected = NSError(
            domain: "HelperServiceTests",
            code: 9003,
            userInfo: [NSLocalizedDescriptionKey: "Injected removal-directory sync failure"]
        )
        var failDirectorySync = false
        let fixture = makeFixture(directorySynchronizer: { _ in
            if failDirectorySync { throw injected }
        })
        defer { fixture.remove() }
        let power = PowerProbe(state: false)
        let sleep = SleepProbe(isClosed: true, causesSleep: true)
        let service = makeService(fixture: fixture, power: power, sleep: sleep)
        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)
        power.onWrite = { disabled in
            if !disabled { failDirectorySync = true }
        }

        let reply = releaseAndSleep(service, mode: .closedLid)

        XCTAssertNil(reply.outcome)
        XCTAssertTrue(reply.error?.contains("Injected removal-directory sync failure") == true)
        XCTAssertEqual(power.state, false,
                       "normal policy may already be restored when durability proof fails")
        XCTAssertEqual(sleep.reads, 0)
        XCTAssertEqual(sleep.requests, 0)

        let stateReply = awaitLeaseState(service)
        XCTAssertEqual(stateReply.state?["phase"] as? String, HelperLeasePhase.releasing.rawValue)
        XCTAssertTrue(stateReply.error?.contains("Injected removal-directory sync failure") == true)
    }

    func testConditionalReleaseSurfacesSleepFailureWithoutRetryingOrReacquiring() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: false)
        let sleep = SleepProbe(isClosed: true, causesSleep: true)
        sleep.requestResult = (false, "Injected IOPMSleepSystem failure")
        let service = makeService(fixture: fixture, power: power, sleep: sleep)
        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)

        let reply = releaseAndSleep(service, mode: .closedLid)

        XCTAssertEqual(reply.outcome?.disposition, .sleepRequestFailed)
        XCTAssertEqual(reply.outcome?.leaseReleased, true)
        XCTAssertEqual(reply.outcome?.sleepAttempted, true)
        XCTAssertEqual(reply.outcome?.sleepRequestAccepted, false)
        XCTAssertEqual(reply.error, "Injected IOPMSleepSystem failure")
        XCTAssertEqual(sleep.requests, 1)
        XCTAssertEqual(power.writes, [true, false])
        XCTAssertNil(try fixture.store.load())
    }

    func testUnknownSleepModeDegradesToReleaseOnly() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: false)
        let sleep = SleepProbe(isClosed: true, causesSleep: true)
        let service = makeService(fixture: fixture, power: power, sleep: sleep)
        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)

        let reply = awaitConditionalReply {
            service.releaseLeaseAndSleepIfEligible(
                self.leaseID,
                sleepMode: "future-unknown-mode",
                withReply: $0
            )
        }

        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.outcome?.disposition, .releasedWithoutSleep)
        XCTAssertEqual(sleep.reads, 0)
        XCTAssertEqual(sleep.requests, 0)
        XCTAssertNil(try fixture.store.load())
    }

    func testSameIDAcquireRebuildsLeaseAfterExternalDisable() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: false)
        let service = makeService(fixture: fixture, power: power)
        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)

        // Simulate another power tool clearing the global flag without touching
        // Lidless AI's still-active journal.
        power.state = false
        let reacquired = acquire(service, notAfter: now + 700)

        XCTAssertTrue(reacquired.ok, reacquired.error ?? "reacquire failed")
        XCTAssertEqual(power.writes, [true, true])
        let journal = try XCTUnwrap(fixture.store.load())
        XCTAssertEqual(journal.phase, .active)
        XCTAssertFalse(journal.baselineEnabled)
        XCTAssertTrue(journal.changedByUs)
        XCTAssertEqual(journal.notAfter, now + 700)

        XCTAssertTrue(release(service).ok)
        XCTAssertEqual(power.writes, [true, true, false])
        XCTAssertEqual(power.state, false)
    }

    func testExternalDisableAfterPreexistingBaselineGetsFreshOwnedBaseline() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: true)
        let service = makeService(fixture: fixture, power: power)
        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)
        XCTAssertTrue(try XCTUnwrap(fixture.store.load()).baselineEnabled)

        power.state = false
        XCTAssertTrue(acquire(service, notAfter: now + 700).ok)
        let rebuilt = try XCTUnwrap(fixture.store.load())
        XCTAssertFalse(rebuilt.baselineEnabled)
        XCTAssertTrue(rebuilt.changedByUs)
        XCTAssertEqual(power.writes, [true])

        XCTAssertTrue(release(service).ok)
        XCTAssertEqual(power.writes, [true, false])
        XCTAssertEqual(power.state, false)
    }

    func testFailedAcquireWriteRollsBackAndCanRetry() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: false)
        power.failNextValue = true
        let service = makeService(fixture: fixture, power: power)

        let failed = acquire(service, notAfter: now + 600)
        XCTAssertFalse(failed.ok)
        XCTAssertTrue(failed.error?.contains("Injected pmset failure") == true)
        XCTAssertNil(try fixture.store.load(), "failed 0->1 must not strand a pending record")
        XCTAssertEqual(power.state, false)

        let retried = acquire(service, notAfter: now + 600)
        XCTAssertTrue(retried.ok, retried.error ?? "retry failed")
        XCTAssertEqual(power.writes, [true, true])
        XCTAssertEqual(try fixture.store.load()?.phase, .active)
    }

    func testFailedReleaseWriteKeepsRetryableJournal() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: false)
        let service = makeService(fixture: fixture, power: power)
        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)
        power.failNextValue = false

        let failed = release(service)
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(try fixture.store.load()?.phase, .releasing)
        XCTAssertEqual(power.state, true)

        let retried = release(service)
        XCTAssertTrue(retried.ok, retried.error ?? "release retry failed")
        XCTAssertEqual(power.writes, [true, false, false])
        XCTAssertEqual(power.state, false)
        XCTAssertNil(try fixture.store.load())
    }

    func testStartupRecoversOwnedLeaseAcrossBoot() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        try fixture.store.save(HelperLeaseJournal(
            leaseID: leaseID,
            baselineEnabled: false,
            changedByUs: true,
            phase: .active,
            bootID: "BOOT-PREVIOUS",
            lastHeartbeat: now - 10,
            notAfter: now + 600
        ))
        let power = PowerProbe(state: true)

        let service = makeService(fixture: fixture, power: power)

        XCTAssertEqual(power.writes, [false])
        XCTAssertEqual(power.state, false)
        XCTAssertNil(try fixture.store.load())
        withExtendedLifetime(service) {}
    }

    func testSameBootHelperRestartRetainsFreshActiveLease() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        try fixture.store.save(HelperLeaseJournal(
            leaseID: leaseID,
            baselineEnabled: false,
            changedByUs: true,
            phase: .active,
            bootID: bootID,
            lastHeartbeat: now - 10,
            notAfter: now + 600
        ))
        let power = PowerProbe(state: true)

        let service = makeService(fixture: fixture, power: power)

        XCTAssertTrue(power.writes.isEmpty)
        XCTAssertEqual(power.state, true)
        XCTAssertEqual(try fixture.store.load()?.phase, .active)
        XCTAssertTrue(awaitReply {
            service.heartbeatLease(self.leaseID, withReply: $0)
        }.ok)
        XCTAssertEqual(try fixture.store.load()?.lastHeartbeat, now)
    }

    func testWatchdogExpiresStaleHeartbeat() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let clock = TestClock(now: now)
        let power = PowerProbe(state: false)
        let service = makeService(
            fixture: fixture,
            power: power,
            clock: clock,
            watchdogTimeout: 10
        )
        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)

        clock.now += 10
        service.runWatchdogTickForTesting()

        XCTAssertEqual(power.writes, [true, false])
        XCTAssertEqual(power.state, false)
        XCTAssertNil(try fixture.store.load())
    }

    func testDifferentLeaseCannotAcquireUpdateHeartbeatOrRelease() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let power = PowerProbe(state: false)
        let service = makeService(fixture: fixture, power: power)
        XCTAssertTrue(acquire(service, notAfter: now + 600).ok)
        let other = "com.example.other-owner"

        let acquireOther = awaitReply {
            service.acquireLease(other, notAfter: self.now + 700, withReply: $0)
        }
        let updateOther = awaitReply {
            service.updateLease(other, notAfter: self.now + 700, withReply: $0)
        }
        let heartbeatOther = awaitReply {
            service.heartbeatLease(other, withReply: $0)
        }
        let releaseOther = awaitReply {
            service.releaseLease(other, withReply: $0)
        }

        for reply in [acquireOther, updateOther, heartbeatOther, releaseOther] {
            XCTAssertFalse(reply.ok)
            XCTAssertNotNil(reply.error)
        }
        let journal = try XCTUnwrap(fixture.store.load())
        XCTAssertEqual(journal.leaseID, leaseID)
        XCTAssertEqual(journal.phase, .active)
        XCTAssertEqual(power.writes, [true])
    }

    private func makeService(
        fixture: TemporaryFixture,
        power: PowerProbe,
        sleep: SleepProbe? = nil,
        externalDisplayConnected: @escaping () -> Bool? = { false },
        clock: TestClock? = nil,
        watchdogTimeout: TimeInterval = 90
    ) -> HelperService {
        let clock = clock ?? TestClock(now: now)
        return HelperService(
            journalStore: fixture.store,
            bootID: bootID,
            watchdogTimeout: watchdogTimeout,
            clock: { clock.now },
            readSleepDisabled: { power.read() },
            writeSleepDisabled: { power.write($0) },
            externalDisplayConnected: externalDisplayConnected,
            readClamshellState: {
                sleep?.read() ?? HelperClamshellState(isClosed: nil, causesSleep: nil)
            },
            requestSystemSleep: {
                sleep?.request() ?? (false, "System sleep is disabled in unit tests.")
            },
            startsWatchdog: false
        )
    }

    private func acquire(_ service: HelperService, notAfter: TimeInterval) -> ServiceReply {
        awaitReply {
            service.acquireLease(leaseID, notAfter: notAfter, withReply: $0)
        }
    }

    private func release(_ service: HelperService) -> ServiceReply {
        awaitReply {
            service.releaseLease(leaseID, withReply: $0)
        }
    }

    private struct ConditionalReply {
        let outcome: HelperReleaseOutcome?
        let error: String?
    }

    private func releaseAndSleep(
        _ service: HelperService,
        mode: HelperSleepMode
    ) -> ConditionalReply {
        awaitConditionalReply {
            service.releaseLeaseAndSleepIfEligible(
                leaseID,
                sleepMode: mode.rawValue,
                withReply: $0
            )
        }
    }

    private func awaitConditionalReply(
        _ operation: (@escaping (NSDictionary?, String?) -> Void) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ConditionalReply {
        let completed = expectation(description: "HelperService conditional-release reply")
        var received: ConditionalReply?
        operation { dictionary, error in
            received = ConditionalReply(
                outcome: dictionary.flatMap(HelperReleaseOutcome.init(dictionary:)),
                error: error
            )
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        guard let received else {
            XCTFail("HelperService did not reply", file: file, line: line)
            return ConditionalReply(outcome: nil, error: "No reply")
        }
        return received
    }

    private func awaitLeaseState(
        _ service: HelperService,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (state: NSDictionary?, error: String?) {
        let completed = expectation(description: "HelperService lease-state reply")
        var state: NSDictionary?
        var receivedError: String?
        service.getLeaseState { dictionary, error in
            state = dictionary
            receivedError = error
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        if state == nil && receivedError == nil {
            XCTFail("HelperService did not reply", file: file, line: line)
        }
        return (state, receivedError)
    }

    private func awaitReply(
        _ operation: (@escaping (Bool, String?) -> Void) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ServiceReply {
        let completed = expectation(description: "HelperService reply")
        var received: ServiceReply?
        operation { ok, error in
            received = ServiceReply(ok: ok, error: error)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        guard let received else {
            XCTFail("HelperService did not reply", file: file, line: line)
            return ServiceReply(ok: false, error: "No reply")
        }
        return received
    }

    private struct TemporaryFixture {
        let directory: URL
        let store: HelperLeaseJournalStore

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture(
        directorySynchronizer: ((URL) throws -> Void)? = nil
    ) -> TemporaryFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelperServiceTests-\(UUID().uuidString)", isDirectory: true)
        let store = HelperLeaseJournalStore(
            fileURL: directory.appendingPathComponent("journal.json", isDirectory: false),
            directorySynchronizer: directorySynchronizer
        )
        return TemporaryFixture(directory: directory, store: store)
    }
}
