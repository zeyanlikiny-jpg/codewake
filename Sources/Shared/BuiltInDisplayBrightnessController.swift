import CoreGraphics
import Darwin
import Foundation

public enum DisplayBrightnessAPIError: Error, Equatable {
    case frameworkUnavailable
    case symbolUnavailable(String)
    case coreGraphicsFailure(CGError)
    case getBrightnessFailed(Int32)
    case setBrightnessFailed(Int32)
    case invalidBrightness
}

/// Injectable boundary around online-display discovery and the three private
/// DisplayServices brightness functions. Production loads the private symbols
/// at runtime, keeping the target free of a private-framework link dependency.
public struct DisplayBrightnessAPI {
    public let onlineDisplayIDs: () throws -> [CGDirectDisplayID]
    public let isBuiltin: (CGDirectDisplayID) -> Bool
    public let canChangeBrightness: (CGDirectDisplayID) throws -> Bool
    public let getBrightness: (CGDirectDisplayID) throws -> Float
    public let setBrightness: (CGDirectDisplayID, Float) throws -> Void

    public init(
        onlineDisplayIDs: @escaping () throws -> [CGDirectDisplayID],
        isBuiltin: @escaping (CGDirectDisplayID) -> Bool,
        canChangeBrightness: @escaping (CGDirectDisplayID) throws -> Bool,
        getBrightness: @escaping (CGDirectDisplayID) throws -> Float,
        setBrightness: @escaping (CGDirectDisplayID, Float) throws -> Void
    ) {
        self.onlineDisplayIDs = onlineDisplayIDs
        self.isBuiltin = isBuiltin
        self.canChangeBrightness = canChangeBrightness
        self.getBrightness = getBrightness
        self.setBrightness = setBrightness
    }

    public static func system() throws -> DisplayBrightnessAPI {
        let library = try DisplayServicesDynamicLibrary()
        return DisplayBrightnessAPI(
            onlineDisplayIDs: {
                var count: UInt32 = 0
                let countResult = CGGetOnlineDisplayList(0, nil, &count)
                guard countResult == .success else {
                    throw DisplayBrightnessAPIError.coreGraphicsFailure(countResult)
                }
                guard count > 0 else { return [] }

                var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
                var populated: UInt32 = 0
                let listResult = CGGetOnlineDisplayList(count, &displays, &populated)
                guard listResult == .success else {
                    throw DisplayBrightnessAPIError.coreGraphicsFailure(listResult)
                }
                return Array(displays.prefix(Int(populated)))
            },
            isBuiltin: { CGDisplayIsBuiltin($0) != 0 },
            canChangeBrightness: { library.canChangeBrightness($0) },
            getBrightness: { displayID in
                var value: Float = 0
                let result = library.getBrightness(displayID, &value)
                guard result == 0 else {
                    throw DisplayBrightnessAPIError.getBrightnessFailed(result)
                }
                guard value.isFinite, (0...1).contains(value) else {
                    throw DisplayBrightnessAPIError.invalidBrightness
                }
                return value
            },
            setBrightness: { displayID, value in
                guard value.isFinite, (0...1).contains(value) else {
                    throw DisplayBrightnessAPIError.invalidBrightness
                }
                let result = library.setBrightness(displayID, value)
                guard result == 0 else {
                    throw DisplayBrightnessAPIError.setBrightnessFailed(result)
                }
            }
        )
    }
}

private final class DisplayServicesDynamicLibrary {
    // The private framework ships no SDK header. Use the integer ABI exposed by
    // the C implementation and normalize it at our public Bool boundary.
    private typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Int32
    private typealias GetBrightness = @convention(c) (
        CGDirectDisplayID,
        UnsafeMutablePointer<Float>
    ) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let handle: UnsafeMutableRawPointer
    private let canChangeBrightnessFunction: CanChangeBrightness
    private let getBrightnessFunction: GetBrightness
    private let setBrightnessFunction: SetBrightness

    init() throws {
        let frameworkPath =
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = Darwin.dlopen(frameworkPath, RTLD_LAZY | RTLD_LOCAL) else {
            throw DisplayBrightnessAPIError.frameworkUnavailable
        }
        self.handle = handle

        do {
            canChangeBrightnessFunction = try Self.loadSymbol(
                "DisplayServicesCanChangeBrightness",
                from: handle,
                as: CanChangeBrightness.self
            )
            getBrightnessFunction = try Self.loadSymbol(
                "DisplayServicesGetBrightness",
                from: handle,
                as: GetBrightness.self
            )
            setBrightnessFunction = try Self.loadSymbol(
                "DisplayServicesSetBrightness",
                from: handle,
                as: SetBrightness.self
            )
        } catch {
            Darwin.dlclose(handle)
            throw error
        }
    }

