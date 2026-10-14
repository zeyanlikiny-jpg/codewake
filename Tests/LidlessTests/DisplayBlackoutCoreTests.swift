import CoreGraphics
import Darwin
import Foundation
import XCTest

final class DisplayBlackoutCoreTests: XCTestCase {
    private let builtin: CGDirectDisplayID = 101
    private let external: CGDirectDisplayID = 202

    // MARK: - Wire protocol

    func testProtocolUsesExactVersionBuildAndRejectsInvalidIdentity() {
        let valid = DisplayBlackoutRequest(
            token: "token_123",
            generation: 1,
            action: .arm
        )
        XCTAssertNil(valid.validationFailure)
        XCTAssertEqual(valid.protocolVersion, 1)
        XCTAssertEqual(valid.versionAdvertisement, "0.2.18+23;protocol=1")

        XCTAssertEqual(
            DisplayBlackoutRequest(
                token: "token_123",
                generation: 1,
                action: .arm,
                protocolVersion: 2
            ).validationFailure,
            .protocolMismatch
        )
        XCTAssertEqual(
            DisplayBlackoutRequest(
                token: "contains space",
                generation: 1,
                action: .arm
            ).validationFailure,
            .invalidIdentity
        )
        XCTAssertEqual(
            DisplayBlackoutRequest(
                token: "token",
                generation: 0,
                action: .arm
            ).validationFailure,
            .invalidIdentity
        )
    }

    func testLengthPrefixedRequestRoundTrips() throws {
        let request = DisplayBlackoutRequest(
            token: "token",
            generation: 42,
            action: .restore
        )
        let frame = try DisplayBlackoutFrameCodec.encode(request)

        let advertisedLength = frame.prefix(4).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        XCTAssertEqual(Int(advertisedLength), frame.count - 4)
        XCTAssertEqual(
            try DisplayBlackoutFrameCodec.decode(DisplayBlackoutRequest.self, from: frame),
            request
        )
    }

    func testFrameCodecRejectsOversizedIncompleteAndTrailingFrames() throws {
        let oversized = DisplayBlackoutResponse(
            token: "token",
            generation: 1,
            status: .failed,
            failureCode: String(repeating: "x", count: 5_000)
        )
        XCTAssertThrowsError(try DisplayBlackoutFrameCodec.encode(oversized)) {
            guard case DisplayBlackoutFrameError.payloadTooLarge = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }

        let request = DisplayBlackoutRequest(token: "token", generation: 1, action: .status)
        let frame = try DisplayBlackoutFrameCodec.encode(request)
        XCTAssertThrowsError(
            try DisplayBlackoutFrameCodec.decode(
                DisplayBlackoutRequest.self,
                from: frame.dropLast()
            )
        )
        XCTAssertThrowsError(
            try DisplayBlackoutFrameCodec.decode(
                DisplayBlackoutRequest.self,
                from: frame + Data([0])
            )
        )
    }

    func testIncrementalFrameDecoderWaitsForCompleteSingleFrame() throws {
        let request = DisplayBlackoutRequest(token: "token", generation: 3, action: .restore)
        let frame = try DisplayBlackoutFrameCodec.encode(request)
        var decoder = DisplayBlackoutFrameStreamDecoder()

        XCTAssertEqual(try decoder.append(frame.prefix(2)), [])
        XCTAssertEqual(try decoder.append(frame.dropFirst(2).prefix(5)), [])
        let completed = try decoder.append(frame.dropFirst(7))

        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(
            try DisplayBlackoutFrameCodec.decode(
                DisplayBlackoutRequest.self,
                from: try XCTUnwrap(completed.first)
            ),
            request
        )
        XCTAssertNoThrow(try decoder.finish())
    }

    // MARK: - Topology and strict display selection

    func testOnlyOneBuiltinDisplayIsReady() {
        let fake = FakeDisplaySystem(
            online: [builtin],
            builtin: [builtin],
            brightness: [builtin: 0.7]
        )

        XCTAssertEqual(
            BuiltInDisplayBrightnessController(api: fake.api()).blackoutCapability(),
            .ready(displayID: builtin)
        )
        XCTAssertEqual(fake.canChangeCalls, [builtin])
    }

    func testAnyExternalEndpointBlocksBlackoutWithoutBrightnessCalls() {
        let fake = FakeDisplaySystem(
            online: [builtin, external],
            builtin: [builtin],
            brightness: [builtin: 0.7, external: 0.5]
        )
        let controller = BuiltInDisplayBrightnessController(api: fake.api())

        XCTAssertEqual(
            controller.blackoutCapability(),
            .externalDisplayConnected(count: 1)
        )
        XCTAssertEqual(controller.externalDisplayState(), .connected(count: 1))
        XCTAssertTrue(fake.canChangeCalls.isEmpty)
        XCTAssertTrue(fake.getCalls.isEmpty)
        XCTAssertTrue(fake.setCalls.isEmpty)
    }

