import Combine
import XCTest

@MainActor
final class AudioInputDeviceControllerTests: XCTestCase {
    private let primary = AudioInputSelection(uid: "uid-a", lastKnownName: "Primary")
    private let secondary = AudioInputSelection(uid: "uid-b", lastKnownName: "Secondary")

    func testRefreshFiltersInvalidInputsAndPublishesActivity() {
        let stub = StubAudioInputSystem(sample: AudioInputTopologySample(
            devices: [
                snapshot(id: 1, uid: "valid", name: " Valid ", running: true),
                snapshot(id: 2, uid: "output", name: "Output", hasInput: false),
                snapshot(id: 3, uid: "dead", name: "Dead", isAlive: false),
                snapshot(id: 4, uid: "not-default", name: "No", canBeDefault: false),
                snapshot(id: 5, uid: "hidden", name: "Hidden", isHidden: true),
                snapshot(id: 6, uid: " ", name: "Missing UID"),
            ],
            defaultInputUID: "valid"
        ))

        let controller = makeController(stub: stub)

        XCTAssertEqual(controller.availableInputs, [
            AudioInputChoice(
                uid: "valid",
                displayName: "Valid",
                isAvailable: true,
                isRunningSomewhere: true
            ),
        ])
        XCTAssertEqual(controller.defaultInputUID, "valid")
        XCTAssertEqual(controller.topologyGeneration, 1)
    }

    func testChoicesRetainOfflineSelectionWithoutMakingItEligible() {
        let stub = StubAudioInputSystem(sample: configuredSample(defaultUID: primary.uid))
        let controller = makeController(stub: stub)

        let choices = controller.choices(retaining: [
            primary,
            AudioInputSelection(uid: "uid-z", lastKnownName: " Offline "),
        ])

        let offline = choices.first { $0.uid == "uid-z" }
        XCTAssertEqual(offline?.displayName, "Offline")
        XCTAssertEqual(offline?.isAvailable, false)
        XCTAssertEqual(offline?.isRunningSomewhere, nil)
        XCTAssertEqual(offline?.isSwitchEligible, false)
    }

    func testDeviceNotificationsUseFixedTwoHundredMillisecondBatchWindow() async {
        let clock = ManualAudioClock()
        let stub = StubAudioInputSystem(sample: configuredSample(defaultUID: primary.uid))
        let controller = makeController(stub: stub, clock: clock, observes: true)
        XCTAssertEqual(stub.readCount, 1)

        stub.emit(.devicesChanged)
        stub.emit(.devicesChanged)
        stub.emit(.devicesChanged)
        await drainTasks()
        XCTAssertEqual(clock.requestedSleeps.filter { $0 == 0.2 }.count, 1)

        clock.advance(by: 0.199)
        await drainTasks()
        XCTAssertEqual(stub.readCount, 1)

        clock.advance(by: 0.001)
        await drainTasks()
        XCTAssertEqual(stub.readCount, 2)
        XCTAssertEqual(controller.topologyGeneration, 1, "identical samples are deduplicated")
    }

    func testPureDefaultChangePublishesAtArbitrationDeadline() async {
        let clock = ManualAudioClock()
        let stub = StubAudioInputSystem(sample: configuredSample(defaultUID: primary.uid))
        let controller = makeController(stub: stub, clock: clock, observes: true)

        stub.setDefaultWithoutRecording(secondary.uid)
        stub.emit(.defaultInputChanged)
        await drainTasks()
        XCTAssertEqual(controller.defaultInputUID, primary.uid)

        clock.advance(by: 0.2)
        await drainTasks()
        XCTAssertEqual(controller.defaultInputUID, secondary.uid)
        XCTAssertEqual(controller.topologyGeneration, 1)
    }

