import XCTest

final class HelperLeaseTests: XCTestCase {
    private let now: TimeInterval = 1_700_000_000
    private let bootID = "BOOT-A"

    private func active(changedByUs: Bool = true,
                        baselineEnabled: Bool = false,
                        heartbeat: TimeInterval? = nil,
                        notAfter: TimeInterval? = nil,
                        bootID: String = "BOOT-A") -> HelperLeaseJournal {
        HelperLeaseJournal(
            leaseID: "com.kenny.lidlessai.agent-monitor",
            baselineEnabled: baselineEnabled,
            changedByUs: changedByUs,
            phase: .active,
            bootID: bootID,
            lastHeartbeat: heartbeat ?? now,
            notAfter: notAfter ?? now + 600
        )
    }

    func testPendingClaimsOnlyABaselineOffTransition() {
        let fromOff = HelperLeaseJournal.pending(
            leaseID: "lease", baselineEnabled: false,
            bootID: bootID, now: now, notAfter: now + 60)
        XCTAssertEqual(fromOff.phase, .pending)
        XCTAssertTrue(fromOff.changedByUs)

        let fromOn = HelperLeaseJournal.pending(
            leaseID: "lease", baselineEnabled: true,
            bootID: bootID, now: now, notAfter: now + 60)
        XCTAssertFalse(fromOn.changedByUs)
    }

    func testStateDictionaryUsesOnlyFoundationXPCValues() {
        let journal = active()
        let state = journal.stateDictionary
        XCTAssertEqual(state["schemaVersion"] as? Int, 1)
        XCTAssertEqual(state["leaseID"] as? String, journal.leaseID)
        XCTAssertEqual(state["baselineEnabled"] as? Bool, false)
        XCTAssertEqual(state["changedByUs"] as? Bool, true)
        XCTAssertEqual(state["phase"] as? String, "active")
        XCTAssertEqual(state["bootID"] as? String, bootID)
        XCTAssertEqual(state["lastHeartbeat"] as? Double, now)
        XCTAssertEqual(state["notAfter"] as? Double, now + 600)
    }

    func testConditionalReleaseOutcomeRoundTripsThroughFoundationDictionary() {
        let outcome = HelperReleaseOutcome(
            leaseReleased: true,
            restoredOwnedTransition: true,
            lidClosed: true,
            clamshellCausesSleep: false,
            sleepAttempted: true,
            sleepRequestAccepted: true,
            disposition: .sleepRequested
        )
        XCTAssertEqual(HelperReleaseOutcome(dictionary: outcome.dictionary), outcome)

        let unknownState = HelperReleaseOutcome(
            leaseReleased: true,
            restoredOwnedTransition: true,
            lidClosed: nil,
            clamshellCausesSleep: nil,
            sleepAttempted: false,
            sleepRequestAccepted: false,
            disposition: .lidStateUnknown
        )
        XCTAssertNil(unknownState.dictionary["lidClosed"])
        XCTAssertNil(unknownState.dictionary["clamshellCausesSleep"])
        XCTAssertEqual(HelperReleaseOutcome(dictionary: unknownState.dictionary), unknownState)
    }

    func testConditionalReleaseOutcomeRejectsMalformedXPCDictionary() {
        XCTAssertNil(HelperReleaseOutcome(dictionary: [:]))
        XCTAssertNil(HelperReleaseOutcome(dictionary: [
            "schemaVersion": 999,
            "leaseReleased": true,
            "restoredOwnedTransition": true,
            "sleepAttempted": false,
            "sleepRequestAccepted": false,
            "disposition": HelperReleaseDisposition.releasedWithoutSleep.rawValue
        ]))
    }

    func testSameBootStartupRetainsFreshActiveLeaseForAppAdoption() {
        XCTAssertNil(
            HelperLeasePolicy.recoveryReason(
                for: active(), currentBootID: bootID, now: now + 1,
                heartbeatTimeout: 90, atStartup: true)
        )
    }

    func testPendingAndReleasingTransactionsRecoverImmediately() {
        for phase in [HelperLeasePhase.pending, .releasing] {
            var journal = active()
            journal.phase = phase
            XCTAssertEqual(
                HelperLeasePolicy.recoveryReason(
                    for: journal, currentBootID: bootID, now: now + 1,
                    heartbeatTimeout: 90, atStartup: false),
                .incompleteTransaction
            )
        }
    }

    func testHeartbeatRecoversAtNinetySeconds() {
        XCTAssertNil(
            HelperLeasePolicy.recoveryReason(
                for: active(), currentBootID: bootID, now: now + 89.999,
                heartbeatTimeout: 90, atStartup: false)
        )
        XCTAssertEqual(
            HelperLeasePolicy.recoveryReason(
                for: active(), currentBootID: bootID, now: now + 90,
                heartbeatTimeout: 90, atStartup: false),
            .heartbeatTimedOut
        )
    }

    func testAbsoluteExpiryWinsEvenWithAFreshHeartbeat() {
        let journal = active(heartbeat: now + 59, notAfter: now + 60)
        XCTAssertEqual(
            HelperLeasePolicy.recoveryReason(
                for: journal, currentBootID: bootID, now: now + 60,
                heartbeatTimeout: 90, atStartup: false),
            .expired
        )
    }

