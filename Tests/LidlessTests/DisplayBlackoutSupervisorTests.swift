import CoreGraphics
import Foundation
import XCTest

final class DisplayBlackoutSupervisorTests: XCTestCase {
    @MainActor private var latestPipeFixture: PipeWatchdogFixture?

    @MainActor
    func testExternalCapabilityBlocksArmBeforeLaunchingWatchdog() {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let urlRequests = LockedInteger()
        let supervisor = DisplayBlackoutSupervisor(
            watchdogURLProvider: {
                urlRequests.increment()
                return URL(fileURLWithPath: "/usr/bin/false")
            },
            journalStore: paths.store,
            capabilityProbe: { .externalDisplayConnected(count: 1) },
            fallbackRecovery: { _ in .success(.noJournal) }
        )

        supervisor.arm()

        XCTAssertEqual(supervisor.snapshot.phase, .idle)
        XCTAssertEqual(
            supervisor.snapshot.capability,
            .externalDisplayConnected(count: 1)
        )
        // One lookup is the read-only capability boundary; no child is started.
        XCTAssertEqual(urlRequests.value, 1)
    }

    @MainActor
    func testWatchdogCrashInvokesAppFallbackRecovery() async {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let recoveryCalls = LockedInteger()
        let restored = expectation(description: "fallback recovery completes")
        let supervisor = DisplayBlackoutSupervisor(
            watchdogURLProvider: { URL(fileURLWithPath: "/usr/bin/false") },
            journalStore: paths.store,
            capabilityProbe: { .ready(displayID: 1) },
            fallbackRecovery: { _ in
                recoveryCalls.increment()
                return .success(.restored)
            }
        )
        supervisor.onSnapshotChange = { snapshot in
            if snapshot.phase == .idle,
               snapshot.lastStatus == .restored,
               snapshot.failureCode != nil {
                restored.fulfill()
            }
        }

        supervisor.arm()
        await fulfillment(of: [restored], timeout: 3)

        XCTAssertEqual(recoveryCalls.value, 1)
        XCTAssertFalse(supervisor.snapshot.blackoutActive)
        XCTAssertFalse(supervisor.snapshot.recoveryPending)
    }

    @MainActor
    func testRestoreWithoutChildOrJournalCompletesWithoutLaunching() {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let urlRequests = LockedInteger()
        let supervisor = DisplayBlackoutSupervisor(
            watchdogURLProvider: {
                urlRequests.increment()
                return URL(fileURLWithPath: "/usr/bin/false")
            },
            journalStore: paths.store,
            capabilityProbe: { .ready(displayID: 1) },
            fallbackRecovery: { _ in .success(.noJournal) }
        )
        var restored = false

        supervisor.restore { restored = $0 }

        XCTAssertTrue(restored)
        XCTAssertEqual(urlRequests.value, 0)
        XCTAssertEqual(supervisor.snapshot.phase, .idle)
    }

    @MainActor
    func testMissingWatchdogWithJournalImmediatelyUsesAppFallback() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.store.save(DisplayBlackoutJournal(
            token: "prior",
            generation: 1,
            displayID: 1,
            originalBrightness: 0.7,
            phase: .armed,
            createdAt: 100,
            updatedAt: 100
        ))
        let recoveryCalls = LockedInteger()
        let restored = expectation(description: "standalone fallback completes")
        let supervisor = DisplayBlackoutSupervisor(
            watchdogURLProvider: {
                URL(fileURLWithPath: "/definitely/missing/LidlessDisplayWatchdog")
            },
            journalStore: paths.store,
            capabilityProbe: { .ready(displayID: 1) },
            fallbackRecovery: { _ in
                recoveryCalls.increment()
                return .success(.restored)
            }
        )
        supervisor.onSnapshotChange = { snapshot in
            if snapshot.phase == .idle, snapshot.lastStatus == .restored {
                restored.fulfill()
            }
        }

        supervisor.recoverAtLaunchIfNeeded()
        await fulfillment(of: [restored], timeout: 2)

