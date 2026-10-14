import XCTest

@MainActor
final class AllDisplaysSleepControllerTests: XCTestCase {
    func testWaitsFromClickForOneAndAHalfSecondsAndRejectsDuplicateRequests() {
        let environment = Environment()
        let controller = environment.makeController()
        XCTAssertEqual(controller.snapshot.phase, .idle)
        XCTAssertFalse(controller.snapshot.suspendsDisplayAwake)

        controller.request { $0(.ready) }
        XCTAssertEqual(controller.snapshot.phase, .scheduled)
        XCTAssertTrue(controller.snapshot.isBusy)
        XCTAssertTrue(controller.snapshot.suspendsDisplayAwake)
        environment.advance(by: 1.49)
        controller.request { _ in XCTFail("A duplicate must not prepare or change the delay") }
        XCTAssertEqual(environment.commandCompletions.count, 0)
        environment.advance(by: 0.01)
        XCTAssertEqual(environment.commandCompletions.count, 1)
        XCTAssertEqual(controller.snapshot.phase, .requesting)
    }

    func testSlowPreparationUsesOriginalClickDeadline() {
        let environment = Environment()
        let controller = environment.makeController()
        var finishPreparation: ((AllDisplaysSleepPreparation) -> Void)?
        controller.request { finishPreparation = $0 }
        environment.advance(by: 2)
        XCTAssertEqual(controller.snapshot.phase, .preparing)
        XCTAssertTrue(controller.snapshot.suspendsDisplayAwake)
        XCTAssertTrue(environment.commandCompletions.isEmpty)
        finishPreparation?(.ready)
        environment.advance(by: 0)
        XCTAssertEqual(environment.commandCompletions.count, 1)
    }

    func testFailedPreparationNeverRunsCommandAndReleasesGate() {
        let environment = Environment()
        let controller = environment.makeController()
        controller.request { $0(.blocked(.recoveryFailed)) }
        environment.advance(by: 10)
        XCTAssertTrue(environment.commandCompletions.isEmpty)
        XCTAssertEqual(controller.snapshot.failure, .preparationFailed)
        XCTAssertEqual(controller.snapshot.phase, .idle)
        XCTAssertFalse(controller.snapshot.suspendsDisplayAwake)
    }

    func testPreparationTimeoutRejectsLateCompletion() {
        let environment = Environment()
        let controller = environment.makeController()
        var finishPreparation: ((AllDisplaysSleepPreparation) -> Void)?
        controller.request { finishPreparation = $0 }
        environment.advance(by: AllDisplaysSleepController.preparationTimeout)
        XCTAssertEqual(controller.snapshot.failure, .preparationFailed)
        XCTAssertEqual(controller.snapshot.preparationFailure, .timedOut)
        finishPreparation?(.ready)
        environment.advance(by: 10)
        XCTAssertTrue(environment.commandCompletions.isEmpty)
    }

    func testSuccessfulCommandMustConfirmEveryDisplayAndWakeReleasesGate() {
        let environment = Environment()
        let controller = environment.makeController()
        startCommand(controller, environment)
        environment.completeCommand()
        XCTAssertEqual(controller.snapshot.phase, .confirming)
        XCTAssertTrue(controller.snapshot.isBusy)
        environment.displayState = .online(asleep: [true, true, true])
        environment.advance(by: 0.25)
        XCTAssertEqual(controller.snapshot.phase, .asleep)
        XCTAssertFalse(controller.snapshot.isBusy)
        XCTAssertTrue(controller.snapshot.suspendsDisplayAwake)
        XCTAssertNil(controller.snapshot.failure)
        controller.request { _ in XCTFail("Asleep is still the same manual operation") }
        environment.advance(by: 10)
        XCTAssertEqual(environment.commandCompletions.count, 1)
        environment.emit(.displaysWoke)
        XCTAssertEqual(controller.snapshot.phase, .idle)
        XCTAssertFalse(controller.snapshot.suspendsDisplayAwake)
    }