    deinit {
        Darwin.dlclose(handle)
    }

    func canChangeBrightness(_ displayID: CGDirectDisplayID) -> Bool {
        canChangeBrightnessFunction(displayID) != 0
    }

    func getBrightness(
        _ displayID: CGDirectDisplayID,
        _ value: UnsafeMutablePointer<Float>
    ) -> Int32 {
        getBrightnessFunction(displayID, value)
    }

    func setBrightness(_ displayID: CGDirectDisplayID, _ value: Float) -> Int32 {
        setBrightnessFunction(displayID, value)
    }

    private static func loadSymbol<T>(
        _ name: String,
        from handle: UnsafeMutableRawPointer,
        as type: T.Type
    ) throws -> T {
        guard let symbol = Darwin.dlsym(handle, name) else {
            throw DisplayBrightnessAPIError.symbolUnavailable(name)
        }
        return unsafeBitCast(symbol, to: type)
    }
}

public enum DisplayBlackoutCapability: Error, Equatable {
    case ready(displayID: CGDirectDisplayID)
    case externalDisplayConnected(count: Int)
    case topologyUnknown
    case builtInUnavailable
    case brightnessUnavailable

    public var responseStatus: DisplayBlackoutResponseStatus {
        switch self {
        case .ready: return .ready
        case .externalDisplayConnected: return .externalDisplayConnected
        case .topologyUnknown: return .topologyUnknown
        case .builtInUnavailable: return .builtInUnavailable
        case .brightnessUnavailable: return .brightnessUnavailable
        }
    }
}

public enum DisplayBlackoutExternalDisplayState: Equatable {
    case connected(count: Int)
    case disconnected
    case unknown
}

public struct DisplayBlackoutJournal: Codable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var token: String
    public var generation: UInt64
    public var displayID: CGDirectDisplayID
    public var originalBrightness: Float
    public var phase: DisplayBlackoutJournalPhase
    public var createdAt: TimeInterval
    public var updatedAt: TimeInterval

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        token: String,
        generation: UInt64,
        displayID: CGDirectDisplayID,
        originalBrightness: Float,
        phase: DisplayBlackoutJournalPhase,
        createdAt: TimeInterval,
        updatedAt: TimeInterval
    ) {
        self.schemaVersion = schemaVersion
        self.token = token
        self.generation = generation
        self.displayID = displayID
        self.originalBrightness = originalBrightness
        self.phase = phase
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    fileprivate var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && DisplayBlackoutProtocol.tokenIsValid(token)
            && generation > 0
            && originalBrightness.isFinite
            && (0...1).contains(originalBrightness)
            && createdAt.isFinite
            && updatedAt.isFinite
    }
}

public enum DisplayBlackoutJournalStoreError: Error, Equatable {
    case unsafeDirectory
    case unsafeFile
    case oversized
    case invalidJournal
    case unsupportedSchema(Int)
    case ioFailure(Int32)
}

/// User-owned atomic recovery record. A prepared record is durable before the
/// first brightness write, and restoring is durable before a compare-and-set
/// restore. The direct directory and journal are always 0700/0600 respectively.
public struct DisplayBlackoutJournalStore {
    public static let maximumJournalBytes = 4 * 1024
    public static let defaultFileName = "display-blackout-recovery.json"

    public let fileURL: URL
    private let fileManager: FileManager

    public init(
        fileURL: URL = Self.defaultFileURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/Lidless AI/runtime", isDirectory: true)
            .appendingPathComponent(defaultFileName, isDirectory: false)
    }

    public func load() throws -> DisplayBlackoutJournal? {
        let directory = fileURL.deletingLastPathComponent()
        guard let fileMetadata = try metadata(at: fileURL) else { return nil }
        try validateDirectory(directory, exactPermissions: true)
        try validateFile(fileMetadata)
        guard fileMetadata.st_size >= 0,
              fileMetadata.st_size <= off_t(Self.maximumJournalBytes) else {
            throw DisplayBlackoutJournalStoreError.oversized
        }

        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw currentIOError() }
        defer { Darwin.close(descriptor) }