    func testExternalOnlyTopologyBlocksAsExternalAndNeverBecomesFallback() throws {
        let paths = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fake = FakeDisplaySystem(
            online: [external],
            builtin: [],
            brightness: [external: 0.5]
        )
        let result = try BuiltInDisplayBrightnessController(api: fake.api()).arm(
            token: "token",
            generation: 1,
            journalStore: paths.store
        )

        XCTAssertEqual(result, .blocked(.externalDisplayConnected(count: 1)))
        XCTAssertTrue(fake.getCalls.isEmpty)
        XCTAssertTrue(fake.setCalls.isEmpty)
    }

    func testEmptyAndFailedTopologyAreUnknown() {
        let empty = FakeDisplaySystem(online: [], builtin: [], brightness: [:])
        XCTAssertEqual(
            BuiltInDisplayBrightnessController(api: empty.api()).blackoutCapability(),
            .topologyUnknown
        )

        let failed = FakeDisplaySystem(
            online: [builtin],
            builtin: [builtin],
            brightness: [builtin: 0.5]
        )
        failed.onlineError = .unavailable
        XCTAssertEqual(
            BuiltInDisplayBrightnessController(api: failed.api()).blackoutCapability(),
            .topologyUnknown
        )
    }

    func testDuplicateBuiltinIsDeduplicatedButMultipleBuiltinsFailClosed() {
        let duplicate = FakeDisplaySystem(
            online: [builtin, builtin],
            builtin: [builtin],
            brightness: [builtin: 0.5]
        )
        XCTAssertEqual(
            BuiltInDisplayBrightnessController(api: duplicate.api()).blackoutCapability(),
            .ready(displayID: builtin)
        )

        let secondBuiltin: CGDirectDisplayID = 303
        let multiple = FakeDisplaySystem(
            online: [builtin, secondBuiltin],
            builtin: [builtin, secondBuiltin],
            brightness: [builtin: 0.5, secondBuiltin: 0.5]
        )
        XCTAssertEqual(
            BuiltInDisplayBrightnessController(api: multiple.api()).blackoutCapability(),
            .builtInUnavailable
        )
    }

    // MARK: - Journal and brightness transaction

    func testArmPersistsPreparedJournalBeforeWritingZeroThenArms() throws {
        let paths = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fake = FakeDisplaySystem(
            online: [builtin],
            builtin: [builtin],
            brightness: [builtin: 0.72]
        )
        var observedPrepared = false
        fake.onSet = { displayID, brightness in
            guard displayID == self.builtin, brightness == 0 else { return }
            observedPrepared = (try? paths.store.load()?.phase) == .prepared
        }

        let result = try BuiltInDisplayBrightnessController(api: fake.api()).arm(
            token: "token",
            generation: 7,
            journalStore: paths.store,
            now: 100
        )

        guard case .armed(let journal) = result else {
            return XCTFail("Expected armed, got \(result)")
        }
        XCTAssertTrue(observedPrepared)
        XCTAssertEqual(fake.setCalls, [BrightnessCall(displayID: builtin, value: 0)])
        XCTAssertEqual(journal.phase, .armed)
        XCTAssertEqual(journal.originalBrightness, 0.72)
        XCTAssertEqual(try paths.store.load()?.phase, .armed)
    }

    func testSecondTopologyProbeCatchesHotPlugBeforeZeroWrite() throws {
        let paths = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fake = FakeDisplaySystem(
            online: [builtin],
            builtin: [builtin],
            brightness: [builtin: 0.6, external: 0.5]
        )
        fake.onlineSequence = [[builtin], [builtin, external]]

        let result = try BuiltInDisplayBrightnessController(api: fake.api()).arm(
            token: "token",
            generation: 1,
            journalStore: paths.store
        )

        XCTAssertEqual(result, .blocked(.externalDisplayConnected(count: 1)))
        XCTAssertTrue(fake.setCalls.isEmpty)
        XCTAssertNil(try paths.store.load())
    }

    func testFailedBlackoutVerificationRestoresOriginalBrightness() throws {
        let paths = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fake = FakeDisplaySystem(
            online: [builtin],
            builtin: [builtin],
            brightness: [builtin: 0.64]
        )
        fake.ignoreZeroWrites = true

        XCTAssertThrowsError(
            try BuiltInDisplayBrightnessController(api: fake.api()).arm(
                token: "token",
                generation: 1,
                journalStore: paths.store
            )
        )
        // Because the zero write never took effect, compare-before-restore sees
        // 0.64 and preserves it without a second write.
        XCTAssertEqual(fake.setCalls, [BrightnessCall(displayID: builtin, value: 0)])
        XCTAssertEqual(fake.brightness(for: builtin), 0.64)
        XCTAssertNil(try paths.store.load())
    }

    func testRestoreWritesOnlyBuiltinWhenExternalIsNowConnected() throws {
        let paths = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.store.save(journal(originalBrightness: 0.81, phase: .armed))
        let fake = FakeDisplaySystem(
            online: [builtin, external],
            builtin: [builtin],
            brightness: [builtin: 0, external: 0.37]
        )

        let result = try BuiltInDisplayBrightnessController(api: fake.api()).restoreIfNeeded(
            journalStore: paths.store
        )

        XCTAssertEqual(result, .restored)
        XCTAssertEqual(fake.setCalls, [BrightnessCall(displayID: builtin, value: 0.81)])
        XCTAssertEqual(fake.brightness(for: external), 0.37)
        XCTAssertFalse(fake.setCalls.contains { $0.displayID == external })
        XCTAssertNil(try paths.store.load())
    }

