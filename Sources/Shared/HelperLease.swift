import Darwin
import Foundation

/// Durable phase of the helper's single aggregate keep-awake lease.
///
/// `pending` is written before `pmset` is allowed to change the system. This
/// closes the crash window between the power mutation and the durable record
/// that says the helper owns it. `releasing` similarly makes an interrupted
/// restore retryable on the helper's next launch.
public enum HelperLeasePhase: String, Codable, Equatable {
    case pending
    case active
    case releasing
}

/// The complete crash-recovery record for the privileged helper.
///
/// There is intentionally one record, rather than one file per AI process. The
/// app reduces every active agent/session into one aggregate hold and keeps this
/// lease alive. That gives the root helper a very small and auditable surface.
public struct HelperLeaseJournal: Codable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var leaseID: String
    public var baselineEnabled: Bool
    public var changedByUs: Bool
    public var phase: HelperLeasePhase
    public var bootID: String
    /// Unix epoch seconds.
    public var lastHeartbeat: TimeInterval
    /// Unix epoch seconds. This is an absolute backstop even while heartbeats
    /// continue to arrive.
    public var notAfter: TimeInterval

    public init(schemaVersion: Int = Self.currentSchemaVersion,
                leaseID: String,
                baselineEnabled: Bool,
                changedByUs: Bool,
                phase: HelperLeasePhase,
                bootID: String,
                lastHeartbeat: TimeInterval,
                notAfter: TimeInterval) {
        self.schemaVersion = schemaVersion
        self.leaseID = leaseID
        self.baselineEnabled = baselineEnabled
        self.changedByUs = changedByUs
        self.phase = phase
        self.bootID = bootID
        self.lastHeartbeat = lastHeartbeat
        self.notAfter = notAfter
    }

    /// The record persisted before an acquire is allowed to run `pmset`.
    ///
    /// When the baseline was off, `changedByUs` claims the ensuing 0→1
    /// transaction before it begins. If the helper dies before the command, the
    /// next launch observes that the flag is still off and simply removes the
    /// record. If it dies after the command, the record is already sufficient to
    /// restore normal sleep.
    public static func pending(leaseID: String,
                               baselineEnabled: Bool,
                               bootID: String,
                               now: TimeInterval,
                               notAfter: TimeInterval) -> Self {
        Self(leaseID: leaseID,
             baselineEnabled: baselineEnabled,
             changedByUs: !baselineEnabled,
             phase: .pending,
             bootID: bootID,
             lastHeartbeat: now,
             notAfter: notAfter)
    }

    /// Foundation-only representation safe to send over NSXPC without custom
    /// class whitelists. Booleans and numbers bridge to NSNumber.
    public var stateDictionary: NSDictionary {
        [
            "schemaVersion": schemaVersion,
            "leaseID": leaseID,
            "baselineEnabled": baselineEnabled,
            "changedByUs": changedByUs,
            "phase": phase.rawValue,
            "bootID": bootID,
            "lastHeartbeat": lastHeartbeat,
            "notAfter": notAfter
        ] as NSDictionary
    }
}

/// Request validation shared by the XPC entry points and unit tests.
public enum HelperLeaseRequestValidator {
    public static func error(leaseID: String,
                             notAfter: TimeInterval? = nil,
                             now: TimeInterval) -> String? {
        let trimmed = leaseID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Lease ID must not be empty." }
        guard leaseID.utf8.count <= 256 else { return "Lease ID is too long." }
        guard now.isFinite else { return "The helper clock is invalid." }
        if let notAfter {
            guard notAfter.isFinite else { return "Lease expiry must be finite." }
            guard notAfter > now else { return "Lease expiry must be in the future." }
        }
        return nil
    }
}

/// Why a durable lease must stop holding the Mac awake.
public enum HelperLeaseRecoveryReason: Equatable {
    case incompleteTransaction
    case heartbeatTimedOut
    case expired
    case bootChanged
}

/// Pure recovery policy. It never touches the filesystem or power state.
public enum HelperLeasePolicy {
    public static func recoveryReason(for journal: HelperLeaseJournal,
                                      currentBootID: String,
                                      now: TimeInterval,
                                      heartbeatTimeout: TimeInterval,
                                      atStartup: Bool) -> HelperLeaseRecoveryReason? {
        guard journal.bootID == currentBootID else { return .bootChanged }
        guard journal.phase == .active else { return .incompleteTransaction }
        if now >= journal.notAfter { return .expired }
        if now - journal.lastHeartbeat >= heartbeatTimeout { return .heartbeatTimedOut }
        // A KeepAlive restart of only the helper must not create a momentary
        // sleep window underneath a still-running App/Agent. A same-boot,
        // active, fresh lease is retained and the ordinary watchdog gives the
        // app the remainder of its 90-second heartbeat window to adopt it.
        return nil
    }

