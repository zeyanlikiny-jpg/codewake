import Darwin
import Foundation
import XCTest

final class CodexCancellationObserverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_173_200)
    private var sessionsRoot: URL!
    private var calendar: Calendar!

    override func setUpWithError() throws {
        try super.setUpWithError()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        sessionsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Lidless-CodexCancellationObserverTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: sessionsRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let sessionsRoot {
            try? FileManager.default.removeItem(at: sessionsRoot)
        }
        sessionsRoot = nil
        calendar = nil
        try super.tearDownWithError()
    }

    func testReturnsOnlyExactInterruptedAbortAndDeduplicates() throws {
        let sessionID = "session-exact"
        let turnID = "turn-exact"
        let interruptedAt = now.addingTimeInterval(-10)
        let largePrivateMetadata = String(repeating: "private-context-", count: 3_000)
        let metadata = sessionMetadata(
            sessionID: sessionID,
            additionalPayload: ",\"base_instructions\":\"\(largePrivateMetadata)\""
        )
        try writeRollout(sessionID: sessionID, lines: [
            metadata,
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"turn_aborted\",\"turn_id\":\"\(turnID)\",\"reason\":\"interrupted\",\"completed_at\":\(timestamp(interruptedAt))}}",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\",\"turn_id\":\"other-turn\",\"reason\":\"interrupted\",\"completed_at\":\(timestamp(interruptedAt))}}",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\",\"turn_id\":\"\(turnID)\",\"reason\":\"cancelled\",\"detail\":\"interrupted\",\"completed_at\":\(timestamp(interruptedAt))}}",
            cancellation(turnID: turnID, at: interruptedAt)
        ])
        let observer = makeObserver()
        let turn = observedTurn(sessionID: sessionID, turnID: turnID)

        let records = observer.reconcile(activeTurns: [turn])

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.sessionID, sessionID)
        XCTAssertEqual(records.first?.turnID, turnID)
        XCTAssertEqual(records.first?.interruptedAt, interruptedAt)
        XCTAssertEqual(records.first?.reason, .interrupted)
        XCTAssertTrue(observer.reconcile(activeTurns: [turn]).isEmpty)
    }

    func testRejectsFilenameWhenBoundedSessionMetadataDoesNotMatch() throws {
        let sessionID = "session-requested"
        let turnID = "turn-requested"
        try writeRollout(sessionID: sessionID, lines: [
            sessionMetadata(sessionID: "session-different"),
            cancellation(turnID: turnID, at: now.addingTimeInterval(-5))
        ])

        let records = makeObserver().reconcile(activeTurns: [
            observedTurn(sessionID: sessionID, turnID: turnID)
        ])

        XCTAssertTrue(records.isEmpty)
    }

    func testRejectsAbortOutsideTurnAndClockBounds() throws {
        let sessionID = "session-time"
        let oldTurnID = "turn-old"
        let futureTurnID = "turn-future"
        try writeRollout(sessionID: sessionID, lines: [
            sessionMetadata(sessionID: sessionID),
            cancellation(turnID: oldTurnID, at: now.addingTimeInterval(-120)),
            cancellation(turnID: futureTurnID, at: now.addingTimeInterval(301))
        ])

        let records = makeObserver().reconcile(activeTurns: [
            observedTurn(
                sessionID: sessionID,
                turnID: oldTurnID,
                startedAt: now.addingTimeInterval(-60)
            ),
            observedTurn(sessionID: sessionID, turnID: futureTurnID)
        ])

        XCTAssertTrue(records.isEmpty)
    }

    func testFindsCurrentTurnInRolloutFromOldUUIDv7SessionDay() throws {
        // UUIDv7 timestamp decodes to 2026-06-20, while the active turn and its
        // cancellation occur on the observer's current 2026-08-19 clock.
        let sessionID = "019ee4e5-dc3b-7f80-ad0d-007d332d7706"
        let turnID = "turn-in-old-thread"
        let oldDirectory = sessionsRoot
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("06", isDirectory: true)
            .appendingPathComponent("20", isDirectory: true)
        try FileManager.default.createDirectory(
            at: oldDirectory,
            withIntermediateDirectories: true
        )
        let rollout = oldDirectory.appendingPathComponent(
            "rollout-2026-06-20T19-58-49-\(sessionID).jsonl"
        )
        let contents = [
            sessionMetadata(sessionID: sessionID),
            cancellation(turnID: turnID, at: now.addingTimeInterval(-5)),
        ].joined(separator: "\n") + "\n"
        try Data(contents.utf8).write(to: rollout)

        let records = makeObserver().reconcile(activeTurns: [
            observedTurn(sessionID: sessionID, turnID: turnID)
        ])

        XCTAssertEqual(records.map(\.turnID), [turnID])
    }

    func testDuplicateSnapshotUsesEarliestStartAndPreservesStartedAt() throws {
        let sessionID = "session-duplicate"
        let turnID = "turn-duplicate"
        let interruptedAt = now.addingTimeInterval(-30)
        try writeRollout(sessionID: sessionID, lines: [
            sessionMetadata(sessionID: sessionID),
            cancellation(turnID: turnID, at: interruptedAt)
        ])
        let correctPendingSnapshot = observedTurn(
            sessionID: sessionID,
            turnID: turnID,
            startedAt: now.addingTimeInterval(-90),
            lastEventAt: now.addingTimeInterval(-80)
        )
        let laterLiveSnapshot = CodexCancellationObservedTurn(
            sessionID: sessionID,
            turnID: turnID,
            startedAt: nil,
            lastEventAt: now.addingTimeInterval(-10)
        )

        let records = makeObserver().reconcile(activeTurns: [
            laterLiveSnapshot,
            correctPendingSnapshot,
            laterLiveSnapshot
        ])

        XCTAssertEqual(records.map(\.turnID), [turnID])
    }

    func testCompletesAnAppendedPartialLineIncrementally() throws {
        let sessionID = "session-partial"
        let turnID = "turn-partial"
        let event = cancellation(turnID: turnID, at: now.addingTimeInterval(-5))
        let rollout = try writeRollout(
            sessionID: sessionID,
            rawContents: sessionMetadata(sessionID: sessionID) + "\n" + event
        )
        let observer = makeObserver()
        let turn = observedTurn(sessionID: sessionID, turnID: turnID)

        XCTAssertTrue(observer.reconcile(activeTurns: [turn]).isEmpty)
        try append("\n", to: rollout)

        XCTAssertEqual(observer.reconcile(activeTurns: [turn]).map(\.turnID), [turnID])
    }

    func testCachesSameSessionAbortUntilLateTurnBecomesActive() throws {
        let sessionID = "session-siblings"
        let firstTurnID = "turn-first"
        let lateTurnID = "turn-late"
        try writeRollout(sessionID: sessionID, lines: [
            sessionMetadata(sessionID: sessionID),
            cancellation(turnID: lateTurnID, at: now.addingTimeInterval(-5))
        ])
        let observer = makeObserver()

        XCTAssertTrue(observer.reconcile(activeTurns: [
            observedTurn(sessionID: sessionID, turnID: firstTurnID)
        ]).isEmpty)

        let records = observer.reconcile(activeTurns: [
            observedTurn(sessionID: sessionID, turnID: firstTurnID),
            observedTurn(sessionID: sessionID, turnID: lateTurnID)
        ])
        XCTAssertEqual(records.map(\.turnID), [lateTurnID])
        XCTAssertTrue(observer.reconcile(activeTurns: [
            observedTurn(sessionID: sessionID, turnID: lateTurnID)
        ]).isEmpty)
    }

    func testLateTurnCacheExpiresAfterTwentyFourHours() throws {
        let sessionID = "session-cache-expiry"
        let trackingTurnID = "turn-tracking"
        let lateTurnID = "turn-expired"
        try writeRollout(sessionID: sessionID, lines: [
            sessionMetadata(sessionID: sessionID),
            cancellation(turnID: lateTurnID, at: now.addingTimeInterval(-5))
        ])
        let testClock = LockedClock(now)
        let observer = makeObserver(clock: { testClock.now })

        XCTAssertTrue(observer.reconcile(activeTurns: [
            observedTurn(sessionID: sessionID, turnID: trackingTurnID)
        ]).isEmpty)

        testClock.now = now.addingTimeInterval(24 * 60 * 60 + 1)
        XCTAssertTrue(observer.reconcile(activeTurns: [
            observedTurn(sessionID: sessionID, turnID: trackingTurnID),
            observedTurn(sessionID: sessionID, turnID: lateTurnID)
        ]).isEmpty)
    }

    func testLateTurnCacheKeepsOnlyNewestTwoHundredFiftySixRecords() throws {
        let sessionID = "session-cache-capacity"
        let trackingTurnID = "turn-tracking"
        let oldestTurnID = "turn-cache-000"
        let newestTurnID = "turn-cache-256"
        var lines = [sessionMetadata(sessionID: sessionID)]
        lines.append(contentsOf: (0...256).map { index in
            cancellation(
                turnID: String(format: "turn-cache-%03d", index),
                at: now.addingTimeInterval(-50 + Double(index) / 10)
            )
        })
        try writeRollout(sessionID: sessionID, lines: lines)
        let observer = makeObserver()

        XCTAssertTrue(observer.reconcile(activeTurns: [
            observedTurn(sessionID: sessionID, turnID: trackingTurnID)
        ]).isEmpty)

        let records = observer.reconcile(activeTurns: [
            observedTurn(sessionID: sessionID, turnID: oldestTurnID),
            observedTurn(sessionID: sessionID, turnID: newestTurnID)
        ])
        XCTAssertEqual(records.map(\.turnID), [newestTurnID])
    }

    func testDetectsSameInodeTruncateAndRegrow() throws {
        let sessionID = "session-truncate"
        let turnID = "turn-truncate"
        let rollout = try writeRollout(sessionID: sessionID, lines: [
            sessionMetadata(sessionID: sessionID),
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}"
        ])
        let observer = makeObserver()
        let turn = observedTurn(sessionID: sessionID, turnID: turnID)
        XCTAssertTrue(observer.reconcile(activeTurns: [turn]).isEmpty)
        let originalInode = try inode(of: rollout)
        let replacement = [
            sessionMetadata(sessionID: sessionID),
            String(repeating: "x", count: 300),
            cancellation(turnID: turnID, at: now.addingTimeInterval(-5))
        ].joined(separator: "\n") + "\n"

        let handle = try FileHandle(forWritingTo: rollout)
        handle.truncateFile(atOffset: 0)
        handle.write(Data(replacement.utf8))
        try handle.close()

        XCTAssertEqual(try inode(of: rollout), originalInode)
        XCTAssertEqual(observer.reconcile(activeTurns: [turn]).map(\.turnID), [turnID])
    }

    func testDetectsRolloutRotationAndReplacement() throws {
        let sessionID = "session-rotation"
        let turnID = "turn-rotation"
        let rollout = try writeRollout(sessionID: sessionID, lines: [
            sessionMetadata(sessionID: sessionID),
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}"
        ])
        let observer = makeObserver()
        let turn = observedTurn(sessionID: sessionID, turnID: turnID)
        XCTAssertTrue(observer.reconcile(activeTurns: [turn]).isEmpty)

        let rotated = rollout.appendingPathExtension("rotated")
        try FileManager.default.moveItem(at: rollout, to: rotated)
        try Data(([
            sessionMetadata(sessionID: sessionID),
            cancellation(turnID: turnID, at: now.addingTimeInterval(-5))
        ].joined(separator: "\n") + "\n").utf8).write(to: rollout)

        XCTAssertEqual(observer.reconcile(activeTurns: [turn]).map(\.turnID), [turnID])
    }

    func testRejectsSymlinkRootsFilesAndUnexpectedOwnership() throws {
        let sessionID = "session-safety"
        let turnID = "turn-safety"
        let validContents = [
            sessionMetadata(sessionID: sessionID),
            cancellation(turnID: turnID, at: now.addingTimeInterval(-5))
        ].joined(separator: "\n") + "\n"
        let externalFile = sessionsRoot.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: externalFile) }
        try Data(validContents.utf8).write(to: externalFile)
        let directory = try makeDayDirectory()
        let linkedRollout = directory.appendingPathComponent(
            "rollout-2026-08-19T20-00-00-\(sessionID).jsonl"
        )
        try FileManager.default.createSymbolicLink(
            at: linkedRollout,
            withDestinationURL: externalFile
        )
        let turn = observedTurn(sessionID: sessionID, turnID: turnID)

        XCTAssertTrue(makeObserver().reconcile(activeTurns: [turn]).isEmpty)

        try FileManager.default.removeItem(at: linkedRollout)
        try Data(validContents.utf8).write(to: linkedRollout)
        let differentOwner = geteuid() == uid_t.max ? geteuid() - 1 : geteuid() + 1
        XCTAssertTrue(makeObserver(expectedOwnerID: differentOwner)
            .reconcile(activeTurns: [turn]).isEmpty)

        let linkedRoot = sessionsRoot.deletingLastPathComponent()
            .appendingPathComponent("sessions-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: linkedRoot) }
        try FileManager.default.createSymbolicLink(
            at: linkedRoot,
            withDestinationURL: sessionsRoot
        )
        XCTAssertTrue(makeObserver(sessionsRoot: linkedRoot)
            .reconcile(activeTurns: [turn]).isEmpty)
    }

    func testInitialScanReadsOnlyBoundedTail() throws {
        let sessionID = "session-tail"
        let oldTurnID = "turn-outside-tail"
        let recentTurnID = "turn-in-tail"
        var lines = [
            sessionMetadata(sessionID: sessionID),
            cancellation(turnID: oldTurnID, at: now.addingTimeInterval(-20))
        ]
        lines.append(contentsOf: (0..<80).map {
            "{\"type\":\"noise\",\"payload\":\"\($0)-\(String(repeating: "x", count: 64))\"}"
        })
        lines.append(cancellation(turnID: recentTurnID, at: now.addingTimeInterval(-5)))
        try writeRollout(sessionID: sessionID, lines: lines)

        let records = makeObserver(maximumInitialTailBytes: 1_024).reconcile(activeTurns: [
            observedTurn(sessionID: sessionID, turnID: oldTurnID),
            observedTurn(sessionID: sessionID, turnID: recentTurnID)
        ])

        XCTAssertEqual(records.map(\.turnID), [recentTurnID])
    }

    func testConcurrentReconcilesAreSerializedAndDeliverOnce() throws {
        let sessionID = "session-concurrent"
        let turnID = "turn-concurrent"
        try writeRollout(sessionID: sessionID, lines: [
            sessionMetadata(sessionID: sessionID),
            cancellation(turnID: turnID, at: now.addingTimeInterval(-5))
        ])
        let observer = makeObserver()
        let turn = observedTurn(sessionID: sessionID, turnID: turnID)
        let resultCounter = LockedCounter()
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "CodexCancellationObserverTests.concurrent",
            attributes: .concurrent
        )

        for _ in 0..<24 {
            group.enter()
            queue.async {
                resultCounter.add(observer.reconcile(activeTurns: [turn]).count)
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(resultCounter.value, 1)
    }

    func testRejectsTraversalLikeIdentifiersBeforeFilesystemLookup() throws {
        let observer = makeObserver()
        let invalid = observedTurn(
            sessionID: "../../another-root",
            turnID: "turn-invalid"
        )

        XCTAssertTrue(observer.reconcile(activeTurns: [invalid]).isEmpty)
    }

    private func makeObserver(
        sessionsRoot overrideRoot: URL? = nil,
        expectedOwnerID: uid_t = geteuid(),
        maximumInitialTailBytes: Int = 2 * 1_024 * 1_024,
        clock: (() -> Date)? = nil
    ) -> CodexCancellationObserver {
        let fixedNow = now
        return CodexCancellationObserver(
            sessionsRoot: overrideRoot ?? sessionsRoot,
            clock: clock ?? { fixedNow },
            calendar: calendar,
            expectedOwnerID: expectedOwnerID,
            maximumInitialTailBytes: maximumInitialTailBytes
        )
    }

    private func observedTurn(
        sessionID: String,
        turnID: String,
        startedAt: Date? = nil,
        lastEventAt: Date? = nil
    ) -> CodexCancellationObservedTurn {
        CodexCancellationObservedTurn(
            sessionID: sessionID,
            turnID: turnID,
            startedAt: startedAt ?? now.addingTimeInterval(-60),
            lastEventAt: lastEventAt ?? now.addingTimeInterval(-30)
        )
    }

    @discardableResult
    private func writeRollout(
        sessionID: String,
        lines: [String]
    ) throws -> URL {
        try writeRollout(
            sessionID: sessionID,
            rawContents: lines.joined(separator: "\n") + "\n"
        )
    }

    @discardableResult
    private func writeRollout(
        sessionID: String,
        rawContents: String
    ) throws -> URL {
        let directory = try makeDayDirectory()
        let url = directory.appendingPathComponent(
            "rollout-2026-08-19T20-00-00-\(sessionID).jsonl"
        )
        try Data(rawContents.utf8).write(to: url)
        return url
    }

    private func makeDayDirectory() throws -> URL {
        let directory = sessionsRoot
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("08", isDirectory: true)
            .appendingPathComponent("19", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func sessionMetadata(
        sessionID: String,
        additionalPayload: String = ""
    ) -> String {
        "{\"timestamp\":\"2026-08-19T20:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(sessionID)\"\(additionalPayload)}}"
    }

    private func cancellation(turnID: String, at date: Date) -> String {
        "{\"timestamp\":\"2026-08-19T20:59:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\",\"turn_id\":\"\(turnID)\",\"reason\":\"interrupted\",\"completed_at\":\(timestamp(date))}}"
    }

    private func timestamp(_ date: Date) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), date.timeIntervalSince1970)
    }

    private func append(_ string: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        handle.write(Data(string.utf8))
        try handle.close()
    }

    private func inode(of url: URL) throws -> UInt64 {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return UInt64(info.st_ino)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func add(_ amount: Int) {
        lock.lock()
        storage += amount
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date

    init(_ now: Date) {
        storage = now
    }

    var now: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