        var openedMetadata = stat()
        guard Darwin.fstat(descriptor, &openedMetadata) == 0 else { throw currentIOError() }
        try validateFile(openedMetadata)
        guard fileMetadata.st_dev == openedMetadata.st_dev,
              fileMetadata.st_ino == openedMetadata.st_ino else {
            throw DisplayBlackoutJournalStoreError.unsafeFile
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw currentIOError()
            }
            guard data.count + count <= Self.maximumJournalBytes else {
                throw DisplayBlackoutJournalStoreError.oversized
            }
            data.append(buffer, count: count)
        }

        let journal: DisplayBlackoutJournal
        do {
            journal = try JSONDecoder().decode(DisplayBlackoutJournal.self, from: data)
        } catch {
            throw DisplayBlackoutJournalStoreError.invalidJournal
        }
        guard journal.schemaVersion == DisplayBlackoutJournal.currentSchemaVersion else {
            throw DisplayBlackoutJournalStoreError.unsupportedSchema(journal.schemaVersion)
        }
        guard journal.isValid else { throw DisplayBlackoutJournalStoreError.invalidJournal }
        return journal
    }

    public func save(_ journal: DisplayBlackoutJournal) throws {
        guard journal.schemaVersion == DisplayBlackoutJournal.currentSchemaVersion else {
            throw DisplayBlackoutJournalStoreError.unsupportedSchema(journal.schemaVersion)
        }
        guard journal.isValid else { throw DisplayBlackoutJournalStoreError.invalidJournal }

        let directory = fileURL.deletingLastPathComponent()
        try ensurePrivateDirectory(directory)
        if let existing = try metadata(at: fileURL) { try validateFile(existing) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        guard data.count <= Self.maximumJournalBytes else {
            throw DisplayBlackoutJournalStoreError.oversized
        }

        let temporaryURL = directory.appendingPathComponent(
            ".display-blackout-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw currentIOError() }

        var shouldUnlinkTemporary = true
        defer {
            Darwin.close(descriptor)
            if shouldUnlinkTemporary { _ = Darwin.unlink(temporaryURL.path) }
        }

        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw currentIOError()
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw DisplayBlackoutJournalStoreError.invalidJournal
            }
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    bytes.count - written
                )
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw currentIOError()
                }
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw currentIOError() }
        guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
            throw currentIOError()
        }
        shouldUnlinkTemporary = false
        try synchronizeDirectory(directory)
    }

    public func remove() throws {
        guard let existing = try metadata(at: fileURL) else { return }
        try validateDirectory(fileURL.deletingLastPathComponent(), exactPermissions: true)
        try validateFile(existing)
        guard Darwin.unlink(fileURL.path) == 0 else { throw currentIOError() }
        try synchronizeDirectory(fileURL.deletingLastPathComponent())
    }

    private func ensurePrivateDirectory(_ directory: URL) throws {
        let directoryWasCreated: Bool
        if try metadata(at: directory) == nil {
            directoryWasCreated = true
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch let error as POSIXError {
                throw DisplayBlackoutJournalStoreError.ioFailure(error.code.rawValue)
            } catch {
                throw DisplayBlackoutJournalStoreError.ioFailure(EIO)
            }
        } else {
            directoryWasCreated = false
        }
        try validateDirectory(directory, exactPermissions: false)
        guard Darwin.chmod(directory.path, mode_t(0o700)) == 0 else {
            throw currentIOError()
        }
        try validateDirectory(directory, exactPermissions: true)
        if directoryWasCreated {
            try synchronizeDirectory(directory.deletingLastPathComponent())
        }
    }

    private func validateDirectory(_ url: URL, exactPermissions: Bool) throws {
        guard let info = try metadata(at: url),
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == Darwin.geteuid() else {
            throw DisplayBlackoutJournalStoreError.unsafeDirectory
        }
        if exactPermissions, (info.st_mode & 0o777) != 0o700 {
            throw DisplayBlackoutJournalStoreError.unsafeDirectory
        }
    }

    private func validateFile(_ info: stat) throws {
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == Darwin.geteuid(),
              (info.st_mode & 0o777) == 0o600,
              info.st_nlink == 1 else {
            throw DisplayBlackoutJournalStoreError.unsafeFile
        }
    }

    private func metadata(at url: URL) throws -> stat? {
        var info = stat()
        if Darwin.lstat(url.path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw currentIOError()
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw currentIOError() }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw currentIOError() }
    }

    private func currentIOError() -> DisplayBlackoutJournalStoreError {
        .ioFailure(errno)
    }
}