    func testExitZeroWithStderrIsFailureEvenWhenDisplaysAreReportedAsleep() {
        let environment = Environment()
        let controller = environment.makeController()
        environment.displayState = .online(asleep: [true, true])
        startCommand(controller, environment)
        environment.completeCommand(.finished(
            exitStatus: 0,
            stdout: "",
            stderr: "pmset: Failed to put the display to sleep, error 1000\n"
        ))
        XCTAssertEqual(controller.snapshot.failure, .commandFailed)
        XCTAssertFalse(controller.snapshot.suspendsDisplayAwake)
    }

    func testNonzeroExitAndLaunchFailureHaveStableFailureCategories() {
        let results: [(AllDisplaysSleepController.CommandResult, AllDisplaysSleepController.Failure)] = [
            (.launchFailed, .commandLaunchFailed),
            (.finished(exitStatus: 1, stdout: "", stderr: ""), .commandFailed)
        ]
        for (result, failure) in results {
            let environment = Environment()
            let controller = environment.makeController()
            startCommand(controller, environment)
            environment.completeCommand(result)
            XCTAssertEqual(controller.snapshot.failure, failure)
            XCTAssertEqual(controller.snapshot.phase, .idle)
            XCTAssertFalse(controller.snapshot.suspendsDisplayAwake)
        }
    }

    func testCommandTimeoutCancelsProcessAndIgnoresLateCompletion() {
        let environment = Environment()
        let controller = environment.makeController()
        startCommand(controller, environment)
        environment.advance(by: 4.99)
        XCTAssertEqual(controller.snapshot.phase, .requesting)
        environment.advance(by: 0.01)
        XCTAssertEqual(controller.snapshot.failure, .commandTimedOut)
        XCTAssertEqual(environment.commandCancellations, [0])
        environment.displayState = .online(asleep: [true])
        environment.completeCommand()
        XCTAssertEqual(controller.snapshot.failure, .commandTimedOut)
        XCTAssertEqual(controller.snapshot.phase, .idle)
    }

    func testPartialUnknownAndEmptyDisplaySetsNeverConfirmSuccess() {
        let states: [AllDisplaysSleepController.DisplayState] = [
            .online(asleep: [true, false]), .unknown, .online(asleep: [])
        ]
        for state in states {
            let environment = Environment()
            let controller = environment.makeController()
            environment.displayState = state
            startCommand(controller, environment)
            environment.completeCommand()
            environment.emit(.displaysSlept)
            XCTAssertEqual(controller.snapshot.phase, .confirming)
            environment.advance(by: 5)
            XCTAssertEqual(controller.snapshot.failure, .confirmationTimedOut)
            XCTAssertFalse(controller.snapshot.suspendsDisplayAwake)
            environment.advance(by: 20)
            XCTAssertEqual(environment.commandCompletions.count, 1)
        }
    }

    func testConfirmationGetsItsOwnFiveSecondsAfterCommandCompletion() {
        let environment = Environment()
        let controller = environment.makeController()
        startCommand(controller, environment)
        environment.advance(by: 4)
        environment.completeCommand()
        environment.advance(by: 4.99)
        XCTAssertEqual(controller.snapshot.phase, .confirming)
        environment.advance(by: 0.01)
        XCTAssertEqual(controller.snapshot.failure, .confirmationTimedOut)
    }

    func testSleepNotificationTriggersAProbeButCannotReplaceIt() {
        let environment = Environment()
        let controller = environment.makeController()
        startCommand(controller, environment)
        environment.emit(.displaysSlept)
        XCTAssertEqual(controller.snapshot.phase, .requesting)
        environment.completeCommand()
        environment.emit(.displaysSlept)
        XCTAssertEqual(controller.snapshot.phase, .confirming)
        environment.displayState = .online(asleep: [true, true])
        environment.emit(.displaysSlept)
        XCTAssertEqual(controller.snapshot.phase, .asleep)
    }

    func testWakeWhileCommandRunsCancelsAndLateSleepCannotRearm() {
        let environment = Environment()
        let controller = environment.makeController()
        startCommand(controller, environment)
        environment.emit(.displaysWoke)
        XCTAssertEqual(environment.commandCancellations, [0])
        environment.displayState = .online(asleep: [true])
        environment.completeCommand()
        environment.emit(.displaysSlept, observer: 0)
        environment.advance(by: 10)
        XCTAssertEqual(controller.snapshot.phase, .idle)
        XCTAssertFalse(controller.snapshot.suspendsDisplayAwake)
        XCTAssertNil(controller.snapshot.failure)
    }

