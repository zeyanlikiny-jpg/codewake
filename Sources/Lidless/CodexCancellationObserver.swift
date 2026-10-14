import Darwin
import Foundation

/// The minimum lifecycle identity needed to reconcile one currently-active
/// Codex turn against Codex's local rollout journal.
struct CodexCancellationObservedTurn: Hashable, Sendable {
    let sessionID: String
    let turnID: String
    let startedAt: Date?
    let lastEventAt: Date

    init(
        sessionID: String,
        turnID: String,
        startedAt: Date? = nil,
        lastEventAt: Date
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
    }

    fileprivate var searchStartedAt: Date {
        startedAt ?? lastEventAt
    }
}

/// Privacy-minimized terminal evidence. No prompt, response, tool, model, cwd,
/// or rollout path is retained or returned.
struct CodexCancellationRecord: Hashable, Sendable {
    enum Reason: String, Hashable, Sendable {
        case interrupted
    }

    let sessionID: String
    let turnID: String
    let interruptedAt: Date
    let reason: Reason
}

/// Reconciles active Codex turns with Codex Desktop's durable `turn_aborted`
/// journal edge.
///
/// Codex's public command hooks currently have no cancellation hook. The local
/// rollout contains an exact, content-free terminal record, however. This
/// observer reads only bounded file tails, prefilters for that record before
/// JSON decoding, and returns only stable IDs plus its completion timestamp.
/// Every file is opened read-only beneath the configured sessions root, without
/// following symbolic links, and must be a regular file owned by the user.
final class CodexCancellationObserver: @unchecked Sendable {
    private static let maximumSessionIdentifierBytes = 128
    private static let maximumTurnIdentifierBytes = 128
    private static let maximumDirectoryEntries = 4_096
    private static let maximumLookbackDays = 7
    private static let maximumClockSkew: TimeInterval = 300
    private static let timestampRoundingTolerance: TimeInterval = 2
    private static let maximumActiveSessionCount = 16
    private static let maximumActiveTurnCount = 256
    private static let cancellationCacheLifetime: TimeInterval = 24 * 60 * 60
    private static let maximumCachedCancellations = 256

    private let sessionsRoot: URL
    private let clock: () -> Date
    private let calendar: Calendar
    private let expectedOwnerID: uid_t
    private let maximumSessionMetadataBytes: Int
    private let maximumInitialTailBytes: Int
    private let maximumIncrementalBytes: Int
    private let maximumCandidateLineBytes: Int

    /// Serializes the bounded scan as well as all cursor and deduplication
    /// state. Callers may invoke `reconcile` from any background queue.
    private let stateLock = NSLock()
    private var cursorsByPath: [String: FileCursor] = [:]
    private var verifiedRolloutsBySessionID: [String: VerifiedRollout] = [:]
    private var cachedCancellationsByTurn = [TurnKey: CachedCancellation]()
    private var deliveredTurnKeys = Set<TurnKey>()

    convenience init() {
        let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        self.init(sessionsRoot: sessionsRoot)
    }

    init(
        sessionsRoot: URL,
        clock: @escaping () -> Date = Date.init,
        calendar: Calendar = .current,
        expectedOwnerID: uid_t = geteuid(),
        maximumSessionMetadataBytes: Int = 256 * 1_024,
        maximumInitialTailBytes: Int = 2 * 1_024 * 1_024,
        maximumIncrementalBytes: Int = 2 * 1_024 * 1_024,
        maximumCandidateLineBytes: Int = 16 * 1_024
    ) {
        self.sessionsRoot = sessionsRoot.standardizedFileURL
        self.clock = clock
        self.calendar = calendar
        self.expectedOwnerID = expectedOwnerID
        self.maximumSessionMetadataBytes = max(1_024, maximumSessionMetadataBytes)
        self.maximumInitialTailBytes = max(1_024, maximumInitialTailBytes)
        self.maximumIncrementalBytes = max(1_024, maximumIncrementalBytes)
        self.maximumCandidateLineBytes = max(512, maximumCandidateLineBytes)
    }