    func testDefaultBeforeDevicesDoesNotFlashAndUsesReconnectGrace() async {
        let clock = ManualAudioClock()
        let stub = StubAudioInputSystem(sample: configuredSample(defaultUID: primary.uid))
        let controller = makeController(stub: stub, clock: clock, observes: true)

        stub.sample = AudioInputTopologySample(
            devices: [snapshot(id: 20, uid: secondary.uid, name: "Secondary")],
            defaultInputUID: secondary.uid
        )
        stub.emit(.defaultInputChanged)
        await drainTasks()
        stub.emit(.devicesChanged)
        await drainTasks()

        clock.advance(by: 0.2)
        await drainTasks()
        XCTAssertEqual(controller.defaultInputUID, primary.uid)
        XCTAssertEqual(controller.availableInputs.first { $0.uid == primary.uid }?.stability, .reconnecting)

        clock.advance(by: 1.999)
        await drainTasks()
        XCTAssertEqual(controller.defaultInputUID, primary.uid)

        clock.advance(by: 0.001)
        await drainTasks()
        XCTAssertEqual(controller.defaultInputUID, secondary.uid)
    }

    func testDeviceReturningInsideReconnectWindowKeepsDefaultAndBecomesStable() async {
        let clock = ManualAudioClock()
        let stub = StubAudioInputSystem(sample: configuredSample(defaultUID: primary.uid))
        let controller = makeController(stub: stub, clock: clock, observes: true)

        stub.sample = AudioInputTopologySample(
            devices: [snapshot(id: 20, uid: secondary.uid, name: "Secondary")],
            defaultInputUID: secondary.uid
        )
        stub.emit(.defaultInputChanged)
        stub.emit(.devicesChanged)
        await drainTasks()
        clock.advance(by: 0.2)
        await drainTasks()
        XCTAssertEqual(controller.defaultInputUID, primary.uid)
        XCTAssertEqual(controller.availableInputs.first { $0.uid == primary.uid }?.stability, .reconnecting)

        clock.advance(by: 1)
        stub.sample = configuredSample(defaultUID: primary.uid)
        stub.emit(.devicesChanged)
        await drainTasks()
        clock.advance(by: 0.2)
        await drainTasks()

        XCTAssertEqual(controller.defaultInputUID, primary.uid)
        XCTAssertEqual(controller.availableInputs.first { $0.uid == primary.uid }?.stability, .stable)
        XCTAssertEqual(controller.availableInputs.first { $0.uid == primary.uid }?.isAvailable, true)
    }

    func testReadFailureDuringDeviceBatchDoesNotCreateAFlap() async {
        let clock = ManualAudioClock()
        let stub = StubAudioInputSystem(sample: configuredSample(defaultUID: primary.uid))
        let controller = makeController(stub: stub, clock: clock, observes: true)
        let generation = controller.topologyGeneration

        stub.failNextReads = 1
        stub.emit(.devicesChanged)
        await drainTasks()
        clock.advance(by: 0.2)
        await drainTasks()

        XCTAssertEqual(controller.topologyGeneration, generation)
        XCTAssertEqual(controller.availableInputs.first { $0.uid == secondary.uid }?.stability, .stable)
        XCTAssertEqual(controller.lastError, .refreshFailed)
    }

    func testTwoLossReappearanceCyclesWithinTwentySecondsMarkUIDUnstable() async {
        let clock = ManualAudioClock()
        let stub = StubAudioInputSystem(sample: configuredSample(defaultUID: primary.uid))
        let controller = makeController(stub: stub, clock: clock, observes: true)

        await flapSecondary(stub: stub, clock: clock)
        XCTAssertEqual(controller.availableInputs.first { $0.uid == secondary.uid }?.stability, .stable)
        await flapSecondary(stub: stub, clock: clock)

        let choice = controller.availableInputs.first { $0.uid == secondary.uid }
        XCTAssertEqual(choice?.stability, .unstable)
        XCTAssertEqual(choice?.isSwitchEligible, false)
    }