    func testRestoreDoesNotOverwriteBrightnessKeyEscapeHatch() throws {
        let paths = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.store.save(journal(originalBrightness: 0.8, phase: .armed))
        let fake = FakeDisplaySystem(
            online: [builtin],
            builtin: [builtin],
            brightness: [builtin: 0.23]
        )

        let result = try BuiltInDisplayBrightnessController(api: fake.api()).restoreIfNeeded(
            journalStore: paths.store
        )

        XCTAssertEqual(result, .userAlreadyRestored)
        XCTAssertTrue(fake.setCalls.isEmpty)
        XCTAssertEqual(fake.brightness(for: builtin), 0.23)
        XCTAssertNil(try paths.store.load())
    }

    func testOfflineBuiltinKeepsRestoringJournalForRetry() throws {
        let paths = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.store.save(journal(originalBrightness: 0.8, phase: .armed))
        let fake = FakeDisplaySystem(
            online: [external],
            builtin: [builtin],
            brightness: [external: 0.4]
        )

        let result = try BuiltInDisplayBrightnessController(api: fake.api()).restoreIfNeeded(
            journalStore: paths.store
        )

        guard case .pending(.builtInUnavailable, let pendingJournal) = result else {
            return XCTFail("Expected pending built-in recovery, got \(result)")
        }
        XCTAssertEqual(pendingJournal.phase, .restoring)
        XCTAssertEqual(try paths.store.load()?.phase, .restoring)
        XCTAssertTrue(fake.setCalls.isEmpty)
    }

    func testRestoreRejectsStaleTokenWithoutBrightnessAccess() throws {
        let paths = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.store.save(journal(token: "current", generation: 9))
        let fake = FakeDisplaySystem(
            online: [builtin],
            builtin: [builtin],
            brightness: [builtin: 0]
        )

        XCTAssertThrowsError(
            try BuiltInDisplayBrightnessController(api: fake.api()).restoreIfNeeded(
                journalStore: paths.store,
                matchingToken: "old",
                generation: 8
            )
        ) {
            XCTAssertEqual($0 as? DisplayBlackoutControllerError, .staleGeneration)
        }
        XCTAssertTrue(fake.getCalls.isEmpty)
        XCTAssertTrue(fake.setCalls.isEmpty)
        XCTAssertEqual(try paths.store.load()?.phase, .armed)
    }

    func testJournalUsesPrivateModesAndRejectsSymlinkOrBroadFile() throws {
        let paths = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.store.save(journal())

        XCTAssertEqual(try mode(at: paths.store.fileURL.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try mode(at: paths.store.fileURL), 0o600)

        XCTAssertEqual(Darwin.chmod(paths.store.fileURL.path, mode_t(0o644)), 0)
        XCTAssertThrowsError(try paths.store.load()) {
            XCTAssertEqual($0 as? DisplayBlackoutJournalStoreError, .unsafeFile)
        }

        XCTAssertEqual(Darwin.unlink(paths.store.fileURL.path), 0)
        let target = paths.root.appendingPathComponent("target")
        try Data("untouched".utf8).write(to: target)
        XCTAssertEqual(Darwin.chmod(target.path, mode_t(0o600)), 0)
        try FileManager.default.createSymbolicLink(
            at: paths.store.fileURL,
            withDestinationURL: target
        )
        XCTAssertThrowsError(try paths.store.save(journal())) {
            XCTAssertEqual($0 as? DisplayBlackoutJournalStoreError, .unsafeFile)
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("untouched".utf8))
    }

    func testJournalRejectsMalformedAndOversizedInputWithoutDeletingIt() throws {
        let paths = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let directory = paths.store.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(Darwin.chmod(directory.path, mode_t(0o700)), 0)
        try Data("{bad-json".utf8).write(to: paths.store.fileURL)
        XCTAssertEqual(Darwin.chmod(paths.store.fileURL.path, mode_t(0o600)), 0)
        XCTAssertThrowsError(try paths.store.load()) {
            XCTAssertEqual($0 as? DisplayBlackoutJournalStoreError, .invalidJournal)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.store.fileURL.path))

        try Data(repeating: 1, count: 4_097).write(to: paths.store.fileURL)
        XCTAssertEqual(Darwin.chmod(paths.store.fileURL.path, mode_t(0o600)), 0)
        XCTAssertThrowsError(try paths.store.load()) {
            XCTAssertEqual($0 as? DisplayBlackoutJournalStoreError, .oversized)
        }
    }

    // MARK: - HID baseline and watchdog lifecycle

    func testHIDBaselineIgnoresInitiatingEventJitterButDetectsNewerInput() throws {
        let baseline = try XCTUnwrap(DisplayBlackoutHIDBaseline(
            systemUptime: 100,
            idleSeconds: 0.010
        ))

        XCTAssertFalse(baseline.hasNewerInput(systemUptime: 100.015, idleSeconds: 0.010))
        XCTAssertFalse(baseline.hasNewerInput(systemUptime: 120, idleSeconds: 20.010))
        XCTAssertTrue(baseline.hasNewerInput(systemUptime: 120, idleSeconds: 0.001))
    }