    /// Restore only an explicit 0→1 transaction owned by this helper.
    ///
    /// `SleepDisabled` can survive a reboot, so the durable ownership evidence
    /// must survive one too. At early launch the helper reads the live value: if
    /// it is still 1 this record authorizes restoring 0; if macOS already reset
    /// it to 0 no write is needed. A pre-existing baseline 1 is never cleared.
    public static func shouldRestoreSleep(for journal: HelperLeaseJournal) -> Bool {
        journal.changedByUs && !journal.baselineEnabled
    }

    /// Whether recovery must actually issue `pmset ... disablesleep 0` after
    /// reading the current flag. This distinction matters across a reboot:
    /// macOS may have retained 1, or may already have reset it to 0.
    public static func requiresRestoreWrite(for journal: HelperLeaseJournal,
                                            currentlyEnabled: Bool) -> Bool {
        shouldRestoreSleep(for: journal) && currentlyEnabled
    }
}

/// Atomic JSON persistence for the helper's single lease journal.
public struct HelperLeaseJournalStore {
    private static let errorDomain = "LidlessAI.HelperLeaseJournalStore"
    private static let maximumJournalBytes = 1 * 1024 * 1024
    public static let defaultDirectoryURL = URL(
        fileURLWithPath: "/Library/Application Support/com.kenny.lidlessai",
        isDirectory: true
    )
    public static let defaultFileName = "helper-lease.json"

    public let fileURL: URL
    private let fileManager: FileManager
    private let directorySynchronizer: ((URL) throws -> Void)?