    /// Manual and periodic reconciliation boundary. This method is synchronous,
    /// bounded, and safe to invoke from any background queue. Failure is
    /// conservative: unreadable, ambiguous, unsafe, or malformed journal state
    /// returns no new terminal record.
    ///
    /// A returned record is atomically marked delivered before this method
    /// returns. The caller must therefore idempotently apply every returned
    /// record, even if another UI/process-scan generation became newer while
    /// this scan was in flight.
    @discardableResult
    func reconcile(
        activeTurns: [CodexCancellationObservedTurn]
    ) -> [CodexCancellationRecord] {
        stateLock.lock()
        defer { stateLock.unlock() }

        let now = clock()
        guard isSafeOwnedDirectory(sessionsRoot) else { return [] }
        pruneCancellationCache(now: now)

        let turns = deduplicatedValidTurns(activeTurns)
        guard !turns.isEmpty else {
            pruneCursors(keeping: [], activeTurnKeys: [])
            verifiedRolloutsBySessionID.removeAll(keepingCapacity: true)
            return []
        }
        // The launch reconciliation is intentionally synchronous so a stale
        // recovery snapshot cannot acquire a helper lease first. Bound the
        // aggregate work as well as each file tail; an implausibly large or
        // corrupt snapshot fails closed and keeps the Mac awake.
        guard turns.count <= Self.maximumActiveTurnCount,
              Set(turns.map(\.sessionID)).count <= Self.maximumActiveSessionCount else {
            return []
        }
        let activeTurnKeys = Set(turns.map {
            TurnKey(sessionID: $0.sessionID, turnID: $0.turnID)
        })

        let turnsBySession = Dictionary(grouping: turns, by: \CodexCancellationObservedTurn.sessionID)
        var pathsInUse = Set<String>()
        var records: [CodexCancellationRecord] = []

        for sessionID in turnsBySession.keys.sorted() {
            guard let sessionTurns = turnsBySession[sessionID],
                  let resolvedRollout = resolveRollout(
                    sessionID: sessionID,
                    turns: sessionTurns,
                    now: now
                  ) else { continue }

            pathsInUse.insert(resolvedRollout.rollout.url.path)
            guard let lines = readNewCompleteLines(from: resolvedRollout) else { continue }

            for line in lines {
                guard let cancellation = decodeCancellation(from: line),
                      cancellation.interruptedAt <= now.addingTimeInterval(
                        Self.maximumClockSkew
                      ) else { continue }
                cache(CodexCancellationRecord(
                    sessionID: sessionID,
                    turnID: cancellation.turnID,
                    interruptedAt: cancellation.interruptedAt,
                    reason: .interrupted
                ), observedAt: now)
            }
        }

        for turn in turns {
            let key = TurnKey(sessionID: turn.sessionID, turnID: turn.turnID)
            guard let cached = cachedCancellationsByTurn[key] else { continue }
            let earliestAccepted = turn.searchStartedAt.addingTimeInterval(
                -Self.timestampRoundingTolerance
            )
            guard cached.record.interruptedAt >= earliestAccepted,
                  cached.record.interruptedAt <= now.addingTimeInterval(
                    Self.maximumClockSkew
                  ),
                  deliveredTurnKeys.insert(key).inserted else { continue }
            records.append(cached.record)
        }

        pruneCursors(keeping: pathsInUse, activeTurnKeys: activeTurnKeys)
        let activeSessionIDs = Set(turns.map(\.sessionID))
        verifiedRolloutsBySessionID = verifiedRolloutsBySessionID.filter {
            activeSessionIDs.contains($0.key)
        }
        return records.sorted {
            if $0.interruptedAt != $1.interruptedAt {
                return $0.interruptedAt < $1.interruptedAt
            }
            if $0.sessionID != $1.sessionID { return $0.sessionID < $1.sessionID }
            return $0.turnID < $1.turnID
        }
    }

    private func isValidTurn(_ turn: CodexCancellationObservedTurn) -> Bool {
        isSafeIdentifier(turn.sessionID, maximumBytes: Self.maximumSessionIdentifierBytes)
            && isSafeIdentifier(turn.turnID, maximumBytes: Self.maximumTurnIdentifierBytes)
    }

    private func deduplicatedValidTurns(
        _ turns: [CodexCancellationObservedTurn]
    ) -> [CodexCancellationObservedTurn] {
        var byKey: [TurnKey: CodexCancellationObservedTurn] = [:]
        for turn in turns where isValidTurn(turn) {
            let key = TurnKey(sessionID: turn.sessionID, turnID: turn.turnID)
            if let existing = byKey[key] {
                let earliestStartedAt = [existing.startedAt, turn.startedAt]
                    .compactMap { $0 }
                    .min()
                byKey[key] = CodexCancellationObservedTurn(
                    sessionID: turn.sessionID,
                    turnID: turn.turnID,
                    startedAt: earliestStartedAt,
                    lastEventAt: min(existing.lastEventAt, turn.lastEventAt)
                )
            } else {
                byKey[key] = turn
            }
        }
        return Array(byKey.values)
    }