    func testSystemSleepAndWakeCancelWithoutLaunchingPendingCommand() {
        for event in [AllDisplaysSleepController.ScreenEvent.systemWillSleep, .systemDidWake] {
            let environment = Environment()
            let controller = environment.makeController()
            controller.request { $0(.ready) }
            environment.emit(event)
            environment.advance(by: 10)
            XCTAssertTrue(environment.commandCompletions.isEmpty)
            XCTAssertEqual(controller.snapshot.phase, .idle)
        }
    }

    func testCancelInvalidatesPreparationAndCancelledTimerCallbacks() {
        let environment = Environment()
        let controller = environment.makeController()
        var finishPreparation: ((AllDisplaysSleepPreparation) -> Void)?
        controller.request { finishPreparation = $0 }
        controller.cancel()
        controller.request { $0(.ready) }
        finishPreparation?(.blocked(.recoveryFailed))
        // Deliberately deliver removed timers from the first operation.
        environment.jobs[0].action()
        XCTAssertEqual(controller.snapshot.phase, .scheduled)
        environment.advance(by: 1.5)
        XCTAssertEqual(environment.commandCompletions.count, 1)
        XCTAssertNil(controller.snapshot.failure)
    }

    func testCancelledDelayCannotLaunchEvenIfItsCallbackWasAlreadyQueued() {
        let environment = Environment()
        let controller = environment.makeController()
        controller.request { $0(.ready) }
        let delayedCommand = environment.jobs.last!
        controller.cancel()
        delayedCommand.action()
        environment.advance(by: 10)
        XCTAssertTrue(environment.commandCompletions.isEmpty)
        XCTAssertEqual(controller.snapshot.phase, .idle)
    }

    func testOldCommandAndObserverCallbacksCannotAffectNewOperation() {
        let environment = Environment()
        let controller = environment.makeController()
        startCommand(controller, environment)
        controller.cancel()
        controller.request { $0(.ready) }
        environment.completeCommand(.launchFailed, index: 0)
        environment.emit(.displaysWoke, observer: 0)
        environment.emit(.systemWillSleep, observer: 0)
        XCTAssertEqual(controller.snapshot.phase, .scheduled)
        environment.advance(by: 1.5)
        environment.displayState = .online(asleep: [true, true])
        environment.completeCommand(index: 1)
        XCTAssertEqual(controller.snapshot.phase, .asleep)
    }

    func testWakeBeforeDelayedSleepNotificationLeavesNewRequestAvailable() {
        let environment = Environment()
        let controller = environment.makeController()
        startCommand(controller, environment)
        environment.completeCommand()
        environment.emit(.displaysWoke)
        environment.emit(.displaysSlept, observer: 0)
        XCTAssertEqual(controller.snapshot.phase, .idle)
        controller.request { $0(.ready) }
        environment.advance(by: 1.5)
        XCTAssertEqual(environment.commandCompletions.count, 2)
    }

    func testCancelFromSnapshotObserverDoesNotLeaveFutureSleepScheduled() {
        let environment = Environment()
        let controller = environment.makeController()
        controller.onSnapshotChange = { [weak controller] state in
            if state.phase == .scheduled { controller?.cancel() }
        }
        controller.request { $0(.ready) }
        environment.advance(by: 10)
        XCTAssertTrue(environment.commandCompletions.isEmpty)
        XCTAssertEqual(controller.snapshot.phase, .idle)
    }

    func testCancellationIsIdempotentEvenWhenCleanupRepliesSynchronously() {
        let environment = Environment()
        environment.completesWhenCancelled = true
        let controller = environment.makeController()
        startCommand(controller, environment)
        controller.cancel()
        controller.cancel()
        XCTAssertEqual(environment.commandCancellations, [0])
        XCTAssertEqual(controller.snapshot.phase, .idle)
        XCTAssertNil(controller.snapshot.failure)
    }