    func testHIDInputGateSuppressesReleaseMovementDragAndScrollThroughDeadline() throws {
        let suppressibleEventTypes: [CGEventType] = [
            .leftMouseUp,
            .rightMouseUp,
            .otherMouseUp,
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel,
            .keyUp,
            .flagsChanged,
            .tabletPointer,
            .tabletProximity,
        ]

        for eventType in suppressibleEventTypes {
            for offset in [0.0, 1.49, 1.50] {
                let rawEventType = eventType.rawValue
                var gate = try XCTUnwrap(DisplayBlackoutHIDInputGate(
                    armedAtUptime: 100,
                    baseline: hidSnapshot(
                        sampledAt: 99.9,
                        lastInputAt: 99.8,
                        counters: [rawEventType: 10]
                    )
                ))

                XCTAssertEqual(
                    gate.observe(try hidSnapshot(
                        sampledAt: 100 + offset,
                        lastInputAt: 100 + offset,
                        counters: [rawEventType: 11]
                    )),
                    .suppressedDuringGrace,
                    "Expected event type \(rawEventType) at +\(offset)s to be consumed"
                )
            }
        }
    }

    func testHIDInputGateRestoresImmediatelyForNewMouseDownOrKeyDown() throws {
        let immediateEventTypes: [CGEventType] = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .keyDown,
        ]