        XCTAssertEqual(recoveryCalls.value, 1)
        XCTAssertEqual(supervisor.snapshot.phase, .idle)
        XCTAssertFalse(supervisor.snapshot.recoveryPending)
    }

    @MainActor
    func testProcessRunFailureWithJournalImmediatelyUsesAppFallback() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.store.save(DisplayBlackoutJournal(
            token: "prior",
            generation: 2,
            displayID: 1,
            originalBrightness: 0.6,
            phase: .armed,
            createdAt: 100,
            updatedAt: 100
        ))
        let invalidExecutable = paths.root.appendingPathComponent("invalid-watchdog")
        try Data("not a Mach-O executable".utf8).write(to: invalidExecutable, options: .atomic)
        XCTAssertEqual(Darwin.chmod(invalidExecutable.path, mode_t(0o700)), 0)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: invalidExecutable.path))

        let recoveryCalls = LockedInteger()
        let restored = expectation(description: "launch failure fallback completes")
        restored.assertForOverFulfill = false
        let supervisor = DisplayBlackoutSupervisor(
            watchdogURLProvider: { invalidExecutable },
            journalStore: paths.store,
            capabilityProbe: { .ready(displayID: 1) },
            fallbackRecovery: { _ in
                recoveryCalls.increment()
                return .success(.restored)
            }
        )
        supervisor.onSnapshotChange = { snapshot in
            if snapshot.phase == .idle, snapshot.lastStatus == .restored {
                restored.fulfill()
            }
        }

        supervisor.recoverAtLaunchIfNeeded()
        await fulfillment(of: [restored], timeout: 2)

        XCTAssertEqual(recoveryCalls.value, 1)
        XCTAssertEqual(supervisor.snapshot.phase, .idle)
    }

    @MainActor
    func testMissingWatchdogWithoutJournalDoesNotInvokeFallbackOrArm() {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let recoveryCalls = LockedInteger()
        let supervisor = DisplayBlackoutSupervisor(
            watchdogURLProvider: {
                URL(fileURLWithPath: "/definitely/missing/LidlessDisplayWatchdog")
            },
            journalStore: paths.store,
            capabilityProbe: { .ready(displayID: 1) },
            fallbackRecovery: { _ in
                recoveryCalls.increment()
                return .success(.noJournal)
            }
        )

        supervisor.arm()

        XCTAssertEqual(recoveryCalls.value, 0)
        XCTAssertEqual(supervisor.snapshot.phase, .idle)
        XCTAssertEqual(supervisor.snapshot.capability, .brightnessUnavailable)
    }

    @MainActor
    func testClosedLidWithTwoExternalDisplaysDefersRecoveryWithoutDiscardingJournal() async throws {
        let fixture = try await makePipeFixture()
        let supervisor = try XCTUnwrap(fixture.supervisor)
        supervisor.recoverAtLaunchIfNeeded()
        try await eventually { supervisor.snapshot.phase == .pendingRecovery }
        let acknowledgedJournal = try XCTUnwrap(fixture.store.load())
        var preparationResults: [AllDisplaysSleepPreparation] = []
        var strictRestoreResults: [Bool] = []

        supervisor.prepareForAllDisplaysSleep { preparationResults.append($0) }
        supervisor.restore { strictRestoreResults.append($0) }

        XCTAssertEqual(preparationResults, [.deferredBuiltInRecovery])
        XCTAssertEqual(strictRestoreResults, [false], "Quit/normal-sleep restoration remains strict")
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .deferredBuiltInRecovery)
        XCTAssertEqual(try fixture.store.load(), acknowledgedJournal)
        XCTAssertTrue(fixture.processIsRunning)
        XCTAssertEqual(fixture.fallbackCalls.value, 0)

        var idleTransitions = 0
        var previousPhase = supervisor.snapshot.phase
        supervisor.onSnapshotChange = { snapshot in
            if snapshot.phase == .idle, previousPhase != .idle { idleTransitions += 1 }
            previousPhase = snapshot.phase
        }
        try fixture.send(.restoredTwice)
        try await eventually { supervisor.snapshot.phase == .idle && !fixture.processIsRunning }

        XCTAssertNil(try fixture.store.load(), "The fake watchdog must actually remove its test journal")
        XCTAssertEqual(supervisor.snapshot.lastStatus, .restored)
        XCTAssertNil(supervisor.snapshot.recoveryStatus)
        XCTAssertNil(supervisor.snapshot.recoveryFailure)
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .ready)
        XCTAssertEqual(idleTransitions, 1, "Duplicate terminal replies and process EOF must be harmless")
        XCTAssertEqual(preparationResults, [.deferredBuiltInRecovery])
        XCTAssertEqual(strictRestoreResults, [false])
        XCTAssertEqual(fixture.fallbackCalls.value, 0)
    }

    @MainActor
    func testExternalArmCapabilityDoesNotOverwritePendingRecoveryReason() async throws {
        let fixture = try await makePipeFixture()
        let supervisor = try XCTUnwrap(fixture.supervisor)
        supervisor.recoverAtLaunchIfNeeded()
        try await eventually { supervisor.snapshot.recoveryStatus == .builtInUnavailable }

        XCTAssertEqual(supervisor.refreshCapability(), .externalDisplayConnected(count: 2))

        XCTAssertEqual(supervisor.snapshot.capability, .externalDisplayConnected(count: 2))
        XCTAssertEqual(supervisor.snapshot.recoveryStatus, .builtInUnavailable)
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .deferredBuiltInRecovery)

        try fixture.send(.pending(.topologyUnknown))
        try await eventually { supervisor.snapshot.recoveryStatus == .topologyUnknown }
        supervisor.refreshCapability()

        XCTAssertEqual(supervisor.snapshot.recoveryStatus, .topologyUnknown)
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .blocked(.topologyUnknown))
        XCTAssertNotNil(try fixture.store.load())
    }

    @MainActor
    func testDeferredRecoveryRequiresFreshClosedLidAndOnlyExternalDisplays() async throws {
        let fixture = try await makePipeFixture()
        let supervisor = try XCTUnwrap(fixture.supervisor)
        supervisor.recoverAtLaunchIfNeeded()
        try await eventually { supervisor.snapshot.phase == .pendingRecovery }

        fixture.topology.value = .unknown
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .blocked(.topologyUnknown))
        fixture.topology.value = .known(lidClosed: nil, displays: PipeWatchdogFixture.externalDisplays)
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .blocked(.topologyUnknown))
        fixture.topology.value = .known(lidClosed: false, displays: PipeWatchdogFixture.externalDisplays)
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .blocked(.builtInUnavailable))
        fixture.topology.value = .known(lidClosed: true, displays: [
            .init(id: 1, isBuiltIn: true),
            .init(id: 2, isBuiltIn: false),
            .init(id: 3, isBuiltIn: false)
        ])
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .blocked(.builtInUnavailable))
        fixture.topology.value = PipeWatchdogFixture.closedLidTopology
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .deferredBuiltInRecovery)
    }

    @MainActor
    func testCorruptOrReplacedRecoveryRecordCannotReuseEarlierAcknowledgement() async throws {
        let fixture = try await makePipeFixture()
        let supervisor = try XCTUnwrap(fixture.supervisor)
        supervisor.recoverAtLaunchIfNeeded()
        try await eventually { supervisor.snapshot.phase == .pendingRecovery }
        let original = try XCTUnwrap(fixture.store.load())

        try Data("invalid-json".utf8).write(to: fixture.store.fileURL)
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .blocked(.invalidRecoveryRecord))

        var replacement = original
        replacement.generation += 1
        try fixture.store.save(replacement)
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .blocked(.invalidRecoveryRecord))

        replacement = original
        replacement.originalBrightness = 0.9
        try fixture.store.save(replacement)
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .blocked(.invalidRecoveryRecord))

        replacement = original
        replacement.phase = .armed
        try fixture.store.save(replacement)
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .blocked(.invalidRecoveryRecord))

        try fixture.store.save(original)
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .deferredBuiltInRecovery)
    }

    @MainActor
    func testReplacingGenerationBeforeFirstPendingReplyCannotAuthenticateTheNewRecord() async throws {
        let fixture = try await makePipeFixture(initialCommand: .hold)
        let supervisor = try XCTUnwrap(fixture.supervisor)
        supervisor.recoverAtLaunchIfNeeded()
        // The fake writes its PID only after reading the production launch
        // request, but .hold deliberately withholds its first acknowledgement.
        try await eventually { fixture.processIsRunning }
        XCTAssertEqual(supervisor.snapshot.phase, .starting)
        var replacement = try XCTUnwrap(fixture.store.load())
        replacement.generation += 1
        try fixture.store.save(replacement)

        try fixture.send(.pending(.builtInUnavailable))
        try await eventually { supervisor.snapshot.phase == .pendingRecovery }
        var preparationResults: [AllDisplaysSleepPreparation] = []
        supervisor.prepareForAllDisplaysSleep { preparationResults.append($0) }

        XCTAssertEqual(supervisor.snapshot.recoveryFailure, .invalidRecoveryRecord)
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .blocked(.invalidRecoveryRecord))
        XCTAssertEqual(preparationResults, [.blocked(.invalidRecoveryRecord)])
        XCTAssertEqual(try fixture.store.load(), replacement)
        XCTAssertTrue(fixture.processIsRunning)
        XCTAssertEqual(fixture.fallbackCalls.value, 0)

        // Losing the old child must not erase the record-identity failure, even
        // if a subsequent valid child can now read the replacement generation.
        try fixture.send(.exit)
        try await eventually {
            fixture.fallbackCalls.value == 1 && supervisor.snapshot.phase == .pendingRecovery
        }
        XCTAssertEqual(supervisor.snapshot.recoveryFailure, .invalidRecoveryRecord)
        try fixture.send(.pending(.builtInUnavailable))
        supervisor.retryPendingRecovery()
        try await eventually { supervisor.snapshot.phase == .pendingRecovery && fixture.processIsRunning }
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .blocked(.invalidRecoveryRecord))
        XCTAssertEqual(try fixture.store.load(), replacement)

        try fixture.send(.restoredTwice)
        try await eventually { supervisor.snapshot.phase == .idle && !fixture.processIsRunning }
        XCTAssertNil(try fixture.store.load())
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .ready)
        XCTAssertEqual(preparationResults, [.blocked(.invalidRecoveryRecord)])
    }

    @MainActor
    func testDeadWatchdogCannotAuthorizeDeferredRecovery() async throws {
        let fixture = try await makePipeFixture()
        let supervisor = try XCTUnwrap(fixture.supervisor)
        supervisor.recoverAtLaunchIfNeeded()
        try await eventually { supervisor.snapshot.phase == .pendingRecovery }
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .deferredBuiltInRecovery)

        try fixture.send(.exit)
        try await eventually {
            fixture.fallbackCalls.value == 1 && supervisor.snapshot.phase == .pendingRecovery
        }

        XCTAssertFalse(fixture.processIsRunning)
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .blocked(.recoveryUnavailable))
        XCTAssertNotNil(try fixture.store.load())
    }

    @MainActor
    func testPendingResponseWithWrongHandshakeCannotAuthorizeDeferredRecovery() async throws {
        let fixture = try await makePipeFixture(initialCommand: .pendingWithWrongToken)
        let supervisor = try XCTUnwrap(fixture.supervisor)
        supervisor.recoverAtLaunchIfNeeded()
        try await eventually {
            fixture.fallbackCalls.value == 1 && supervisor.snapshot.phase == .pendingRecovery
        }

        XCTAssertEqual(supervisor.snapshot.failureCode, "watchdog-handshake-mismatch")
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .blocked(.recoveryUnavailable))
        XCTAssertNotNil(try fixture.store.load())
    }

    @MainActor
    func testPendingBrightnessFailureIsNotHiddenByExternalCapabilityOrLaterOfflineStatus() async throws {
        let fixture = try await makePipeFixture(initialCommand: .pending(.brightnessUnavailable))
        let supervisor = try XCTUnwrap(fixture.supervisor)
        supervisor.recoverAtLaunchIfNeeded()
        try await eventually { supervisor.snapshot.recoveryFailure == .brightnessUnavailable }

        supervisor.refreshCapability()
        XCTAssertEqual(supervisor.snapshot.capability, .externalDisplayConnected(count: 2))
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .blocked(.brightnessUnavailable))
        try fixture.send(.pending(.builtInUnavailable))
        try await eventually { supervisor.snapshot.recoveryStatus == .builtInUnavailable }

        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .blocked(.brightnessUnavailable))
        XCTAssertNotNil(try fixture.store.load())

        try fixture.send(.restoredTwice)
        try await eventually { supervisor.snapshot.phase == .idle }
        XCTAssertNil(supervisor.snapshot.recoveryFailure)
        XCTAssertNil(try fixture.store.load())
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .ready)
    }

    @MainActor
    func testPendingRestorationErrorIsNotReclassifiedAsSafeOfflineRecovery() async throws {
        let fixture = try await makePipeFixture(initialCommand: .pendingFailure)
        let supervisor = try XCTUnwrap(fixture.supervisor)
        supervisor.recoverAtLaunchIfNeeded()
        try await eventually { supervisor.snapshot.recoveryFailure == .recoveryFailed }

        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .blocked(.recoveryFailed))
        try fixture.send(.pending(.builtInUnavailable))
        try await eventually { supervisor.snapshot.recoveryStatus == .builtInUnavailable }

        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .blocked(.recoveryFailed))
        XCTAssertNotNil(try fixture.store.load())
    }

    @MainActor
    func testRealRecoveryErrorsSurviveWatchdogExitFallbackAndNewPendingHandshake() async throws {
        let scenarios: [(PipeWatchdogFixture.Command, AllDisplaysSleepPreparationFailure)] = [
            (.pending(.brightnessUnavailable), .brightnessUnavailable),
            (.pendingFailure, .recoveryFailed)
        ]
        for (initialCommand, expectedFailure) in scenarios {
            let fixture = try await makePipeFixture(initialCommand: initialCommand)
            let supervisor = try XCTUnwrap(fixture.supervisor)
            supervisor.recoverAtLaunchIfNeeded()
            try await eventually { supervisor.snapshot.recoveryFailure == expectedFailure }
            try fixture.send(.exit)
            try await eventually {
                fixture.fallbackCalls.value == 1 && supervisor.snapshot.phase == .pendingRecovery
            }

            XCTAssertEqual(supervisor.snapshot.recoveryFailure, expectedFailure,
                           "Offline fallback must preserve the earlier real recovery error")
            XCTAssertNotNil(try fixture.store.load())
            try fixture.send(.pending(.builtInUnavailable))
            supervisor.retryPendingRecovery()
            try await eventually {
                supervisor.snapshot.phase == .pendingRecovery
                    && supervisor.snapshot.recoveryStatus == .builtInUnavailable
                    && fixture.processIsRunning
            }

            XCTAssertEqual(supervisor.snapshot.recoveryFailure, expectedFailure)
            XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .blocked(expectedFailure))
            XCTAssertNotNil(try fixture.store.load())

            try fixture.send(.restoredTwice)
            try await eventually { supervisor.snapshot.phase == .idle && !fixture.processIsRunning }
            XCTAssertNil(supervisor.snapshot.recoveryFailure)
            XCTAssertNil(try fixture.store.load())
            XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .ready)
            XCTAssertEqual(fixture.fallbackCalls.value, 1)
        }
    }

    @MainActor
    func testCancelPreparationDropsLateCompletionButKeepsWatchdogRecoveryAlive() async throws {
        let fixture = try await makePipeFixture(initialCommand: .hold)
        let supervisor = try XCTUnwrap(fixture.supervisor)
        var preparationResults: [AllDisplaysSleepPreparation] = []

        supervisor.prepareForAllDisplaysSleep { preparationResults.append($0) }
        supervisor.cancelAllDisplaysSleepPreparation()
        try await eventually { fixture.processIsRunning }
        try fixture.send(.pending(.builtInUnavailable))
        try await eventually { supervisor.snapshot.phase == .pendingRecovery }

        XCTAssertTrue(preparationResults.isEmpty)
        XCTAssertTrue(fixture.processIsRunning)
        XCTAssertNotNil(try fixture.store.load())
        XCTAssertEqual(supervisor.revalidateAllDisplaysSleepPreparation(), .deferredBuiltInRecovery)

        try fixture.send(.restoredTwice)
        try await eventually { supervisor.snapshot.phase == .idle && !fixture.processIsRunning }

        XCTAssertTrue(preparationResults.isEmpty, "Cancelled preparation must never receive late success")
        XCTAssertNil(try fixture.store.load())
        XCTAssertEqual(fixture.fallbackCalls.value, 0)
    }

    @MainActor
    func testRealSupervisorHandoffSleepsOnceAndLaterRestorationNeverRepeatsCommand() async throws {
        let fixture = try await makePipeFixture()
        let supervisor = try XCTUnwrap(fixture.supervisor)
        supervisor.recoverAtLaunchIfNeeded()
        try await eventually { supervisor.snapshot.phase == .pendingRecovery }
        let retainedJournal = try XCTUnwrap(fixture.store.load())
        var commandCount = 0
        var timerCallbacks: [() -> Void] = []
        var screenObserver: ((AllDisplaysSleepController.ScreenEvent) -> Void)?
        let controller = AllDisplaysSleepController(dependencies: .init(
            uptime: { ProcessInfo.processInfo.systemUptime },
            schedule: { delay, action in
                timerCallbacks.append(action)
                let work = DispatchWorkItem(block: action)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                return .init { work.cancel() }
            },
            launch: { completion in
                commandCount += 1
                completion(.finished(exitStatus: 0, stdout: "", stderr: ""))
                return .init()
            },
            probe: { .online(asleep: [true, true]) },
            observe: { handler in
                screenObserver = handler
                return .init()
            },
            topology: { fixture.topology.value }
        ))
        defer { controller.cancel() }

        controller.request(
            prepare: { supervisor.prepareForAllDisplaysSleep(completion: $0) },
            revalidate: { supervisor.revalidateAllDisplaysSleepPreparation() }
        )
        controller.request { _ in XCTFail("A second click cannot begin another preparation") }
        XCTAssertEqual(controller.snapshot.phase, .scheduled)
        try await eventually { controller.snapshot.phase == .asleep }

        XCTAssertEqual(commandCount, 1)
        XCTAssertTrue(controller.snapshot.suspendsDisplayAwake)
        XCTAssertEqual(try fixture.store.load(), retainedJournal)
        XCTAssertTrue(fixture.processIsRunning)

        screenObserver?(.displaysWoke)
        XCTAssertEqual(controller.snapshot.phase, .idle)
        XCTAssertFalse(controller.snapshot.suspendsDisplayAwake)
        try fixture.send(.restoredTwice)
        try await eventually { supervisor.snapshot.phase == .idle && !fixture.processIsRunning }
        // Deliver even callbacks whose timers were already cancelled. The old
        // operation must not acquire a new screen-sleep command after user wake.
        timerCallbacks.forEach { $0() }
        screenObserver?(.displaysSlept)

        XCTAssertEqual(commandCount, 1)
        XCTAssertEqual(controller.snapshot.phase, .idle)
        XCTAssertNil(try fixture.store.load())
        XCTAssertEqual(fixture.fallbackCalls.value, 0)
    }

    @MainActor
    private func makePipeFixture(
        initialCommand: PipeWatchdogFixture.Command = .pending(.builtInUnavailable)
    ) async throws -> PipeWatchdogFixture {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("The isolated pipe-watchdog fixture requires /usr/bin/python3")
        }
        try await PipeWatchdogFixture.verifyInterpreterIsReady()
        let fixture = try PipeWatchdogFixture(initialCommand: initialCommand)
        latestPipeFixture = fixture
        addTeardownBlock { await fixture.tearDown() }
        return fixture
    }

    @MainActor
    private func eventually(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard condition() else {
            let diagnostics = latestPipeFixture?.diagnosticDescription ?? "No pipe fixture"
            XCTFail("Timed out waiting for the isolated watchdog state. \(diagnostics)", file: file, line: line)
            throw PipeWatchdogFixture.FixtureError.timedOut
        }
    }

    private func makePaths() -> (
        root: URL,
        store: DisplayBlackoutJournalStore
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DisplayBlackoutSupervisorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let file = root
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("journal.json", isDirectory: false)
        return (root, DisplayBlackoutJournalStore(fileURL: file))
    }
}