    func testSynchronousLauncherCompletionDoesNotRetainAStaleCommand() {
        let environment = Environment()
        environment.synchronousResult = .launchFailed
        let controller = environment.makeController()
        startCommand(controller, environment)
        XCTAssertEqual(controller.snapshot.failure, .commandLaunchFailed)
        XCTAssertEqual(environment.commandCancellations, [0])
        controller.cancel()
        XCTAssertEqual(environment.commandCancellations, [0])
    }

    func testRefreshEndsSleepWhenAnyCurrentDisplayWakesWithoutANotification() {
        let environment = Environment()
        let controller = environment.makeController()
        environment.displayState = .online(asleep: [true, true])
        startCommand(controller, environment)
        environment.completeCommand()
        XCTAssertEqual(controller.snapshot.phase, .asleep)
        environment.displayState = .online(asleep: [true, true, false])
        controller.refreshDisplayState()
        XCTAssertEqual(controller.snapshot.phase, .idle)
        XCTAssertFalse(controller.snapshot.suspendsDisplayAwake)
        XCTAssertEqual(environment.commandCompletions.count, 1)
    }

    func testRefreshDoesNotInventAWakeFromUnknownOrEmptyDisplaySets() {
        let environment = Environment()
        let controller = environment.makeController()
        environment.displayState = .online(asleep: [true])
        startCommand(controller, environment)
        environment.completeCommand()
        for state in [AllDisplaysSleepController.DisplayState.unknown, .online(asleep: []),
                      .online(asleep: [true, true])] {
            environment.displayState = state
            controller.refreshDisplayState()
            XCTAssertEqual(controller.snapshot.phase, .asleep)
            XCTAssertTrue(controller.snapshot.suspendsDisplayAwake)
        }
    }

    func testRefreshDuringConfirmationCannotCancelAnIncompleteRequest() {
        let environment = Environment()
        let controller = environment.makeController()
        startCommand(controller, environment)
        environment.completeCommand()
        controller.refreshDisplayState()
        XCTAssertEqual(controller.snapshot.phase, .confirming)
    }

    func testDeferredRecoveryAllowsOneCommandWithoutAnAdditionalDelay() {
        let environment = Environment()
        let controller = environment.makeController()
        var revalidationCount = 0
        controller.request(
            prepare: { $0(.deferredBuiltInRecovery) },
            revalidate: {
                revalidationCount += 1
                return .deferredBuiltInRecovery
            }
        )
        environment.advance(by: 1.49)
        XCTAssertTrue(environment.commandCompletions.isEmpty)
        environment.advance(by: 0.01)
        XCTAssertEqual(environment.commandCompletions.count, 1)
        XCTAssertEqual(revalidationCount, 1)
        XCTAssertNil(controller.snapshot.preparationFailure)
    }

    func testEveryBlockedPreparationPreservesItsSpecificReason() {
        let reasons: [AllDisplaysSleepPreparationFailure] = [
            .builtInUnavailable, .brightnessUnavailable, .topologyUnknown,
            .invalidRecoveryRecord, .recoveryUnavailable, .recoveryFailed, .timedOut
        ]
        for reason in reasons {
            let environment = Environment()
            let controller = environment.makeController()
            controller.request { $0(.blocked(reason)) }
            environment.advance(by: 10)
            XCTAssertEqual(controller.snapshot.failure, .preparationFailed)
            XCTAssertEqual(controller.snapshot.preparationFailure, reason)
            XCTAssertTrue(environment.commandCompletions.isEmpty)
        }
    }

    func testPrelaunchRevalidationFailureNeverLaunchesAndPreservesReason() {
        let environment = Environment()
        let controller = environment.makeController()
        controller.request(
            prepare: { $0(.deferredBuiltInRecovery) },
            revalidate: { .blocked(.recoveryUnavailable) }
        )
        environment.advance(by: 1.5)
        XCTAssertEqual(controller.snapshot.failure, .preparationFailed)
        XCTAssertEqual(controller.snapshot.preparationFailure, .recoveryUnavailable)
        XCTAssertTrue(environment.commandCompletions.isEmpty)
        XCTAssertFalse(controller.snapshot.suspendsDisplayAwake)
    }