        for eventType in immediateEventTypes {
            for offset in [0.0, 1.49] {
                let rawEventType = eventType.rawValue
                var gate = try XCTUnwrap(DisplayBlackoutHIDInputGate(
                    armedAtUptime: 100,
                    baseline: hidSnapshot(
                        sampledAt: 99.9,
                        lastInputAt: 99.8,
                        counters: [rawEventType: 20]
                    )
                ))

                XCTAssertEqual(
                    gate.observe(try hidSnapshot(
                        sampledAt: 100 + offset,
                        lastInputAt: 100 + offset,
                        counters: [rawEventType: 21]
                    )),
                    .restore,
                    "Expected event type \(rawEventType) at +\(offset)s to restore"
                )
            }
        }
    }

    func testHIDInputGateRestoresForFirstNewInputAfterDeadline() throws {
        let postGraceEventTypes: [CGEventType] = [
            .mouseMoved,
            .leftMouseDragged,
            .scrollWheel,
            .leftMouseUp,
            .keyUp,
            .tabletPointer,
        ]

        for eventType in postGraceEventTypes {
            let rawEventType = eventType.rawValue
            var gate = try XCTUnwrap(DisplayBlackoutHIDInputGate(
                armedAtUptime: 100,
                baseline: hidSnapshot(
                    sampledAt: 99.9,
                    lastInputAt: 99.8,
                    counters: [rawEventType: 30]
                )
            ))

            XCTAssertEqual(
                gate.observe(try hidSnapshot(
                    sampledAt: 101.500_001,
                    lastInputAt: 101.500_001,
                    counters: [rawEventType: 31]
                )),
                .restore,
                "Expected event type \(rawEventType) after grace to restore"
            )
        }
    }

    func testHIDInputGateConsumesOldGraceEventWithoutReplayingItAfterDeadline() throws {
        let rawEventType = CGEventType.mouseMoved.rawValue
        var gate = try XCTUnwrap(DisplayBlackoutHIDInputGate(
            armedAtUptime: 100,
            baseline: hidSnapshot(
                sampledAt: 99.9,
                lastInputAt: 99.8,
                counters: [rawEventType: 40]
            )
        ))

        // The watchdog may not sample until after the deadline, so the event's
        // own uptime -- not the observation time -- decides whether it is old.
        XCTAssertEqual(
            gate.observe(try hidSnapshot(
                sampledAt: 101.6,
                lastInputAt: 101.49,
                counters: [rawEventType: 41]
            )),
            .suppressedDuringGrace
        )
        XCTAssertEqual(
            gate.observe(try hidSnapshot(
                sampledAt: 101.8,
                lastInputAt: 101.49,
                counters: [rawEventType: 41]
            )),
            .noNewInput
        )
        XCTAssertEqual(
            gate.observe(try hidSnapshot(
                sampledAt: 101.81,
                lastInputAt: 101.81,
                counters: [rawEventType: 42]
            )),
            .restore
        )
    }

    func testWatchdogHIDInputEmitsArmedThenUnsolicitedRestored() throws {
        let fixture = try WatchdogFixture(
            builtin: builtin,
            external: external,
            initialBrightness: 0.75
        )
        defer { fixture.cleanUp() }

        fixture.start()
        try fixture.send(.init(token: "token", generation: 1, action: .arm))
        XCTAssertEqual(try fixture.receive().status, .armed)
        XCTAssertEqual(fixture.fake.brightness(for: builtin), 0)

        // A fresh click remains an immediate escape hatch during the grace
        // window; no sleep is needed to cross the 1.5 second deadline.
        fixture.hidClock.signalInput(.leftMouseDown)
        let restored = try fixture.receive()

        XCTAssertEqual(restored.status, .restored)
        XCTAssertEqual(restored.trigger, .hidInput)
        XCTAssertEqual(fixture.fake.brightness(for: builtin), 0.75)
        fixture.waitForExit(expected: 0)
    }

    func testWatchdogConsumesGraceMovementButKeyDownStillRestores() throws {
        let fixture = try WatchdogFixture(
            builtin: builtin,
            external: external,
            initialBrightness: 0.74
        )
        defer { fixture.cleanUp() }

        fixture.start()
        try fixture.send(.init(token: "token", generation: 11, action: .arm))
        XCTAssertEqual(try fixture.receive().status, .armed)

        fixture.hidClock.signalInput(.mouseMoved)
        XCTAssertThrowsError(try fixture.receive(timeout: 0.15))
        XCTAssertEqual(fixture.fake.brightness(for: builtin), 0)

        fixture.hidClock.signalInput(.keyDown)
        let restored = try fixture.receive()
        XCTAssertEqual(restored.status, .restored)
        XCTAssertEqual(restored.trigger, .hidInput)
        XCTAssertEqual(fixture.fake.brightness(for: builtin), 0.74)
        fixture.waitForExit(expected: 0)
    }

    func testWatchdogParentPipeEOFRestoresBeforeExit() throws {
        let fixture = try WatchdogFixture(
            builtin: builtin,
            external: external,
            initialBrightness: 0.68
        )
        defer { fixture.cleanUp() }

        fixture.start()
        try fixture.send(.init(token: "token", generation: 2, action: .arm))
        XCTAssertEqual(try fixture.receive().status, .armed)
        try fixture.closeControlWriter()

        let restored = try fixture.receive()
        XCTAssertEqual(restored.status, .restored)
        XCTAssertEqual(restored.trigger, .parentPipeClosed)
        XCTAssertEqual(fixture.fake.brightness(for: builtin), 0.68)
        fixture.waitForExit(expected: 0)
    }

    func testWatchdogExternalHotPlugRestoresBuiltinAndNeverTouchesExternal() throws {
        let fixture = try WatchdogFixture(
            builtin: builtin,
            external: external,
            initialBrightness: 0.77
        )
        defer { fixture.cleanUp() }

        fixture.start()
        try fixture.send(.init(token: "token", generation: 3, action: .arm))
        XCTAssertEqual(try fixture.receive().status, .armed)
        fixture.fake.setOnline([builtin, external])

        let restored = try fixture.receive()
        XCTAssertEqual(restored.status, .restored)
        XCTAssertEqual(restored.trigger, .externalDisplayConnected)
        XCTAssertEqual(fixture.fake.brightness(for: builtin), 0.77)
        XCTAssertFalse(fixture.fake.setCalls.contains { $0.displayID == external })
        fixture.waitForExit(expected: 0)
    }

    func testWatchdogRejectsStaleRestoreAndKeepsCurrentGenerationArmed() throws {
        let fixture = try WatchdogFixture(
            builtin: builtin,
            external: external,
            initialBrightness: 0.66
        )
        defer { fixture.cleanUp() }

        fixture.start()
        try fixture.send(.init(token: "current", generation: 4, action: .arm))
        XCTAssertEqual(try fixture.receive().status, .armed)

        try fixture.send(.init(token: "old", generation: 3, action: .restore))
        XCTAssertEqual(try fixture.receive().status, .staleGeneration)
        XCTAssertEqual(fixture.fake.brightness(for: builtin), 0)

        try fixture.send(.init(token: "current", generation: 4, action: .restore))
        let restored = try fixture.receive()
        XCTAssertEqual(restored.status, .restored)
        XCTAssertEqual(restored.trigger, .requested)
        XCTAssertEqual(fixture.fake.brightness(for: builtin), 0.66)
        fixture.waitForExit(expected: 0)
    }

    func testStartupRecoveryIsOneShotAndReportsNoJournal() throws {
        let fixture = try WatchdogFixture(
            builtin: builtin,
            external: external,
            initialBrightness: 0.5
        )
        defer { fixture.cleanUp() }

        fixture.start()
        try fixture.send(.init(token: "startup", generation: 1, action: .recover))
        let response = try fixture.receive()

        XCTAssertEqual(response.status, .noRecoveryNeeded)
        XCTAssertEqual(response.trigger, .startupRecovery)
        fixture.waitForExit(expected: 0)
    }

    func testStartupRecoveryStaysAliveUntilBuiltinReturnsWithExternalStillOnline() throws {
        let fixture = try WatchdogFixture(
            builtin: builtin,
            external: external,
            initialBrightness: 0
        )
        defer { fixture.cleanUp() }
        try fixture.saveJournal(journal(
            token: "prior",
            generation: 9,
            originalBrightness: 0.73
        ))
        fixture.fake.setOnline([external])

        fixture.start()
        try fixture.send(.init(token: "startup", generation: 10, action: .recover))
        let pending = try fixture.receive()
        XCTAssertEqual(pending.status, .builtInUnavailable)
        XCTAssertTrue(pending.recoveryPending)

        // Parent control EOF must not abandon the durable recovery obligation.
        // The external endpoint remains online throughout the built-in reconnect.
        try fixture.closeControlWriter()
        fixture.fake.setOnline([builtin, external])
        let restored = try fixture.receive()

        XCTAssertEqual(restored.status, .restored)
        XCTAssertEqual(restored.trigger, .startupRecovery)
        XCTAssertEqual(fixture.fake.brightness(for: builtin), 0.73)
        XCTAssertFalse(fixture.fake.setCalls.contains { $0.displayID == external })
        fixture.waitForExit(expected: 0)
    }

    func testStartupRecoveryReportsChangedPendingReasonWithoutRepeatingAndRestoresOnlyBuiltin() throws {
        let fixture = try WatchdogFixture(
            builtin: builtin,
            external: external,
            initialBrightness: 0
        )
        defer { fixture.cleanUp() }
        try fixture.saveJournal(journal(
            token: "prior",
            generation: 9,
            originalBrightness: 0.73
        ))
        fixture.fake.setOnline([external])

        fixture.start()
        try fixture.send(.init(token: "startup", generation: 10, action: .recover))
        let offline = try fixture.receive()
        XCTAssertEqual(offline.status, .builtInUnavailable)
        XCTAssertTrue(offline.recoveryPending)
        fixture.assertNoResponse()

        fixture.fake.setBrightnessFailures(for: builtin, reading: true)
        fixture.fake.setOnline([builtin, external])
        let brightnessFailure = try fixture.receive()
        XCTAssertEqual(brightnessFailure.status, .brightnessUnavailable)
        XCTAssertTrue(brightnessFailure.recoveryPending)
        XCTAssertEqual(brightnessFailure.token, "startup")
        XCTAssertEqual(brightnessFailure.generation, 10)
        XCTAssertEqual(brightnessFailure.trigger, .startupRecovery)
        XCTAssertEqual(try fixture.loadJournal()?.phase, .restoring)
        XCTAssertTrue(fixture.fake.setCalls.isEmpty)
        fixture.assertNoResponse()

        fixture.fake.setBrightnessFailures(for: builtin)
        let restored = try fixture.receive()
        XCTAssertEqual(restored.status, .restored)
        XCTAssertFalse(restored.recoveryPending)
        XCTAssertEqual(restored.trigger, .startupRecovery)
        XCTAssertEqual(fixture.fake.setCalls, [BrightnessCall(displayID: builtin, value: 0.73)])
        XCTAssertEqual(fixture.fake.brightness(for: external), 0.4)
        XCTAssertNil(try fixture.loadJournal())
        fixture.waitForExit(expected: 0)
    }

    func testArmedRecoveryReportsWriteFailureAndPreservesUserBrightnessAfterOfflinePending() throws {
        let fixture = try WatchdogFixture(
            builtin: builtin,
            external: external,
            initialBrightness: 0.76
        )
        defer { fixture.cleanUp() }

        fixture.start()
        try fixture.send(.init(token: "current", generation: 4, action: .arm))
        XCTAssertEqual(try fixture.receive().status, .armed)
        fixture.fake.setOnline([external])
        let offline = try fixture.receive()
        XCTAssertEqual(offline.status, .builtInUnavailable)
        XCTAssertTrue(offline.recoveryPending)
        XCTAssertEqual(offline.trigger, .externalDisplayConnected)
        fixture.assertNoResponse()

        fixture.fake.setBrightnessFailures(for: builtin, writing: true)
        fixture.fake.setOnline([builtin, external])
        let brightnessFailure = try fixture.receive()
        XCTAssertEqual(brightnessFailure.status, .brightnessUnavailable)
        XCTAssertTrue(brightnessFailure.recoveryPending)
        XCTAssertEqual(brightnessFailure.token, "current")
        XCTAssertEqual(brightnessFailure.generation, 4)
        XCTAssertEqual(brightnessFailure.trigger, .externalDisplayConnected)
        XCTAssertEqual(try fixture.loadJournal()?.phase, .restoring)
        XCTAssertEqual(fixture.fake.brightness(for: builtin), 0)
        fixture.assertNoResponse()

        // The user's brightness key still works as an escape hatch even while
        // the app's set-brightness API is failing. Do not overwrite that value.
        fixture.fake.setUserBrightness(0.29, for: builtin)
        let restored = try fixture.receive()
        XCTAssertEqual(restored.status, .restored)
        XCTAssertFalse(restored.recoveryPending)
        XCTAssertEqual(restored.trigger, .externalDisplayConnected)
        XCTAssertEqual(fixture.fake.brightness(for: builtin), 0.29)
        XCTAssertEqual(fixture.fake.brightness(for: external), 0.4)
        XCTAssertTrue(fixture.fake.setCalls.contains(BrightnessCall(displayID: builtin, value: 0.76)))
        XCTAssertTrue(fixture.fake.setCalls.allSatisfy { $0.displayID == builtin })
        XCTAssertNil(try fixture.loadJournal())
        fixture.waitForExit(expected: 0)
    }

    // MARK: - Helpers

    private func journal(
        token: String = "token",
        generation: UInt64 = 1,
        originalBrightness: Float = 0.7,
        phase: DisplayBlackoutJournalPhase = .armed
    ) -> DisplayBlackoutJournal {
        DisplayBlackoutJournal(
            token: token,
            generation: generation,
            displayID: builtin,
            originalBrightness: originalBrightness,
            phase: phase,
            createdAt: 100,
            updatedAt: 100
        )
    }

    private func temporaryStore() throws -> (
        root: URL,
        store: DisplayBlackoutJournalStore
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DisplayBlackoutTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("display-blackout-recovery.json")
        return (root, DisplayBlackoutJournalStore(fileURL: file))
    }

    private func hidSnapshot(
        sampledAt: TimeInterval,
        lastInputAt: TimeInterval,
        counters: [UInt32: UInt32]
    ) throws -> DisplayBlackoutHIDSnapshot {
        try XCTUnwrap(DisplayBlackoutHIDSnapshot(
            systemUptime: sampledAt,
            idleSeconds: max(0, sampledAt - lastInputAt),
            eventCounters: counters
        ))
    }

    private func mode(at url: URL) throws -> mode_t {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
        return info.st_mode & 0o777
    }
}