    func testTwoDirectObjectIDChangesWithinWindowMarkUIDUnstable() async {
        let clock = ManualAudioClock()
        let stub = StubAudioInputSystem(sample: configuredSample(defaultUID: primary.uid))
        let controller = makeController(stub: stub, clock: clock, observes: true)

        stub.sample = sampleWithSecondaryObjectID(21)
        stub.emit(.devicesChanged)
        await drainTasks()
        clock.advance(by: 0.2)
        await drainTasks()
        XCTAssertEqual(controller.availableInputs.first { $0.uid == secondary.uid }?.stability, .stable)

        stub.sample = sampleWithSecondaryObjectID(22)
        stub.emit(.devicesChanged)
        await drainTasks()
        clock.advance(by: 0.2)
        await drainTasks()
        XCTAssertEqual(controller.availableInputs.first { $0.uid == secondary.uid }?.stability, .unstable)
    }

    func testSecondCycleAfterTwentySecondBoundaryDoesNotMarkUnstable() async {
        let clock = ManualAudioClock()
        let stub = StubAudioInputSystem(sample: configuredSample(defaultUID: primary.uid))
        let controller = makeController(stub: stub, clock: clock, observes: true)

        await flapSecondary(stub: stub, clock: clock)
        clock.advance(by: 20.001)
        await flapSecondary(stub: stub, clock: clock)

        XCTAssertEqual(controller.availableInputs.first { $0.uid == secondary.uid }?.stability, .stable)
    }

    func testUnstableUIDRecoversOnlyAfterQuietAndTwoProbes() async {
        let clock = ManualAudioClock()
        let stub = StubAudioInputSystem(sample: configuredSample(defaultUID: primary.uid))
        let controller = makeController(stub: stub, clock: clock, observes: true)
        await flapSecondary(stub: stub, clock: clock)
        await flapSecondary(stub: stub, clock: clock)
        XCTAssertEqual(controller.availableInputs.first { $0.uid == secondary.uid }?.stability, .unstable)

        clock.advance(by: 14.999)
        await drainTasks()
        XCTAssertEqual(controller.availableInputs.first { $0.uid == secondary.uid }?.stability, .unstable)

        clock.advance(by: 0.001)
        await drainTasks()
        XCTAssertTrue(clock.requestedSleeps.contains(0.5))
        XCTAssertEqual(controller.availableInputs.first { $0.uid == secondary.uid }?.stability, .unstable)

        clock.advance(by: 0.499)
        await drainTasks()
        XCTAssertEqual(controller.availableInputs.first { $0.uid == secondary.uid }?.stability, .unstable)

        clock.advance(by: 0.001)
        await drainTasks()
        XCTAssertEqual(controller.availableInputs.first { $0.uid == secondary.uid }?.stability, .stable)
    }

    func testFailedSecondRecoveryProbeSchedulesAnotherQuietWindow() async {
        let clock = ManualAudioClock()
        let stub = StubAudioInputSystem(sample: configuredSample(defaultUID: primary.uid))
        let controller = makeController(stub: stub, clock: clock, observes: true)
        await flapSecondary(stub: stub, clock: clock)
        await flapSecondary(stub: stub, clock: clock)

        clock.advance(by: 15)
        await drainTasks()
        stub.failNextReads = 1
        clock.advance(by: 0.5)
        await drainTasks()

        XCTAssertEqual(controller.availableInputs.first { $0.uid == secondary.uid }?.stability, .unstable)
        XCTAssertGreaterThanOrEqual(clock.requestedSleeps.filter { $0 == 15 }.count, 2)
    }

    func testRunningCurrentInputBlocksWithoutCallingSetter() async {
        let stub = StubAudioInputSystem(sample: configuredSample(
            defaultUID: primary.uid,
            primaryRunning: true
        ))
        let controller = makeController(stub: stub)

        await assertSwitchError(.inputInUse) {
            try await controller.switchInput(
                route: self.routeToSecondary(),
                expectedTopologyGeneration: controller.topologyGeneration
            )
        }
        XCTAssertTrue(stub.setCalls.isEmpty)
    }