    func testOpeningLidCancelsPendingRequestEvenWithTheSameExternalDisplays() {
        let environment = Environment()
        let controller = environment.makeController()
        controller.request { $0(.deferredBuiltInRecovery) }
        environment.topology = .known(lidClosed: false, displays: Environment.externalDisplays)
        environment.emit(.topologyChanged)
        environment.advance(by: 10)
        XCTAssertEqual(controller.snapshot.phase, .idle)
        XCTAssertNil(controller.snapshot.failure)
        XCTAssertTrue(environment.commandCompletions.isEmpty)
    }

    func testReplacingDisplayWithSameCountCancelsPendingRequest() {
        let environment = Environment()
        let controller = environment.makeController()
        controller.request { $0(.ready) }
        environment.topology = .known(lidClosed: true, displays: [
            .init(id: 10, isBuiltIn: false), .init(id: 99, isBuiltIn: false)
        ])
        environment.emit(.topologyChanged)
        environment.advance(by: 10)
        XCTAssertEqual(controller.snapshot.phase, .idle)
        XCTAssertTrue(environment.commandCompletions.isEmpty)
    }

    func testChangingBuiltInClassificationCancelsEvenWithTheSameDisplayIDs() {
        let environment = Environment()
        let controller = environment.makeController()
        controller.request { $0(.ready) }
        environment.topology = .known(lidClosed: true, displays: [
            .init(id: 10, isBuiltIn: true), .init(id: 20, isBuiltIn: false)
        ])
        environment.emit(.topologyChanged)
        environment.advance(by: 1.5)
        XCTAssertEqual(controller.snapshot.phase, .idle)
        XCTAssertTrue(environment.commandCompletions.isEmpty)
    }

    func testTopologyPollCancelsPreparationWhenTheNotificationIsMissed() {
        let environment = Environment()
        let controller = environment.makeController()
        var completion: ((AllDisplaysSleepPreparation) -> Void)?
        controller.request { completion = $0 }
        environment.topology = .known(lidClosed: false, displays: Environment.externalDisplays)
        environment.advance(by: AllDisplaysSleepController.topologyPollInterval)
        completion?(.ready)
        environment.advance(by: 10)
        XCTAssertEqual(controller.snapshot.phase, .idle)
        XCTAssertTrue(environment.commandCompletions.isEmpty)
    }

    func testFinalTopologyCheckCatchesChangeAfterLastPollWithoutANotification() {
        let environment = Environment()
        let controller = environment.makeController()
        controller.request { $0(.ready) }
        environment.advance(by: 1.49)
        environment.topology = .known(lidClosed: false, displays: Environment.externalDisplays)
        environment.advance(by: 0.01)
        XCTAssertTrue(environment.commandCompletions.isEmpty)
        XCTAssertEqual(controller.snapshot.phase, .idle)
    }

    func testUnknownAndMalformedTopologyFailClosedBeforePreparation() {
        let topologies: [AllDisplaysSleepTopology] = [
            .unknown, .known(lidClosed: true, displays: []),
            .known(lidClosed: true, displays: [
                .init(id: 10, isBuiltIn: false), .init(id: 10, isBuiltIn: false)
            ])
        ]
        for topology in topologies {
            let environment = Environment()
            environment.topology = topology
            let controller = environment.makeController()
            controller.request { _ in XCTFail("Unknown topology must not prepare") }
            environment.advance(by: 10)
            XCTAssertEqual(controller.snapshot.failure, .preparationFailed)
            XCTAssertEqual(controller.snapshot.preparationFailure, .topologyUnknown)
            XCTAssertTrue(environment.commandCompletions.isEmpty)
        }
    }

    func testTopologyBecomingUnknownFailsClosedDuringPendingDelay() {
        let environment = Environment()
        let controller = environment.makeController()
        controller.request { $0(.ready) }
        environment.topology = .unknown
        environment.advance(by: AllDisplaysSleepController.topologyPollInterval)
        XCTAssertEqual(controller.snapshot.failure, .preparationFailed)
        XCTAssertEqual(controller.snapshot.preparationFailure, .topologyUnknown)
        environment.advance(by: 10)
        XCTAssertTrue(environment.commandCompletions.isEmpty)
    }