private struct BrightnessCall: Equatable {
    let displayID: CGDirectDisplayID
    let value: Float
}

private enum FakeFailure: Error {
    case unavailable
}

/// Every controller/watchdog test uses this injected fake. Nothing in this test
/// file constructs `DisplayBrightnessAPI.system()`, so no real panel is changed.
private final class FakeDisplaySystem {
    private let lock = NSLock()
    private var online: [CGDirectDisplayID]
    private var builtin: Set<CGDirectDisplayID>
    private var brightnessValues: [CGDirectDisplayID: Float]
    private var recordedCanChangeCalls: [CGDirectDisplayID] = []
    private var recordedGetCalls: [CGDirectDisplayID] = []
    private var recordedSetCalls: [BrightnessCall] = []
    private var brightnessReadFailures: Set<CGDirectDisplayID> = []
    private var brightnessWriteFailures: Set<CGDirectDisplayID> = []

    var onlineSequence: [[CGDirectDisplayID]] = []
    var onlineError: FakeFailure?
    var ignoreZeroWrites = false
    var onSet: ((CGDirectDisplayID, Float) -> Void)?

    init(
        online: [CGDirectDisplayID],
        builtin: Set<CGDirectDisplayID>,
        brightness: [CGDirectDisplayID: Float]
    ) {
        self.online = online
        self.builtin = builtin
        brightnessValues = brightness
    }