public enum DisplayBlackoutArmResult: Equatable {
    case armed(DisplayBlackoutJournal)
    case alreadyArmed(DisplayBlackoutJournal)
    case blocked(DisplayBlackoutCapability)
    case recoveryPending(DisplayBlackoutCapability, DisplayBlackoutJournal)
}

public enum DisplayBlackoutRestoreResult: Equatable {
    case noJournal
    case restored
    case userAlreadyRestored
    case pending(DisplayBlackoutCapability, DisplayBlackoutJournal)
}

public enum DisplayBlackoutControllerError: Error, Equatable {
    case staleGeneration
    case brightnessMutationFailed
    case brightnessVerificationFailed
    case journalFailure
}

/// Transactional built-in-panel controller. Every display ID passed to a
/// brightness API is first proven built-in. Blackout additionally requires that
/// the online set contains no other endpoint; recovery deliberately permits
/// external endpoints so a newly reappeared built-in panel can still be fixed.
public struct BuiltInDisplayBrightnessController {
    public static let blackoutBrightness: Float = 0
    public static let blackoutThreshold: Float = 0.01
    public static let restoreTolerance: Float = 0.02

    public let api: DisplayBrightnessAPI

    public init(api: DisplayBrightnessAPI) {
        self.api = api
    }

    public static func system() throws -> BuiltInDisplayBrightnessController {
        BuiltInDisplayBrightnessController(api: try .system())
    }

    public func blackoutCapability() -> DisplayBlackoutCapability {
        switch topology() {
        case .failure(let capability):
            return capability
        case .success(let displays):
            guard displays.external.isEmpty else {
                return .externalDisplayConnected(count: displays.external.count)
            }
            guard displays.builtin.count == 1, let displayID = displays.builtin.first else {
                return .builtInUnavailable
            }
            do {
                guard try api.canChangeBrightness(displayID) else {
                    return .brightnessUnavailable
                }
            } catch {
                return .brightnessUnavailable
            }
            return .ready(displayID: displayID)
        }
    }

    /// Independent hot-plug check used by the watchdog after the panel is
    /// already black. An empty/failed query is unknown, never proof that no
    /// external display exists. Only a positively identified non-built-in
    /// endpoint triggers the external-display recovery path.
    public func externalDisplayState() -> DisplayBlackoutExternalDisplayState {
        switch topology() {
        case .failure:
            return .unknown
        case .success(let displays):
            guard !displays.external.isEmpty else { return .disconnected }
            return .connected(count: displays.external.count)
        }
    }

    public func arm(
        token: String,
        generation: UInt64,
        journalStore: DisplayBlackoutJournalStore,
        now: TimeInterval = Date().timeIntervalSince1970
    ) throws -> DisplayBlackoutArmResult {
        guard DisplayBlackoutProtocol.tokenIsValid(token), generation > 0, now.isFinite else {
            throw DisplayBlackoutControllerError.journalFailure
        }

        if let existing = try translatedJournalLoad(journalStore) {
            if existing.token == token,
               existing.generation == generation,
               existing.phase == .armed {
                return .alreadyArmed(existing)
            }
            switch try restoreIfNeeded(journalStore: journalStore, now: now) {
            case .noJournal, .restored, .userAlreadyRestored:
                break
            case .pending(let capability, let journal):
                return .recoveryPending(capability, journal)
            }
        }

        let capability = blackoutCapability()
        guard case .ready(let displayID) = capability else {
            return .blocked(capability)
        }

        let originalBrightness: Float
        do {
            originalBrightness = try api.getBrightness(displayID)
        } catch {
            return .blocked(.brightnessUnavailable)
        }
        guard originalBrightness.isFinite, (0...1).contains(originalBrightness) else {
            return .blocked(.brightnessUnavailable)
        }

        var journal = DisplayBlackoutJournal(
            token: token,
            generation: generation,
            displayID: displayID,
            originalBrightness: originalBrightness,
            phase: .prepared,
            createdAt: now,
            updatedAt: now
        )
        try translatedJournalSave(journal, to: journalStore)

        // Close the click-to-write hot-plug window as far as the public APIs
        // allow: re-query independently after the recovery record is durable and
        // immediately before writing. A changed display ID is also rejected.
        let recheckedCapability = blackoutCapability()
        guard case .ready(let recheckedID) = recheckedCapability else {
            try translatedJournalRemove(journalStore)
            return .blocked(recheckedCapability)
        }
        guard recheckedID == displayID else {
            try translatedJournalRemove(journalStore)
            return .blocked(.builtInUnavailable)
        }

        do {
            try api.setBrightness(displayID, Self.blackoutBrightness)
            let readback = try api.getBrightness(displayID)
            guard readback.isFinite, readback <= Self.blackoutThreshold else {
                throw DisplayBlackoutControllerError.brightnessVerificationFailed
            }
        } catch {
            journal.phase = .restoring
            journal.updatedAt = now
            try? journalStore.save(journal)
            _ = try? restoreIfNeeded(journalStore: journalStore, now: now)
            if error is DisplayBlackoutControllerError {
                throw error
            }
            throw DisplayBlackoutControllerError.brightnessMutationFailed
        }

        journal.phase = .armed
        journal.updatedAt = now
        do {
            try journalStore.save(journal)
        } catch {
            _ = try? restoreIfNeeded(journalStore: journalStore, now: now)
            throw DisplayBlackoutControllerError.journalFailure
        }
        return .armed(journal)
    }