    func testTopologyNotificationWithUnchangedIdentityDoesNotCancel() {
        let environment = Environment()
        let controller = environment.makeController()
        controller.request { $0(.ready) }
        environment.emit(.topologyChanged)
        environment.advance(by: 1.5)
        XCTAssertEqual(environment.commandCompletions.count, 1)
    }

    func testAlreadySubmittedCommandNeverRepeatsOnTopologyChange() {
        let environment = Environment()
        let controller = environment.makeController()
        startCommand(controller, environment)
        environment.topology = .known(lidClosed: false, displays: [
            .init(id: 1, isBuiltIn: true), .init(id: 20, isBuiltIn: false)
        ])
        environment.emit(.topologyChanged)
        environment.completeCommand()
        environment.displayState = .online(asleep: [true, false])
        environment.emit(.topologyChanged)
        XCTAssertEqual(controller.snapshot.phase, .confirming)
        environment.displayState = .online(asleep: [true, true])
        environment.emit(.topologyChanged)
        XCTAssertEqual(controller.snapshot.phase, .asleep)
        environment.advance(by: 20)
        XCTAssertEqual(environment.commandCompletions.count, 1)
    }

    func testSynchronousObserverWakePreventsPreparationAndCleansUpObserver() {
        let environment = Environment()
        environment.synchronousObservation = .displaysWoke
        let controller = environment.makeController()
        controller.request { _ in XCTFail("Wake during registration must invalidate preparation") }
        environment.advance(by: 10)
        XCTAssertEqual(controller.snapshot.phase, .idle)
        XCTAssertEqual(environment.observerCancellations, [0])
        XCTAssertTrue(environment.commandCompletions.isEmpty)
    }

    func testSynchronousRevalidationCancellationCannotResurrectTheRequest() {
        let environment = Environment()
        let controller = environment.makeController()
        controller.request(
            prepare: { $0(.ready) },
            revalidate: {
                controller.cancel()
                return .ready
            }
        )
        environment.advance(by: 10)
        XCTAssertEqual(controller.snapshot.phase, .idle)
        XCTAssertTrue(environment.commandCompletions.isEmpty)
    }

    func testTopologyChangeFromRequestingSnapshotIsRecheckedBeforeLaunch() {
        let environment = Environment()
        let controller = environment.makeController()
        controller.onSnapshotChange = { snapshot in
            if snapshot.phase == .requesting {
                environment.topology = .known(lidClosed: false, displays: Environment.externalDisplays)
            }
        }
        controller.request { $0(.ready) }
        environment.advance(by: 10)
        XCTAssertEqual(controller.snapshot.phase, .idle)
        XCTAssertTrue(environment.commandCompletions.isEmpty)
    }

    func testCancelledTopologyTimerCannotAffectANewRequest() {
        let environment = Environment()
        let controller = environment.makeController()
        controller.request { $0(.ready) }
        let oldJobs = environment.jobs
        controller.cancel()
        controller.request { $0(.ready) }
        oldJobs.forEach { $0.action() }
        environment.advance(by: 1.5)
        XCTAssertEqual(controller.snapshot.phase, .requesting)
        XCTAssertEqual(environment.commandCompletions.count, 1)
        XCTAssertNil(controller.snapshot.failure)
    }

    func testPreparationTimerCleanupCancellationCannotPublishScheduledAgain() {
        let environment = Environment()
        let controller = environment.makeController()
        var completion: ((AllDisplaysSleepPreparation) -> Void)?
        controller.request { completion = $0 }
        environment.timerCancellationAction = { controller.cancel() }
        completion?(.ready)
        environment.advance(by: 10)
        XCTAssertEqual(controller.snapshot.phase, .idle)
        XCTAssertTrue(environment.commandCompletions.isEmpty)
    }

    func testCommandTimerCleanupCancellationCannotPublishConfirmingAgain() {
        let environment = Environment()
        let controller = environment.makeController()
        startCommand(controller, environment)
        environment.timerCancellationAction = { controller.cancel() }
        environment.completeCommand()
        environment.advance(by: 10)
        XCTAssertEqual(controller.snapshot.phase, .idle)
        XCTAssertFalse(controller.snapshot.suspendsDisplayAwake)
        XCTAssertEqual(environment.commandCompletions.count, 1)
    }