    func testUnknownCurrentActivityFailsClosedWithoutCallingSetter() async {
        let stub = StubAudioInputSystem(sample: configuredSample(
            defaultUID: primary.uid,
            primaryRunning: nil
        ))
        let controller = makeController(stub: stub)

        await assertSwitchError(.inputActivityUnknown) {
            try await controller.switchInput(
                route: self.routeToSecondary(),
                expectedTopologyGeneration: controller.topologyGeneration
            )
        }
        XCTAssertTrue(stub.setCalls.isEmpty)
    }

    func testTargetRunningDoesNotBlockAndSetterUsesFrozenObjectIDAndUID() async throws {
        let stub = StubAudioInputSystem(sample: configuredSample(
            defaultUID: primary.uid,
            secondaryRunning: true
        ))
        let events = EventRecorder()
        let controller = makeController(stub: stub, recorder: events)

        let result = try await controller.switchInput(
            route: routeToSecondary(),
            expectedTopologyGeneration: controller.topologyGeneration
        )

        XCTAssertEqual(result.target.uid, secondary.uid)
        XCTAssertEqual(stub.setCalls, [SetCall(objectID: 20, uid: secondary.uid)])
        XCTAssertEqual(events.values.filter { $0.kind == .setterIssued }.count, 1)
        XCTAssertEqual(events.values.filter { $0.kind == .switchSucceeded }.count, 1)
    }

    func testStaleTopologyGenerationRejectsWithoutCallingSetter() async {
        let stub = StubAudioInputSystem(sample: configuredSample(defaultUID: primary.uid))
        let controller = makeController(stub: stub)

        await assertSwitchError(.topologyChanged) {
            try await controller.switchInput(
                route: self.routeToSecondary(),
                expectedTopologyGeneration: controller.topologyGeneration &+ 1
            )
        }
        XCTAssertTrue(stub.setCalls.isEmpty)
    }

    func testOfflineTargetRejectsWithoutCallingSetter() async {
        let stub = StubAudioInputSystem(sample: AudioInputTopologySample(
            devices: [snapshot(id: 10, uid: primary.uid, name: "Primary", running: false)],
            defaultInputUID: primary.uid
        ))
        let controller = makeController(stub: stub)

        await assertSwitchError(.targetUnavailable(.secondary)) {
            try await controller.switchInput(
                route: self.routeToSecondary(),
                expectedTopologyGeneration: controller.topologyGeneration
            )
        }
        XCTAssertTrue(stub.setCalls.isEmpty)
    }

    func testPersistentlyUnstableTargetRejectsWithoutCallingSetter() async {
        let clock = ManualAudioClock()
        let stub = StubAudioInputSystem(sample: configuredSample(defaultUID: primary.uid))
        let controller = makeController(stub: stub, clock: clock, observes: true)
        await flapSecondary(stub: stub, clock: clock)
        await flapSecondary(stub: stub, clock: clock)

        await assertSwitchError(.targetUnstable(.secondary)) {
            try await controller.switchInput(
                route: self.routeToSecondary(),
                expectedTopologyGeneration: controller.topologyGeneration
            )
        }
        XCTAssertTrue(stub.setCalls.isEmpty)
    }

    func testPersistentlyUnstableCurrentSourceRejectsWithoutCallingSetter() async {
        let clock = ManualAudioClock()
        let stub = StubAudioInputSystem(sample: configuredSample(defaultUID: primary.uid))
        let events = EventRecorder()
        let controller = makeController(
            stub: stub,
            clock: clock,
            recorder: events,
            observes: true
        )
        await flapPrimary(stub: stub, clock: clock)
        await flapPrimary(stub: stub, clock: clock)
        XCTAssertEqual(
            controller.availableInputs.first { $0.uid == primary.uid }?.stability,
            .unstable
        )

        await assertSwitchError(.topologyChanged) {
            try await controller.switchInput(
                route: self.routeToSecondary(),
                expectedTopologyGeneration: controller.topologyGeneration
            )
        }
        XCTAssertTrue(stub.setCalls.isEmpty)
        XCTAssertEqual(events.values.filter { $0.kind == .setterIssued }.count, 0)
    }