/// Exercises the production Process/Pipe/handshake boundary while keeping all
/// effects in one unique temporary directory. No real watchdog, display API,
/// power API, default runtime path, or test-only production mutation is used.
@MainActor
private final class PipeWatchdogFixture {
    enum FixtureError: Error {
        case timedOut
        case interpreterSelfCheckFailed(String)
    }

    private static var interpreterVerified = false

    /// Python is only this test's protocol adapter. Finish its interpreter and
    /// standard-library cold start (including Rosetta translation) before the
    /// production supervisor starts its unchanged two-second handshake clock.
    /// This is an actual readiness/exit check, not a delay or a watchdog retry.
    static func verifyInterpreterIsReady() async throws {
        guard !interpreterVerified else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
            import json, os, pathlib, select, struct, sys
            assert json.loads(json.dumps({"ready": True}))["ready"]
            assert struct.unpack(">I", struct.pack(">I", 4))[0] == 4
            """]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        func waitForExit(upTo duration: TimeInterval) async {
            let deadline = ProcessInfo.processInfo.systemUptime + duration
            while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        await waitForExit(upTo: 10)
        let exceededStartupDeadline = process.isRunning
        if process.isRunning {
            process.terminate()
            await waitForExit(upTo: 1)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            await waitForExit(upTo: 1)
        }
        guard !process.isRunning else {
            throw FixtureError.interpreterSelfCheckFailed("Timed out; self-check process did not exit after termination")
        }
        guard !exceededStartupDeadline else {
            throw FixtureError.interpreterSelfCheckFailed("Python import self-check exceeded its 10-second startup limit")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw FixtureError.interpreterSelfCheckFailed("Python import self-check exited with status \(process.terminationStatus)")
        }
        interpreterVerified = true
    }

    enum Command {
        case hold
        case pending(DisplayBlackoutResponseStatus)
        case pendingWithWrongToken
        case pendingFailure
        case restoredTwice
        case exit

        var payload: [String: Any] {
            switch self {
            case .hold: return ["action": "hold"]
            case .pending(let status): return ["action": "pending", "status": status.rawValue]
            case .pendingWithWrongToken:
                return ["action": "pending", "status": "builtInUnavailable", "wrongToken": true]
            case .pendingFailure:
                return ["action": "pending", "status": "failed", "failureCode": "brightness-write-failed"]
            case .restoredTwice: return ["action": "restoredTwice"]
            case .exit: return ["action": "exit"]
            }
        }
    }

    @MainActor
    final class TopologyBox {
        var value = PipeWatchdogFixture.closedLidTopology
    }

    static let externalDisplays: [AllDisplaysSleepTopology.Display] = [
        .init(id: 2, isBuiltIn: false), .init(id: 3, isBuiltIn: false)
    ]
    static var closedLidTopology: AllDisplaysSleepTopology {
        .known(lidClosed: true, displays: externalDisplays)
    }

    let root: URL
    let store: DisplayBlackoutJournalStore
    let topology = TopologyBox()
    let fallbackCalls = LockedInteger()
    var supervisor: DisplayBlackoutSupervisor?
    private var commandSequence = 0
    private var controlURL: URL { root.appendingPathComponent("control.json") }
    private var processID: pid_t? {
        guard let contents = try? String(contentsOf: root.appendingPathComponent("pid")),
              let value = Int32(contents), value > 1 else { return nil }
        return value
    }
    var processIsRunning: Bool {
        guard let processID else { return false }
        return Darwin.kill(processID, 0) == 0
    }
    var diagnosticDescription: String {
        let pidContents = try? String(contentsOf: root.appendingPathComponent("pid"))
        let exitContents = try? String(contentsOf: root.appendingPathComponent("exited"))
        return "snapshot=\(String(describing: supervisor?.snapshot)), "
            + "pid=\(pidContents ?? "missing"), exited=\(exitContents ?? "missing"), "
            + "processRunning=\(processIsRunning), fallbackCalls=\(fallbackCalls.value)"
    }

    init(initialCommand: Command) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DisplayBlackoutPipeTests-\(UUID().uuidString)", isDirectory: true
        )
        store = DisplayBlackoutJournalStore(fileURL: root
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("journal.json"))
        let original = DisplayBlackoutJournal(
            token: "prior-recovery", generation: 17, displayID: 1,
            originalBrightness: 0.7, phase: .restoring, createdAt: 100, updatedAt: 101
        )
        do {
            try store.save(original)
            let executable = root.appendingPathComponent("fake-watchdog.py")
            try Data(Self.script.utf8).write(to: executable, options: .atomic)
            guard Darwin.chmod(executable.path, mode_t(0o700)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try send(initialCommand)
            let topology = topology
            let fallbackCalls = fallbackCalls
            let journalURL = store.fileURL
            supervisor = DisplayBlackoutSupervisor(
                watchdogURLProvider: { executable },
                journalStore: store,
                capabilityProbe: { .externalDisplayConnected(count: 2) },
                sleepTopologyProbe: { topology.value },
                fallbackRecovery: { requestedURL in
                    XCTAssertEqual(requestedURL, journalURL)
                    fallbackCalls.increment()
                    return .success(.pending(.builtInUnavailable, original))
                }
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func send(_ command: Command) throws {
        commandSequence += 1
        var payload = command.payload
        payload["sequence"] = commandSequence
        try JSONSerialization.data(withJSONObject: payload).write(to: controlURL, options: .atomic)
    }

    func tearDown() async {
        supervisor?.onSnapshotChange = nil
        supervisor?.cancelAllDisplaysSleepPreparation()
        supervisor?.closeControlPipeForTermination()
        try? send(.exit)
        // Closing the parent pipe is the normal shutdown signal. Keep the main
        // actor available so Foundation can deliver termination and reap it.
        for _ in 0..<200 {
            if !processIsRunning { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if processIsRunning, let processID {
            _ = Darwin.kill(processID, SIGTERM)
            for _ in 0..<100 {
                if !processIsRunning { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let stopped = !processIsRunning
        XCTAssertTrue(stopped, "Isolated fake watchdog did not stop; keeping its fixture for diagnosis")
        supervisor = nil
        if stopped { try? FileManager.default.removeItem(at: root) }
    }

    private static let script = #"""
    #!/usr/bin/python3
    import json
    import os
    from pathlib import Path
    import select
    import struct
    import sys

    root = Path(__file__).resolve().parent
    journal = Path(os.environ["LIDLESS_DISPLAY_BLACKOUT_JOURNAL_PATH"]).resolve()
    # Never accept an environment override pointing at a real app runtime.
    if not root.name.startswith("DisplayBlackoutPipeTests-") or journal != root / "runtime" / "journal.json":
        raise SystemExit(90)

    def read_exact(count):
        result = b""
        while len(result) < count:
            chunk = sys.stdin.buffer.read(count - len(result))
            if not chunk:
                return None
            result += chunk
        return result

    def read_frame():
        header = read_exact(4)
        if header is None:
            return None
        count = struct.unpack(">I", header)[0]
        if not 0 < count <= 4096:
            raise ValueError("invalid frame size")
        payload = read_exact(count)
        return None if payload is None else json.loads(payload)

    def respond(request, status, pending, command):
        response = {key: request[key] for key in (
            "protocolVersion", "versionAdvertisement", "token", "generation"
        )}
        response.update(status=status, recoveryPending=pending, journalPhase="restoring")
        if command.get("wrongToken"):
            response["token"] = "different-child-token"
        if "failureCode" in command:
            response["failureCode"] = command["failureCode"]
        payload = json.dumps(response, separators=(",", ":")).encode()
        sys.stdout.buffer.write(struct.pack(">I", len(payload)) + payload)
        sys.stdout.buffer.flush()

    try:
        request = read_frame()
        if request is None:
            raise SystemExit(0)
        (root / "pid").write_text(str(os.getpid()))
        last_sequence = None
        while True:
            command = json.loads((root / "control.json").read_text())
            if command["sequence"] != last_sequence:
                last_sequence = command["sequence"]
                action = command["action"]
                if action == "pending":
                    respond(request, command["status"], True, command)
                elif action == "restoredTwice":
                    journal.unlink()
                    respond(request, "restored", False, {})
                    respond(request, "restored", False, {})
                    break
                elif action == "exit":
                    break
            readable, _, _ = select.select([sys.stdin.buffer], [], [], 0.01)
            if readable and read_frame() is None:
                break
    finally:
        (root / "exited").write_text(str(os.getpid()))
        sys.stdin.close()
        sys.stdout.close()
    """#
}

private final class LockedInteger: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