    func testNewRequestFromSynchronousObserverCancellationKeepsItsOwnTimers() {
        let environment = Environment()
        environment.synchronousObservation = .displaysWoke
        let controller = environment.makeController()
        var restarted = false
        controller.onSnapshotChange = { snapshot in
            if snapshot.phase == .idle, !restarted {
                restarted = true
                environment.synchronousObservation = nil
                controller.request { $0(.ready) }
            }
        }
        controller.request { _ in XCTFail("The cancelled original must not prepare") }
        environment.advance(by: 1.5)
        XCTAssertTrue(restarted)
        XCTAssertEqual(environment.observerCancellations, [0])
        XCTAssertEqual(controller.snapshot.phase, .requesting)
        XCTAssertEqual(environment.commandCompletions.count, 1)
    }

    private func startCommand(
        _ controller: AllDisplaysSleepController,
        _ environment: Environment
    ) {
        controller.request { $0(.ready) }
        environment.advance(by: AllDisplaysSleepController.clickDelay)
    }

    @MainActor
    private final class Environment {
        final class Job {
            let due: TimeInterval
            let action: () -> Void
            var cancelled = false
            var fired = false
            init(due: TimeInterval, action: @escaping () -> Void) {
                self.due = due
                self.action = action
            }
        }

        var now: TimeInterval = 100
        var jobs: [Job] = []
        var displayState: AllDisplaysSleepController.DisplayState = .online(asleep: [false, false])
        static let externalDisplays: [AllDisplaysSleepTopology.Display] = [
            .init(id: 10, isBuiltIn: false), .init(id: 20, isBuiltIn: false)
        ]
        var topology: AllDisplaysSleepTopology = .known(lidClosed: true, displays: externalDisplays)
        var commandCompletions: [(AllDisplaysSleepController.CommandResult) -> Void] = []
        var commandCancellations: [Int] = []
        var observers: [(AllDisplaysSleepController.ScreenEvent) -> Void] = []
        var observerCancellations: [Int] = []
        var synchronousObservation: AllDisplaysSleepController.ScreenEvent?
        var timerCancellationAction: (() -> Void)?
        var completesWhenCancelled = false
        var synchronousResult: AllDisplaysSleepController.CommandResult?

        func makeController() -> AllDisplaysSleepController {
            AllDisplaysSleepController(dependencies: .init(
                uptime: { self.now },
                schedule: { delay, action in
                    let job = Job(due: self.now + delay, action: action)
                    self.jobs.append(job)
                    return .init {
                        job.cancelled = true
                        let action = self.timerCancellationAction
                        self.timerCancellationAction = nil
                        action?()
                    }
                },
                launch: { completion in
                    let index = self.commandCompletions.count
                    self.commandCompletions.append(completion)
                    if let result = self.synchronousResult { completion(result) }
                    return .init {
                        self.commandCancellations.append(index)
                        if self.completesWhenCancelled { completion(.launchFailed) }
                    }
                },
                probe: { self.displayState },
                observe: { handler in
                    let index = self.observers.count
                    self.observers.append(handler)
                    if let event = self.synchronousObservation { handler(event) }
                    return .init { self.observerCancellations.append(index) }
                },
                topology: { self.topology }
            ))
        }

        func advance(by interval: TimeInterval) {
            let end = now + interval
            while let job = jobs.filter({ !$0.cancelled && !$0.fired && $0.due <= end })
                .min(by: { $0.due < $1.due }) {
                now = job.due
                job.fired = true
                job.action()
            }
            now = end
        }

        func completeCommand(
            _ result: AllDisplaysSleepController.CommandResult = .finished(
                exitStatus: 0, stdout: "", stderr: ""
            ),
            index: Int = 0
        ) {
            commandCompletions[index](result)
        }

        func emit(_ event: AllDisplaysSleepController.ScreenEvent, observer: Int? = nil) {
            guard !observers.isEmpty else { return }
            observers[observer ?? observers.count - 1](event)
        }
    }
}