    var canChangeCalls: [CGDirectDisplayID] {
        lock.withLock { recordedCanChangeCalls }
    }

    var getCalls: [CGDirectDisplayID] {
        lock.withLock { recordedGetCalls }
    }

    var setCalls: [BrightnessCall] {
        lock.withLock { recordedSetCalls }
    }

    func brightness(for displayID: CGDirectDisplayID) -> Float? {
        lock.withLock { brightnessValues[displayID] }
    }

    func setOnline(_ displayIDs: [CGDirectDisplayID]) {
        lock.withLock { online = displayIDs }
    }

    func setBrightnessFailures(
        for displayID: CGDirectDisplayID,
        reading: Bool = false,
        writing: Bool = false
    ) {
        lock.withLock {
            if reading { brightnessReadFailures.insert(displayID) }
            else { brightnessReadFailures.remove(displayID) }
            if writing { brightnessWriteFailures.insert(displayID) }
            else { brightnessWriteFailures.remove(displayID) }
        }
    }

    func setUserBrightness(_ value: Float, for displayID: CGDirectDisplayID) {
        lock.withLock { brightnessValues[displayID] = value }
    }

    func api() -> DisplayBrightnessAPI {
        DisplayBrightnessAPI(
            onlineDisplayIDs: { [self] in
                try lock.withLock {
                    if let onlineError { throw onlineError }
                    if !onlineSequence.isEmpty { return onlineSequence.removeFirst() }
                    return online
                }
            },
            isBuiltin: { [self] displayID in
                lock.withLock { builtin.contains(displayID) }
            },
            canChangeBrightness: { [self] displayID in
                lock.withLock {
                    recordedCanChangeCalls.append(displayID)
                    return brightnessValues[displayID] != nil
                }
            },
            getBrightness: { [self] displayID in
                try lock.withLock {
                    recordedGetCalls.append(displayID)
                    guard !brightnessReadFailures.contains(displayID) else {
                        throw FakeFailure.unavailable
                    }
                    guard let value = brightnessValues[displayID] else {
                        throw FakeFailure.unavailable
                    }
                    return value
                }
            },
            setBrightness: { [self] displayID, value in
                let hook: ((CGDirectDisplayID, Float) -> Void)? = lock.withLock {
                    recordedSetCalls.append(BrightnessCall(displayID: displayID, value: value))
                    return onSet
                }
                hook?(displayID, value)
                try lock.withLock {
                    guard !brightnessWriteFailures.contains(displayID) else {
                        throw FakeFailure.unavailable
                    }
                    guard brightnessValues[displayID] != nil else {
                        throw FakeFailure.unavailable
                    }
                    if !(ignoreZeroWrites && value == 0) {
                        brightnessValues[displayID] = value
                    }
                }
            }
        )
    }
}