    func testDuplicateCurrentUIDFailsActivityClosedAndDuplicateTargetIsUnstable() async {
        let duplicateCurrent = StubAudioInputSystem(sample: AudioInputTopologySample(
            devices: [
                snapshot(id: 10, uid: primary.uid, name: "A1", running: false),
                snapshot(id: 11, uid: primary.uid, name: "A2", running: false),
                snapshot(id: 20, uid: secondary.uid, name: "B"),
            ],
            defaultInputUID: primary.uid
        ))
        let currentController = makeController(stub: duplicateCurrent)
        await assertSwitchError(.inputActivityUnknown) {
            try await currentController.switchInput(
                route: self.routeToSecondary(),
                expectedTopologyGeneration: currentController.topologyGeneration
            )
        }
        XCTAssertTrue(duplicateCurrent.setCalls.isEmpty)

        let duplicateTarget = StubAudioInputSystem(sample: AudioInputTopologySample(
            devices: [
                snapshot(id: 10, uid: primary.uid, name: "A", running: false),
                snapshot(id: 20, uid: secondary.uid, name: "B1"),
                snapshot(id: 21, uid: secondary.uid, name: "B2"),
            ],
            defaultInputUID: primary.uid
        ))
        let targetController = makeController(stub: duplicateTarget)
        await assertSwitchError(.targetUnstable(.secondary)) {
            try await targetController.switchInput(
                route: self.routeToSecondary(),
                expectedTopologyGeneration: targetController.topologyGeneration
            )
        }
        XCTAssertTrue(duplicateTarget.setCalls.isEmpty)
    }

    func testSuccessRequiresFullFiveHundredMillisecondsOfStability() async throws {
        let clock = ManualAudioClock()
        let stub = StubAudioInputSystem(sample: configuredSample(defaultUID: primary.uid))
        let controller = makeController(
            stub: stub,
            clock: clock,
            policy: policy(successStability: 0.5)
        )

        let task = Task {
            try await controller.switchInput(
                route: self.routeToSecondary(),
                expectedTopologyGeneration: controller.topologyGeneration
            )
        }
        await waitUntil { stub.setCalls.count == 1 }
        await drainTasks()
        XCTAssertTrue(controller.isSwitching)

        clock.advance(by: 0.499)
        await drainTasks()
        XCTAssertTrue(controller.isSwitching)

        clock.advance(by: 0.001)
        let route = try await task.value
        XCTAssertEqual(route.target.uid, secondary.uid)
        XCTAssertFalse(controller.isSwitching)
        XCTAssertEqual(stub.setCalls.count, 1)
    }