    private func isSafeIdentifier(_ value: String, maximumBytes: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumBytes else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45
                || byte == 95
                || byte == 46
        }
    }

    private func resolveRollout(
        sessionID: String,
        turns: [CodexCancellationObservedTurn],
        now: Date
    ) -> ResolvedRollout? {
        if let cached = verifiedRolloutsBySessionID[sessionID],
           verifiedIdentityStillMatches(cached) {
            return ResolvedRollout(
                rollout: cached,
                metadataValidatedThisScan: false
            )
        }

        verifiedRolloutsBySessionID.removeValue(forKey: sessionID)
        guard let located = locateRollout(
            sessionID: sessionID,
            turns: turns,
            now: now
        ) else { return nil }
        verifiedRolloutsBySessionID[sessionID] = located
        return ResolvedRollout(
            rollout: located,
            metadataValidatedThisScan: true
        )
    }

    private func verifiedIdentityStillMatches(_ rollout: VerifiedRollout) -> Bool {
        guard let opened = securelyOpenRegularFile(rollout.url) else { return false }
        defer { Darwin.close(opened.descriptor) }
        return opened.device == rollout.device && opened.inode == rollout.inode
    }

    private func locateRollout(
        sessionID: String,
        turns: [CodexCancellationObservedTurn],
        now: Date
    ) -> VerifiedRollout? {
        let suffix = "-\(sessionID).jsonl"
        var matches: [VerifiedRollout] = []
        var visitedEntries = 0

        for directory in candidateDayDirectories(
            for: turns,
            sessionID: sessionID,
            now: now
        ) {
            guard isSafeOwnedDirectory(directory),
                  isDescendant(directory, of: sessionsRoot),
                  let entries = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                  ) else { continue }

            for entry in entries {
                visitedEntries += 1
                guard visitedEntries <= Self.maximumDirectoryEntries else { return nil }
                let name = entry.lastPathComponent
                guard name.hasPrefix("rollout-"), name.hasSuffix(suffix),
                      isDescendant(entry, of: sessionsRoot),
                      let opened = securelyOpenRegularFile(entry) else { continue }
                defer { Darwin.close(opened.descriptor) }
                guard validateSessionMetadata(
                    descriptor: opened.descriptor,
                    fileSize: opened.size,
                    expectedSessionID: sessionID
                ) else { continue }
                matches.append(VerifiedRollout(
                    url: entry.standardizedFileURL,
                    sessionID: sessionID,
                    device: opened.device,
                    inode: opened.inode
                ))
                if matches.count > 1 { return nil }
            }
        }
        return matches.first
    }

    private func candidateDayDirectories(
        for turns: [CodexCancellationObservedTurn],
        sessionID: String,
        now: Date
    ) -> [URL] {
        let requestedStart = turns.map(\.searchStartedAt).min() ?? now
        let boundedStart = max(
            requestedStart,
            calendar.date(byAdding: .day, value: -Self.maximumLookbackDays, to: now) ?? now
        )
        let firstDay = calendar.startOfDay(for: boundedStart)
        let lastDay = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: 1, to: now) ?? now
        )

        var candidateDays = Set<Date>()
        var date = calendar.date(byAdding: .day, value: -1, to: firstDay) ?? firstDay
        while date <= lastDay, candidateDays.count <= Self.maximumLookbackDays + 3 {
            candidateDays.insert(calendar.startOfDay(for: date))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date),
                  next > date else { break }
            date = next
        }

        // Codex keeps appending new turns to the rollout created with the
        // original thread, even months later. Codex session IDs are UUIDv7, so
        // their first 48 bits give that creation day without reading an index
        // database or scanning every historical journal. Include adjacent days
        // for timezone and filename-boundary tolerance, then still require the
        // exact filename suffix and session_meta ID before reading a tail.
        if let createdAt = uuidV7CreationDate(sessionID, now: now) {
            let creationDay = calendar.startOfDay(for: createdAt)
            for offset in -1...1 {
                if let adjacent = calendar.date(
                    byAdding: .day,
                    value: offset,
                    to: creationDay
                ) {
                    candidateDays.insert(calendar.startOfDay(for: adjacent))
                }
            }
        }

        return candidateDays.sorted().compactMap { day in
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day else { return nil }
            return sessionsRoot
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        }
    }

    private func uuidV7CreationDate(_ sessionID: String, now: Date) -> Date? {
        let groups = sessionID.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5,
              groups[0].count == 8,
              groups[1].count == 4,
              groups[2].count == 4,
              groups[3].count == 4,
              groups[4].count == 12,
              groups[2].first == "7",
              let variant = groups[3].first,
              "89aAbB".contains(variant),
              groups.joined().utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57)
                      || (byte >= 65 && byte <= 70)
                      || (byte >= 97 && byte <= 102)
              }),
              let milliseconds = UInt64(String(groups[0] + groups[1]), radix: 16) else {
            return nil
        }
        let createdAt = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        guard createdAt.timeIntervalSince1970.isFinite,
              createdAt <= now.addingTimeInterval(Self.maximumClockSkew) else {
            return nil
        }
        return createdAt
    }

    private func readNewCompleteLines(from resolved: ResolvedRollout) -> [Data]? {
        let rollout = resolved.rollout
        let url = rollout.url
        guard let opened = securelyOpenRegularFile(url) else {
            cursorsByPath.removeValue(forKey: url.path)
            return nil
        }
        guard opened.device == rollout.device, opened.inode == rollout.inode else {
            Darwin.close(opened.descriptor)
            cursorsByPath.removeValue(forKey: url.path)
            return nil
        }
        defer { Darwin.close(opened.descriptor) }

        let old = cursorsByPath[url.path]
        let identityChanged = old.map {
            $0.device != opened.device || $0.inode != opened.inode
        } ?? true
        let wasTruncated = old.map { opened.size < $0.offset } ?? false
        let boundaryChanged: Bool
        if let old, !identityChanged, !wasTruncated {
            guard let matches = cursorBoundaryMatches(old, descriptor: opened.descriptor) else {
                return nil
            }
            boundaryChanged = !matches
        } else {
            boundaryChanged = false
        }

        var cursor: FileCursor
        let byteLimit: Int
        let needsReset = old == nil || identityChanged || wasTruncated || boundaryChanged
        if needsReset {
            if !resolved.metadataValidatedThisScan {
                guard validateSessionMetadata(
                    descriptor: opened.descriptor,
                    fileSize: opened.size,
                    expectedSessionID: resolved.rollout.sessionID
                ) else {
                    verifiedRolloutsBySessionID.removeValue(
                        forKey: resolved.rollout.sessionID
                    )
                    cursorsByPath.removeValue(forKey: url.path)
                    return nil
                }
            }
            let start = max(0, opened.size - off_t(maximumInitialTailBytes))
            cursor = FileCursor(
                device: opened.device,
                inode: opened.inode,
                offset: start,
                partialLine: Data(),
                discardingCurrentLine: start > 0,
                boundaryOffset: 0,
                boundaryData: Data()
            )
            byteLimit = maximumInitialTailBytes
        } else {
            cursor = old!
            byteLimit = maximumIncrementalBytes
            let unread = opened.size - cursor.offset
            if unread > off_t(byteLimit) {
                cursor.offset = max(0, opened.size - off_t(byteLimit))
                cursor.partialLine.removeAll(keepingCapacity: false)
                cursor.discardingCurrentLine = cursor.offset > 0
            }
        }

        guard cursor.offset <= opened.size else { return nil }
        let bytesToRead = min(off_t(byteLimit), opened.size - cursor.offset)
        guard let data = pread(
            descriptor: opened.descriptor,
            offset: cursor.offset,
            count: Int(bytesToRead)
        ) else { return nil }

        cursor.offset += off_t(data.count)
        let lines = consumeCompleteCandidateLines(data, cursor: &cursor)
        guard updateCursorBoundary(&cursor, descriptor: opened.descriptor) else { return nil }
        cursorsByPath[url.path] = cursor
        return lines
    }

    private func validateSessionMetadata(
        descriptor: Int32,
        fileSize: off_t,
        expectedSessionID: String
    ) -> Bool {
        let byteCount = min(maximumSessionMetadataBytes, Int(fileSize))
        guard byteCount > 0,
              let data = pread(descriptor: descriptor, offset: 0, count: byteCount) else {
            return false
        }

        var lineStart = data.startIndex
        while let newline = data[lineStart...].firstIndex(of: 0x0A) {
            let line = data[lineStart..<newline]
            if line.count <= maximumSessionMetadataBytes,
               line.containsASCII("session_meta") {
                guard let envelope = try? JSONDecoder().decode(
                    SessionMetadataEnvelope.self,
                    from: Data(line)
                ) else { return false }
                return envelope.type == "session_meta"
                    && envelope.payload.id == expectedSessionID
            }
            lineStart = data.index(after: newline)
            if lineStart == data.endIndex { break }
        }
        return false
    }

    private func cursorBoundaryMatches(
        _ cursor: FileCursor,
        descriptor: Int32
    ) -> Bool? {
        guard !cursor.boundaryData.isEmpty else { return true }
        guard let current = pread(
            descriptor: descriptor,
            offset: cursor.boundaryOffset,
            count: cursor.boundaryData.count
        ) else { return nil }
        return current == cursor.boundaryData
    }

    private func updateCursorBoundary(
        _ cursor: inout FileCursor,
        descriptor: Int32
    ) -> Bool {
        let markerLength = min(64, Int(cursor.offset))
        cursor.boundaryOffset = cursor.offset - off_t(markerLength)
        guard let marker = pread(
            descriptor: descriptor,
            offset: cursor.boundaryOffset,
            count: markerLength
        ) else { return false }
        cursor.boundaryData = marker
        return true
    }

    private func consumeCompleteCandidateLines(
        _ data: Data,
        cursor: inout FileCursor
    ) -> [Data] {
        var lines: [Data] = []
        for byte in data {
            if byte == 0x0A {
                if !cursor.discardingCurrentLine,
                   !cursor.partialLine.isEmpty,
                   cursor.partialLine.containsASCII("turn_aborted"),
                   cursor.partialLine.containsASCII("interrupted") {
                    lines.append(cursor.partialLine)
                }
                cursor.partialLine.removeAll(keepingCapacity: true)
                cursor.discardingCurrentLine = false
                continue
            }

            guard !cursor.discardingCurrentLine else { continue }
            if cursor.partialLine.count >= maximumCandidateLineBytes {
                cursor.partialLine.removeAll(keepingCapacity: false)
                cursor.discardingCurrentLine = true
                continue
            }
            cursor.partialLine.append(byte)
        }
        return lines
    }

    private func decodeCancellation(from line: Data) -> DecodedCancellation? {
        guard line.count <= maximumCandidateLineBytes,
              line.containsASCII("turn_aborted"),
              line.containsASCII("interrupted"),
              let envelope = try? JSONDecoder().decode(RolloutEnvelope.self, from: line),
              envelope.type == "event_msg",
              envelope.payload.type == "turn_aborted",
              envelope.payload.reason == "interrupted",
              let turnID = envelope.payload.turnID,
              isSafeIdentifier(turnID, maximumBytes: Self.maximumTurnIdentifierBytes),
              let completedAt = envelope.payload.completedAt,
              completedAt.isFinite else { return nil }

        return DecodedCancellation(
            turnID: turnID,
            interruptedAt: Date(timeIntervalSince1970: completedAt)
        )
    }

    private func cache(_ record: CodexCancellationRecord, observedAt: Date) {
        let key = TurnKey(sessionID: record.sessionID, turnID: record.turnID)
        if let existing = cachedCancellationsByTurn[key],
           existing.record.interruptedAt > record.interruptedAt {
            return
        }
        cachedCancellationsByTurn[key] = CachedCancellation(
            record: record,
            observedAt: observedAt
        )
        if cachedCancellationsByTurn.count > Self.maximumCachedCancellations {
            let overflow = cachedCancellationsByTurn.count - Self.maximumCachedCancellations
            let oldestKeys = cachedCancellationsByTurn
                .sorted {
                    if $0.value.observedAt != $1.value.observedAt {
                        return $0.value.observedAt < $1.value.observedAt
                    }
                    return $0.value.record.interruptedAt < $1.value.record.interruptedAt
                }
                .prefix(overflow)
                .map(\.key)
            for key in oldestKeys { cachedCancellationsByTurn.removeValue(forKey: key) }
        }
    }

    private func pruneCancellationCache(now: Date) {
        cachedCancellationsByTurn = cachedCancellationsByTurn.filter {
            now.timeIntervalSince($0.value.observedAt) <= Self.cancellationCacheLifetime
        }
    }

    private func pread(descriptor: Int32, offset: off_t, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        var result = Data()
        result.reserveCapacity(count)
        var position = offset
        var remaining = count
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, count))

        while remaining > 0 {
            let requested = min(buffer.count, remaining)
            let readCount = Darwin.pread(descriptor, &buffer, requested, position)
            if readCount < 0, errno == EINTR { continue }
            guard readCount >= 0 else { return nil }
            if readCount == 0 { break }
            result.append(buffer, count: readCount)
            position += off_t(readCount)
            remaining -= readCount
        }
        return result
    }

    private func securelyOpenRegularFile(_ url: URL) -> OpenedFile? {
        guard isDescendant(url, of: sessionsRoot),
              validatePathComponents(to: url, finalType: S_IFREG) else { return nil }

        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == expectedOwnerID,
              info.st_size >= 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return OpenedFile(
            descriptor: descriptor,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: info.st_size
        )
    }

    private func isSafeOwnedDirectory(_ url: URL) -> Bool {
        validatePathComponents(to: url, finalType: S_IFDIR)
    }

    /// Validates the configured root itself, then every descendant component.
    /// `lstat` rejects symbolic links before any file is opened; the final
    /// `open(... O_NOFOLLOW)` and `fstat` close the final-component race.
    private func validatePathComponents(to url: URL, finalType: mode_t) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.isFileURL, standardized.path.hasPrefix("/") else { return false }

        let paths: [String]
        if standardized.path == sessionsRoot.path {
            paths = [sessionsRoot.path]
        } else {
            guard isDescendant(standardized, of: sessionsRoot) else { return false }
            let relative = String(standardized.path.dropFirst(sessionsRoot.path.count + 1))
            let components = relative.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else {
                return false
            }
            var current = sessionsRoot.path
            paths = [sessionsRoot.path] + components.map { component in
                current += "/\(component)"
                return current
            }
        }

        for (index, path) in paths.enumerated() {
            var info = stat()
            guard Darwin.lstat(path, &info) == 0,
                  info.st_uid == expectedOwnerID else { return false }
            let expectedType: mode_t = index == paths.count - 1 ? finalType : S_IFDIR
            guard (info.st_mode & S_IFMT) == expectedType else { return false }
        }
        return true
    }

    private func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let childPath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return childPath.hasPrefix(rootPath + "/")
    }

    private func pruneCursors(
        keeping paths: Set<String>,
        activeTurnKeys: Set<TurnKey>
    ) {
        cursorsByPath = cursorsByPath.filter { paths.contains($0.key) }
        if deliveredTurnKeys.count > 2_048 {
            // Active turns are bounded by the caller. Retain only keys that can
            // still suppress a replay; a later app relaunch may intentionally
            // rediscover cancellation for a still-persisted stale turn.
            deliveredTurnKeys.formIntersection(activeTurnKeys)
        }
    }

    private struct TurnKey: Hashable {
        let sessionID: String
        let turnID: String
    }

    private struct FileCursor {
        let device: UInt64
        let inode: UInt64
        var offset: off_t
        var partialLine: Data
        var discardingCurrentLine: Bool
        var boundaryOffset: off_t
        var boundaryData: Data
    }

    private struct VerifiedRollout {
        let url: URL
        let sessionID: String
        let device: UInt64
        let inode: UInt64
    }

    private struct ResolvedRollout {
        let rollout: VerifiedRollout
        let metadataValidatedThisScan: Bool
    }

    private struct CachedCancellation {
        let record: CodexCancellationRecord
        let observedAt: Date
    }

    private struct OpenedFile {
        let descriptor: Int32
        let device: UInt64
        let inode: UInt64
        let size: off_t
    }

    private struct DecodedCancellation {
        let turnID: String
        let interruptedAt: Date
    }

    private struct RolloutEnvelope: Decodable {
        let type: String
        let payload: Payload

        struct Payload: Decodable {
            let type: String
            let turnID: String?
            let reason: String?
            let completedAt: TimeInterval?

            private enum CodingKeys: String, CodingKey {
                case type, reason
                case turnID = "turn_id"
                case completedAt = "completed_at"
            }
        }
    }

    private struct SessionMetadataEnvelope: Decodable {
        let type: String
        let payload: Payload

        struct Payload: Decodable {
            let id: String
        }
    }
}

private extension Data {
    func containsASCII(_ value: String) -> Bool {
        let bytes = Data(value.utf8)
        return range(of: bytes) != nil
    }
}