private final class FakeHIDClock {
    private let lock = NSLock()
    private var lastInputUptime: TimeInterval
    private var eventCounters: [UInt32: UInt32] = [:]

    init() {
        lastInputUptime = ProcessInfo.processInfo.systemUptime
    }

    func uptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func snapshot() -> DisplayBlackoutHIDSnapshot? {
        let sampledAt = uptime()
        return lock.withLock {
            DisplayBlackoutHIDSnapshot(
                systemUptime: sampledAt,
                idleSeconds: max(0, sampledAt - lastInputUptime),
                eventCounters: eventCounters
            )
        }
    }

    func signalInput(_ eventType: CGEventType = .mouseMoved) {
        let eventUptime = uptime()
        lock.withLock {
            lastInputUptime = eventUptime
            eventCounters[eventType.rawValue, default: 0] &+= 1
        }
    }
}

private final class LockedExitCode {
    private let lock = NSLock()
    private var value: Int32?

    func set(_ newValue: Int32) { lock.withLock { value = newValue } }
    func get() -> Int32? { lock.withLock { value } }
}

private final class WatchdogFixture {
    let fake: FakeDisplaySystem
    let hidClock = FakeHIDClock()

    private let root: URL
    private let store: DisplayBlackoutJournalStore
    private let controlPipe = Pipe()
    private let responsePipe = Pipe()
    private let exitCode = LockedExitCode()
    private let exitExpectation: XCTestExpectation
    private let watchdog: DisplayBlackoutWatchdog
    private var started = false
    private var controlWriterClosed = false

    init(
        builtin: CGDirectDisplayID,
        external: CGDirectDisplayID,
        initialBrightness: Float
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DisplayBlackoutWatchdogTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        store = DisplayBlackoutJournalStore(
            fileURL: root
                .appendingPathComponent("runtime", isDirectory: true)
                .appendingPathComponent("display-blackout-recovery.json")
        )
        fake = FakeDisplaySystem(
            online: [builtin],
            builtin: [builtin],
            brightness: [builtin: initialBrightness, external: 0.4]
        )
        exitExpectation = XCTestExpectation(description: "watchdog exits")
        watchdog = DisplayBlackoutWatchdog(
            inputDescriptor: controlPipe.fileHandleForReading.fileDescriptor,
            outputDescriptor: responsePipe.fileHandleForWriting.fileDescriptor,
            dependencies: DisplayBlackoutWatchdogDependencies(
                controller: BuiltInDisplayBrightnessController(api: fake.api()),
                journalStore: store,
                hidInputSnapshot: { [hidClock] in hidClock.snapshot() },
                systemUptime: { [hidClock] in hidClock.uptime() },
                pollIntervalMilliseconds: 25
            )
        )
    }

    func start() {
        guard !started else { return }
        started = true
        DispatchQueue.global(qos: .userInitiated).async { [watchdog, exitCode, exitExpectation] in
            exitCode.set(watchdog.run())
            exitExpectation.fulfill()
        }
    }

    func send(_ request: DisplayBlackoutRequest) throws {
        try DisplayBlackoutFrameCodec.write(
            request,
            to: controlPipe.fileHandleForWriting.fileDescriptor
        )
    }

    func saveJournal(_ journal: DisplayBlackoutJournal) throws {
        try store.save(journal)
    }

    func loadJournal() throws -> DisplayBlackoutJournal? {
        try store.load()
    }

    func assertNoResponse(
        timeout: TimeInterval = 0.125,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var descriptor = pollfd(
            fd: responsePipe.fileHandleForReading.fileDescriptor,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
        let result = Darwin.poll(&descriptor, 1, Int32(timeout * 1_000))
        XCTAssertEqual(result, 0, "Unchanged recovery reason must not emit another response", file: file, line: line)
    }

    func receive(timeout: TimeInterval = 2) throws -> DisplayBlackoutResponse {
        var descriptor = pollfd(
            fd: responsePipe.fileHandleForReading.fileDescriptor,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
        let result = Darwin.poll(&descriptor, 1, Int32(timeout * 1_000))
        guard result > 0, (descriptor.revents & Int16(POLLIN)) != 0 else {
            throw FakeFailure.unavailable
        }
        return try XCTUnwrap(DisplayBlackoutFrameCodec.read(
            DisplayBlackoutResponse.self,
            from: responsePipe.fileHandleForReading.fileDescriptor
        ))
    }

    func closeControlWriter() throws {
        guard !controlWriterClosed else { return }
        controlWriterClosed = true
        try controlPipe.fileHandleForWriting.close()
    }

    func waitForExit(expected: Int32, timeout: TimeInterval = 2) {
        let result = XCTWaiter.wait(for: [exitExpectation], timeout: timeout)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(exitCode.get(), expected)
    }

    func cleanUp() {
        if !controlWriterClosed {
            try? controlPipe.fileHandleForWriting.close()
            controlWriterClosed = true
        }
        if started, exitCode.get() == nil {
            _ = XCTWaiter.wait(for: [exitExpectation], timeout: 1)
        }
        try? responsePipe.fileHandleForReading.close()
        try? responsePipe.fileHandleForWriting.close()
        try? controlPipe.fileHandleForReading.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