    func testUnconfirmedSetUsesInjectedTwoSecondTimeoutAndNeverRetries() async {
        let clock = ManualAudioClock()
        let stub = StubAudioInputSystem(sample: configuredSample(defaultUID: primary.uid))
        stub.applySetToDefault = false
        let controller = makeController(stub: stub, clock: clock)

        let task = Task {
            try await controller.switchInput(
                route: self.routeToSecondary(),
                expectedTopologyGeneration: controller.topologyGeneration
            )
        }
        await waitUntil { stub.setCalls.count == 1 }
        await drainTasks()
        XCTAssertTrue(clock.requestedSleeps.contains(2))

        clock.advance(by: 1.999)
        await drainTasks()
        XCTAssertTrue(controller.isSwitching)
        clock.advance(by: 0.001)
        await drainTasks()

        do {
            _ = try await task.value
            XCTFail("Expected confirmation timeout")
        } catch let error as AudioInputDeviceControllerError {
            XCTAssertEqual(error, .confirmationTimedOut(.secondary))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(stub.setCalls.count, 1)
    }

    func testDeviceEventDuringSuccessWindowFailsWithoutRetryOrFallback() async {
        let clock = ManualAudioClock()
        let stub = StubAudioInputSystem(sample: configuredSample(defaultUID: primary.uid))
        let controller = makeController(
            stub: stub,
            clock: clock,
            policy: policy(successStability: 0.5),
            observes: true
        )

        let task = Task {
            try await controller.switchInput(
                route: self.routeToSecondary(),
                expectedTopologyGeneration: controller.topologyGeneration
            )
        }
        await waitUntil { stub.setCalls.count == 1 }
        stub.emit(.devicesChanged)
        await drainTasks()
        clock.advance(by: 0.5)
        await drainTasks()

        do {
            _ = try await task.value
            XCTFail("Expected topology drift")
        } catch let error as AudioInputDeviceControllerError {
            XCTAssertEqual(error, .topologyChanged)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(stub.setCalls.count, 1)
    }

    func testDefaultMovesToThirdInputDuringSuccessWindowFailsAfterOneSet() async {
        let clock = ManualAudioClock()
        let stub = StubAudioInputSystem(sample: configuredSampleWithThird(defaultUID: primary.uid))
        let controller = makeController(
            stub: stub,
            clock: clock,
            policy: policy(successStability: 0.5),
            observes: true
        )

        let task = Task {
            try await controller.switchInput(
                route: self.routeToSecondary(),
                expectedTopologyGeneration: controller.topologyGeneration
            )
        }
        await waitUntil { stub.setCalls.count == 1 }
        stub.setDefaultWithoutRecording("uid-c")
        stub.emit(.defaultInputChanged)
        await drainTasks()
        clock.advance(by: 0.2)
        await drainTasks()
        clock.advance(by: 0.3)
        await drainTasks()

        do {
            _ = try await task.value
            XCTFail("Expected topology drift")
        } catch let error as AudioInputDeviceControllerError {
            XCTAssertEqual(error, .topologyChanged)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(stub.setCalls.count, 1)
    }

    func testIdenticalRefreshAndRepeatedSameErrorDoNotRepublish() {
        let stub = StubAudioInputSystem(sample: configuredSample(defaultUID: primary.uid))
        let controller = makeController(stub: stub)
        let generation = controller.topologyGeneration
        let choices = controller.availableInputs
        var inputPublications = 0
        var errorPublications: [AudioInputDeviceControllerError?] = []
        var cancellables: Set<AnyCancellable> = []
        controller.$availableInputs.dropFirst().sink { _ in
            inputPublications += 1
        }.store(in: &cancellables)
        controller.$lastError.dropFirst().sink { value in
            errorPublications.append(value)
        }.store(in: &cancellables)

        controller.refresh()
        XCTAssertEqual(controller.topologyGeneration, generation)
        XCTAssertEqual(controller.availableInputs, choices)
        XCTAssertEqual(inputPublications, 0)

        stub.failNextReads = 2
        controller.refresh()
        controller.refresh()
        XCTAssertEqual(errorPublications, [.refreshFailed])
    }

    func testSetterFailureIsLoggedOnceAndNeverRetried() async {
        let stub = StubAudioInputSystem(sample: configuredSample(defaultUID: primary.uid))
        stub.setError = StubFailure.failed
        let events = EventRecorder()
        let controller = makeController(stub: stub, recorder: events)

        await assertSwitchError(.setFailed) {
            try await controller.switchInput(
                route: self.routeToSecondary(),
                expectedTopologyGeneration: controller.topologyGeneration
            )
        }
        XCTAssertEqual(stub.setCalls.count, 1)
        XCTAssertEqual(events.values.filter { $0.kind == .setterIssued }.count, 1)
        XCTAssertEqual(events.values.filter { $0.kind == .switchSucceeded }.count, 0)
    }

    private func flapSecondary(
        stub: StubAudioInputSystem,
        clock: ManualAudioClock
    ) async {
        stub.sample = AudioInputTopologySample(
            devices: [snapshot(id: 10, uid: primary.uid, name: "Primary", running: false)],
            defaultInputUID: primary.uid
        )
        stub.emit(.devicesChanged)
        await drainTasks()
        clock.advance(by: 0.2)
        await drainTasks()

        stub.sample = configuredSample(defaultUID: primary.uid)
        stub.emit(.devicesChanged)
        await drainTasks()
        clock.advance(by: 0.2)
        await drainTasks()
    }

    private func flapPrimary(
        stub: StubAudioInputSystem,
        clock: ManualAudioClock
    ) async {
        stub.sample = AudioInputTopologySample(
            devices: [snapshot(id: 20, uid: secondary.uid, name: "Secondary")],
            defaultInputUID: primary.uid
        )
        stub.emit(.devicesChanged)
        await drainTasks()
        clock.advance(by: 0.2)
        await drainTasks()

        stub.sample = configuredSample(defaultUID: primary.uid)
        stub.emit(.devicesChanged)
        await drainTasks()
        clock.advance(by: 0.2)
        await drainTasks()
    }

    private func routeToSecondary() -> AudioInputSwitchRoute {
        AudioInputSwitchRoute(
            fromUID: primary.uid,
            target: secondary,
            slot: .secondary
        )
    }

    private func configuredSample(
        defaultUID: String,
        primaryRunning: Bool? = false,
        secondaryRunning: Bool? = false
    ) -> AudioInputTopologySample {
        AudioInputTopologySample(
            devices: [
                snapshot(
                    id: 10,
                    uid: primary.uid,
                    name: primary.lastKnownName,
                    running: primaryRunning
                ),
                snapshot(
                    id: 20,
                    uid: secondary.uid,
                    name: secondary.lastKnownName,
                    running: secondaryRunning
                ),
            ],
            defaultInputUID: defaultUID
        )
    }

    private func sampleWithSecondaryObjectID(_ objectID: UInt32) -> AudioInputTopologySample {
        AudioInputTopologySample(
            devices: [
                snapshot(id: 10, uid: primary.uid, name: "Primary", running: false),
                snapshot(id: objectID, uid: secondary.uid, name: "Secondary"),
            ],
            defaultInputUID: primary.uid
        )
    }

    private func configuredSampleWithThird(defaultUID: String) -> AudioInputTopologySample {
        AudioInputTopologySample(
            devices: configuredSample(defaultUID: defaultUID).devices + [
                snapshot(id: 30, uid: "uid-c", name: "Third"),
            ],
            defaultInputUID: defaultUID
        )
    }

    private func snapshot(
        id: UInt32,
        uid: String,
        name: String,
        hasInput: Bool = true,
        isAlive: Bool = true,
        canBeDefault: Bool = true,
        isHidden: Bool = false,
        running: Bool? = false
    ) -> AudioInputDeviceSnapshot {
        AudioInputDeviceSnapshot(
            objectID: id,
            uid: uid,
            displayName: name,
            transportType: 0,
            hasInput: hasInput,
            isAlive: isAlive,
            canBeDefaultInput: canBeDefault,
            isHidden: isHidden,
            isRunningSomewhere: running
        )
    }

    private func policy(successStability: TimeInterval = 0) -> AudioInputStabilityPolicy {
        AudioInputStabilityPolicy(
            eventCoalesce: 0.2,
            reconnectWindow: 2,
            flapWindow: 20,
            recoveryQuiet: 15,
            recoveryProbeGap: 0.5,
            confirmationTimeout: 2,
            successStability: successStability
        )
    }

    private func makeController(
        stub: StubAudioInputSystem,
        clock: ManualAudioClock? = nil,
        policy: AudioInputStabilityPolicy? = nil,
        recorder: EventRecorder? = nil,
        observes: Bool = false
    ) -> AudioInputDeviceController {
        AudioInputDeviceController(
            client: stub.client,
            policy: policy ?? self.policy(),
            clock: clock?.controllerClock ?? AudioInputControllerClock(
                now: { 0 },
                sleep: { _ in }
            ),
            logger: AudioInputDiagnosticLogger { event in recorder?.values.append(event) },
            automaticallyObserves: observes
        )
    }

    private func assertSwitchError(
        _ expected: AudioInputDeviceControllerError,
        operation: () async throws -> AudioInputSwitchRoute
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as AudioInputDeviceControllerError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func drainTasks(iterations: Int = 12) async {
        for _ in 0..<iterations { await Task.yield() }
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool,
        iterations: Int = 200
    ) async {
        for _ in 0..<iterations where !condition() { await Task.yield() }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class ManualAudioClock {
    private struct Sleeper {
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var now: TimeInterval = 0
    private(set) var requestedSleeps: [TimeInterval] = []
    private var sleepers: [UUID: Sleeper] = [:]

    var controllerClock: AudioInputControllerClock {
        AudioInputControllerClock(
            now: { self.now },
            sleep: { seconds in await self.sleep(seconds) }
        )
    }

    func advance(by interval: TimeInterval) {
        now += interval
        let ready = sleepers.filter { $0.value.deadline <= now }
        for (id, sleeper) in ready {
            sleepers[id] = nil
            sleeper.continuation.resume()
        }
    }

    private func sleep(_ interval: TimeInterval) async {
        requestedSleeps.append(interval)
        guard interval > 0 else { return }
        let id = UUID()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    sleepers[id] = Sleeper(
                        deadline: now + interval,
                        continuation: continuation
                    )
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        })
    }

    private func cancel(id: UUID) {
        guard let sleeper = sleepers.removeValue(forKey: id) else { return }
        sleeper.continuation.resume()
    }
}

@MainActor
private final class StubAudioInputSystem {
    var sample: AudioInputTopologySample
    var failNextReads = 0
    var setError: Error?
    var applySetToDefault = true
    private(set) var readCount = 0
    private(set) var setCalls: [SetCall] = []
    private var observer: ((AudioInputSystemEvent) -> Void)?

    init(sample: AudioInputTopologySample) {
        self.sample = sample
    }

    var client: AudioInputDeviceClient {
        AudioInputDeviceClient(
            readTopology: {
                self.readCount += 1
                if self.failNextReads > 0 {
                    self.failNextReads -= 1
                    throw StubFailure.failed
                }
                return self.sample
            },
            setDefaultInput: { objectID, uid in
                self.setCalls.append(SetCall(objectID: objectID, uid: uid))
                if let setError = self.setError { throw setError }
                guard self.sample.devices.contains(where: {
                    $0.objectID == objectID && $0.uid == uid
                }) else { throw StubFailure.failed }
                if self.applySetToDefault { self.setDefaultWithoutRecording(uid) }
            },
            observeChanges: { handler in
                self.observer = handler
                return AudioInputObservation { [weak self] in self?.observer = nil }
            }
        )
    }

    func setDefaultWithoutRecording(_ uid: String?) {
        sample = AudioInputTopologySample(
            devices: sample.devices,
            defaultInputUID: uid
        )
    }

    func emit(_ event: AudioInputSystemEvent) {
        observer?(event)
    }
}

private struct SetCall: Equatable {
    let objectID: UInt32
    let uid: String
}

@MainActor
private final class EventRecorder {
    var values: [AudioInputDiagnosticEvent] = []
}

private enum StubFailure: Error {
    case failed
}