    public func restoreIfNeeded(
        journalStore: DisplayBlackoutJournalStore,
        matchingToken: String? = nil,
        generation: UInt64? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) throws -> DisplayBlackoutRestoreResult {
        guard var journal = try translatedJournalLoad(journalStore) else {
            return .noJournal
        }
        if let matchingToken,
           let generation,
           (journal.token != matchingToken || journal.generation != generation) {
            throw DisplayBlackoutControllerError.staleGeneration
        }

        if journal.phase != .restoring {
            journal.phase = .restoring
            journal.updatedAt = now
            try translatedJournalSave(journal, to: journalStore)
        }

        let restoreTarget: CGDirectDisplayID
        switch topology() {
        case .failure(let capability):
            return .pending(capability, journal)
        case .success(let displays):
            guard displays.builtin.count == 1, let displayID = displays.builtin.first else {
                return .pending(.builtInUnavailable, journal)
            }
            restoreTarget = displayID
        }

        do {
            guard try api.canChangeBrightness(restoreTarget) else {
                return .pending(.brightnessUnavailable, journal)
            }
            let currentBrightness = try api.getBrightness(restoreTarget)
            guard currentBrightness.isFinite, (0...1).contains(currentBrightness) else {
                return .pending(.brightnessUnavailable, journal)
            }

            // A brightness key is the user's escape hatch. Once the panel is no
            // longer near our zero value, never overwrite the user's choice.
            if currentBrightness > Self.blackoutThreshold {
                try translatedJournalRemove(journalStore)
                return .userAlreadyRestored
            }

            try api.setBrightness(restoreTarget, journal.originalBrightness)
            let readback = try api.getBrightness(restoreTarget)
            guard readback.isFinite,
                  abs(readback - journal.originalBrightness) <= Self.restoreTolerance else {
                return .pending(.brightnessUnavailable, journal)
            }
        } catch {
            return .pending(.brightnessUnavailable, journal)
        }

        try translatedJournalRemove(journalStore)
        return .restored
    }

    private func topology() -> Result<DisplaySets, DisplayBlackoutCapability> {
        let rawDisplayIDs: [CGDirectDisplayID]
        do {
            rawDisplayIDs = try api.onlineDisplayIDs()
        } catch {
            return .failure(.topologyUnknown)
        }
        guard !rawDisplayIDs.isEmpty else { return .failure(.topologyUnknown) }

        var seen = Set<CGDirectDisplayID>()
        let displayIDs = rawDisplayIDs.filter { seen.insert($0).inserted }
        let builtin = displayIDs.filter(api.isBuiltin)
        let external = displayIDs.filter { !api.isBuiltin($0) }
        return .success(DisplaySets(builtin: builtin, external: external))
    }

    private func translatedJournalLoad(
        _ store: DisplayBlackoutJournalStore
    ) throws -> DisplayBlackoutJournal? {
        do { return try store.load() }
        catch { throw DisplayBlackoutControllerError.journalFailure }
    }

    private func translatedJournalSave(
        _ journal: DisplayBlackoutJournal,
        to store: DisplayBlackoutJournalStore
    ) throws {
        do { try store.save(journal) }
        catch { throw DisplayBlackoutControllerError.journalFailure }
    }

    private func translatedJournalRemove(_ store: DisplayBlackoutJournalStore) throws {
        do { try store.remove() }
        catch { throw DisplayBlackoutControllerError.journalFailure }
    }

    private struct DisplaySets {
        let builtin: [CGDirectDisplayID]
        let external: [CGDirectDisplayID]
    }
}