    func testPriorBootJournalStillCarriesOwnedRestoreEvidence() {
        let journal = active(bootID: "BOOT-OLD")
        XCTAssertEqual(
            HelperLeasePolicy.recoveryReason(
                for: journal, currentBootID: bootID, now: now,
                heartbeatTimeout: 90, atStartup: true),
            .bootChanged
        )
        XCTAssertTrue(HelperLeasePolicy.shouldRestoreSleep(for: journal))
    }

    func testPriorBootPersistentOneRequiresRestoreWrite() {
        let journal = active(bootID: "BOOT-OLD")
        XCTAssertTrue(HelperLeasePolicy.requiresRestoreWrite(
            for: journal, currentlyEnabled: true))
    }

    func testPriorBootAlreadyResetZeroNeedsNoRestoreWrite() {
        let journal = active(bootID: "BOOT-OLD")
        XCTAssertFalse(HelperLeasePolicy.requiresRestoreWrite(
            for: journal, currentlyEnabled: false))
    }

    func testRestoreRequiresExplicitZeroToOneOwnership() {
        XCTAssertTrue(HelperLeasePolicy.shouldRestoreSleep(
            for: active(changedByUs: true, baselineEnabled: false)))
        XCTAssertFalse(HelperLeasePolicy.shouldRestoreSleep(
            for: active(changedByUs: false, baselineEnabled: true)))

        // Even inconsistent/corrupt-looking fields fail closed rather than
        // using changedByUs alone to clear somebody else's baseline.
        XCTAssertFalse(HelperLeasePolicy.shouldRestoreSleep(
            for: active(changedByUs: true, baselineEnabled: true)))
    }

    func testRequestValidationRejectsUnsafeInputs() {
        XCTAssertNotNil(HelperLeaseRequestValidator.error(leaseID: "  ", now: now))
        XCTAssertNotNil(HelperLeaseRequestValidator.error(
            leaseID: String(repeating: "x", count: 257), now: now))
        XCTAssertNotNil(HelperLeaseRequestValidator.error(
            leaseID: "lease", notAfter: now, now: now))
        XCTAssertNotNil(HelperLeaseRequestValidator.error(
            leaseID: "lease", notAfter: .infinity, now: now))
        XCTAssertNil(HelperLeaseRequestValidator.error(
            leaseID: "lease", notAfter: now + 1, now: now))
    }

    func testAtomicJournalRoundTripAndReplacementAtInjectedPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelperLeaseTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("journal.json")
        let store = HelperLeaseJournalStore(fileURL: file)

        var journal = active()
        try store.save(journal)
        XCTAssertEqual(try store.load(), journal)

        journal.phase = .releasing
        journal.lastHeartbeat += 30
        try store.save(journal)
        XCTAssertEqual(try store.load(), journal)

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions.map { $0 & 0o777 }, 0o600)

        try store.remove()
        XCTAssertNil(try store.load())
    }

    func testMalformedJournalThrowsAndIsPreserved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelperLeaseMalformed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("journal.json")
        try Data("{not-json".utf8).write(to: file, options: .atomic)
        let store = HelperLeaseJournalStore(fileURL: file)

        XCTAssertThrowsError(try store.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "unknown ownership evidence must not be deleted")
    }

    func testJournalRejectsSymbolicLinkWithoutChangingTarget() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelperLeaseSymlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target.json")
        let linked = directory.appendingPathComponent("journal.json")
        let marker = Data("do-not-touch".utf8)
        try marker.write(to: target)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)

        let store = HelperLeaseJournalStore(fileURL: linked)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(active()))
        XCTAssertEqual(try Data(contentsOf: target), marker)
    }

    func testJournalRejectsOversizedInput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelperLeaseOversized-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("journal.json")
        try Data(repeating: 0x20, count: 1_048_577).write(to: file)

        XCTAssertThrowsError(try HelperLeaseJournalStore(fileURL: file).load())
    }

    func testJournalRejectsGroupOrWorldWritableFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelperLeasePermissions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("journal.json")
        let store = HelperLeaseJournalStore(fileURL: file)
        try store.save(active())
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o666)],
            ofItemAtPath: file.path
        )

        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(active()))
        XCTAssertThrowsError(try store.remove())
    }

    func testUnknownSchemaFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelperLeaseSchema-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HelperLeaseJournalStore(fileURL: directory.appendingPathComponent("journal.json"))
        var journal = active()
        journal.schemaVersion = 999
        try store.save(journal)
        XCTAssertThrowsError(try store.load())
    }

    func testRuntimePathsAndBootIDAreInjectable() {
        let path = "/tmp/lidless-helper-tests/custom.json"
        let environment = [
            HelperLeaseRuntime.journalPathEnvKey: path,
            HelperLeaseRuntime.bootIDEnvKey: "TEST-BOOT"
        ]
        XCTAssertEqual(HelperLeaseRuntime.journalFileURL(environment: environment).path, path)
        XCTAssertEqual(HelperLeaseRuntime.currentBootID(environment: environment), "TEST-BOOT")
    }
}