    public init(fileURL: URL = Self.defaultDirectoryURL.appendingPathComponent(Self.defaultFileName),
                fileManager: FileManager = .default,
                directorySynchronizer: ((URL) throws -> Void)? = nil) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.directorySynchronizer = directorySynchronizer
    }

    public func load() throws -> HelperLeaseJournal? {
        guard try metadata(at: fileURL) != nil else { return nil }
        let data = try readSecureFile()
        let journal = try Self.makeDecoder().decode(HelperLeaseJournal.self, from: data)
        guard journal.schemaVersion == HelperLeaseJournal.currentSchemaVersion else {
            throw NSError(
                domain: Self.errorDomain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Unsupported helper lease journal schema \(journal.schemaVersion)."]
            )
        }
        return journal
    }

    /// Write a root-owned sibling with `O_NOFOLLOW`, flush it, then atomically
    /// rename it over the journal. The pending record must be durable before the
    /// caller is allowed to change the global power-management flag.
    public func save(_ journal: HelperLeaseJournal) throws {
        let directory = fileURL.deletingLastPathComponent()
        let directoryWasCreated: Bool
        if try metadata(at: directory) == nil {
            directoryWasCreated = true
            let parentDirectory = directory.deletingLastPathComponent()
            try validateDirectory(parentDirectory)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            // The directory entry itself is ownership evidence: if it vanished
            // after a sudden power loss, the journal could vanish with it while
            // SleepDisabled remained 1. Make the parent mutation durable before
            // the caller is allowed to reach pmset.
            try validateDirectory(directory)
            guard Darwin.chmod(directory.path, mode_t(0o700)) == 0 else {
                throw currentPOSIXError()
            }
            try synchronizeDirectory(parentDirectory)
        } else {
            directoryWasCreated = false
        }
        // Validate with lstat before chmod so a substituted directory symlink is
        // rejected without following it and changing an unrelated target.
        try validateDirectory(directory)
        guard Darwin.chmod(directory.path, mode_t(0o700)) == 0 else {
            throw currentPOSIXError()
        }
        let existingJournal = try metadata(at: fileURL)
        if let existingJournal {
            try validateRegularOwnedFile(existingJournal, at: fileURL)
        } else if !directoryWasCreated {
            // An empty directory can be left behind by a prior interrupted or
            // failed first save. Re-prove its parent entry before treating it as
            // durable ownership storage.
            try synchronizeDirectory(directory.deletingLastPathComponent())
        }
        let data = try Self.makeEncoder().encode(journal)
        guard data.count <= Self.maximumJournalBytes else {
            throw storeError(2, "The helper lease journal is unexpectedly large.")
        }
        try writeAtomicallyAndSynchronously(data, directory: directory)
    }

    public func remove() throws {
        guard let existing = try metadata(at: fileURL) else { return }
        try validateRegularOwnedFile(existing, at: fileURL)
        guard Darwin.unlink(fileURL.path) == 0 else { throw currentPOSIXError() }
        try synchronizeDirectory(fileURL.deletingLastPathComponent())
    }

    private func readSecureFile() throws -> Data {
        // The file existed at the caller's first lstat. Disappearing before the
        // secure open is a retryable race, not a permanently malformed journal.
        guard let before = try metadata(at: fileURL) else {
            throw POSIXError(.ENOENT)
        }
        try validateRegularOwnedFile(before, at: fileURL)
        guard before.st_size >= 0,
              before.st_size <= off_t(Self.maximumJournalBytes) else {
            throw storeError(2, "The helper lease journal is unexpectedly large.")
        }

        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(descriptor) }

        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0 else { throw currentPOSIXError() }
        try validateRegularOwnedFile(after, at: fileURL)
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino else {
            throw storeError(3, "The helper lease journal changed while it was being opened.")
        }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw currentPOSIXError()
            }
            guard result.count + count <= Self.maximumJournalBytes else {
                throw storeError(2, "The helper lease journal is unexpectedly large.")
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private func writeAtomicallyAndSynchronously(_ data: Data, directory: URL) throws {
        let temporaryURL = directory.appendingPathComponent(
            ".\(Self.defaultFileName).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw currentPOSIXError() }
        var renamed = false
        defer {
            Darwin.close(descriptor)
            if !renamed { Darwin.unlink(temporaryURL.path) }
        }

        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let baseAddress = bytes.baseAddress else { break }
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard count >= 0 else {
                    if errno == EINTR { continue }
                    throw currentPOSIXError()
                }
                offset += count
            }
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw currentPOSIXError()
        }
        if Darwin.fcntl(descriptor, F_FULLFSYNC) != 0,
           Darwin.fsync(descriptor) != 0 {
            throw currentPOSIXError()
        }

        // Refuse to replace a link or special file even though rename itself
        // would replace the link rather than follow it. This makes unexpected
        // root-path tampering visible instead of silently repairing over it.
        if let existing = try metadata(at: fileURL) {
            try validateRegularOwnedFile(existing, at: fileURL)
        }
        guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
            throw currentPOSIXError()
        }
        renamed = true
        try synchronizeDirectory(directory)
    }

    private func validateDirectory(_ url: URL) throws {
        guard let info = try metadata(at: url), (info.st_mode & S_IFMT) == S_IFDIR else {
            throw storeError(4, "The helper lease directory is not a real directory.")
        }
        guard info.st_uid == geteuid(), (info.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            throw storeError(5, "The helper lease directory has an unsafe owner or permissions.")
        }
    }

    private func validateRegularOwnedFile(_ info: stat, at url: URL) throws {
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw storeError(6, "The helper lease journal is not a regular file: \(url.path)")
        }
        guard info.st_uid == geteuid(),
              (info.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            throw storeError(7, "The helper lease journal has an unsafe owner or permissions.")
        }
    }

    private func metadata(at url: URL) throws -> stat? {
        var info = stat()
        if Darwin.lstat(url.path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw currentPOSIXError()
    }

    private func synchronizeDirectory(_ url: URL) throws {
        if let directorySynchronizer {
            try directorySynchronizer(url)
            return
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw currentPOSIXError() }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid() else {
            throw storeError(4, "The helper lease directory is not a trusted directory.")
        }
        if Darwin.fcntl(descriptor, F_FULLFSYNC) != 0,
           Darwin.fsync(descriptor) != 0 {
            throw currentPOSIXError()
        }
    }

    /// Storage/security failures are intentionally fail-closed, except a file
    /// identity race (code 3), which the watchdog can safely retry.
    static func isPermanentStorageFailure(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == errorDomain && value.code != 3
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func storeError(_ code: Int, _ description: String) -> NSError {
        NSError(
            domain: Self.errorDomain,
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder { JSONDecoder() }
}

/// Environment/configuration keys shared by the launchd entry point and tests.
public enum HelperLeaseRuntime {
    public static let journalPathEnvKey = "LIDLESS_LEASE_JOURNAL_PATH"
    public static let bootIDEnvKey = "LIDLESS_BOOT_ID"

    public static func journalFileURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        guard let path = environment[journalPathEnvKey], !path.isEmpty else {
            return HelperLeaseJournalStore.defaultDirectoryURL
                .appendingPathComponent(HelperLeaseJournalStore.defaultFileName)
        }
        return URL(fileURLWithPath: path)
    }

    /// The kernel boot-session UUID is stable across helper restarts and changes
    /// across reboots. Tests can inject `LIDLESS_BOOT_ID` and avoid shelling out.
    public static func currentBootID(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let injected = environment[bootIDEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !injected.isEmpty {
            return injected
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        process.arguments = ["-n", "kern.bootsessionuuid"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
