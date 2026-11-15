import Darwin
import Foundation

private struct HookConfigurationFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64

    init(_ information: stat) {
        device = UInt64(bitPattern: Int64(information.st_dev))
        inode = UInt64(information.st_ino)
        size = Int64(information.st_size)
        modificationSeconds = Int64(information.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(information.st_mtimespec.tv_nsec)
    }
}

private struct HookConfigurationSnapshot {
    let data: Data?
    let permissions: NSNumber?
    let identity: HookConfigurationFileIdentity?

    static let missing = HookConfigurationSnapshot(
        data: nil,
        permissions: nil,
        identity: nil
    )
}

/// Performs the small, transactional file-system layer around
/// `HookConfigurationEditor`. All JSON is parsed and conflict-checked before a
/// backup, executable copy, or configuration write occurs.
final class HookIntegrationInstaller {
    static let maximumConfigurationFileBytes = 2 * 1024 * 1024

    let homeDirectory: URL
    let bridgeSourceURL: URL?
    let appBundleIdentifier: String

    private let fileManager: FileManager
    /// Deterministic race seam used by tests. Production leaves it nil; the
    /// actual protection is the destination identity check at commit time.
    private let beforeConfigurationCommit: (() -> Void)?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bridgeSourceURL: URL? = Bundle.main.url(forAuxiliaryExecutable: HookIntegrationPaths.bridgeExecutableName),
        appBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default,
        beforeConfigurationCommit: (() -> Void)? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.bridgeSourceURL = bridgeSourceURL
        self.appBundleIdentifier = HookIntegrationPaths.normalizedAppBundleIdentifier(appBundleIdentifier)
        self.fileManager = fileManager
        self.beforeConfigurationCommit = beforeConfigurationCommit
    }

    var bridgeURL: URL {
        HookIntegrationPaths.bridgeURL(homeDirectory: homeDirectory)
    }

    func health(for provider: HookProvider) -> HookIntegrationHealth {
        if provider == .codex {
            return codexHealth().integration
        }

        let configurationURL = provider.configurationURL(homeDirectory: homeDirectory)
        var state: HookIntegrationHealthState
        do {
            let snapshot = try configurationSnapshot(at: configurationURL)
            state = HookConfigurationEditor.health(
                of: snapshot.data,
                provider: provider,
                appBundleIdentifier: appBundleIdentifier,
                homeDirectory: homeDirectory
            )
        } catch {
            state = .invalidConfiguration
        }
        if provider == .paseo, state == .installed {
            state = paseoPluginFilesHealth()
        }
        if state == .installed {
            if !isExecutableRegularFile(at: bridgeURL) {
                state = .bridgeMissing
            } else if !installedBridgeMatchesBundledSource() {
                state = .needsRepair
            }
        }
        return HookIntegrationHealth(
            provider: provider,
            state: state,
            configurationURL: configurationURL,
            bridgeURL: bridgeURL
        )
    }

    /// Reads Codex hooks and completion notify independently, then applies the
    /// bundled-Bridge identity check once. The strict aggregate health preserves
    /// the existing Settings/repair contract, while callers can separately use
    /// canonical hooks + current Bridge as activity-event evidence.
    func codexHealth() -> CodexIntegrationHealth {
        let configurationURL = HookProvider.codex.configurationURL(
            homeDirectory: homeDirectory
        )
        let hookState: HookIntegrationHealthState
        do {
            let snapshot = try configurationSnapshot(at: configurationURL)
            hookState = HookConfigurationEditor.health(
                of: snapshot.data,
                provider: .codex,
                appBundleIdentifier: appBundleIdentifier
            )
        } catch {
            hookState = .invalidConfiguration
        }

        let notifyState: HookIntegrationHealthState
        do {
            let snapshot = try configurationSnapshot(
                at: HookIntegrationPaths.codexConfigurationURL(homeDirectory: homeDirectory)
            )
            notifyState = CodexNotifyConfigurationEditor.health(
                of: snapshot.data,
                homeDirectory: homeDirectory,
                appBundleIdentifier: appBundleIdentifier
            )
        } catch {
            notifyState = .invalidConfiguration
        }

        let bridgeIsExecutable = isExecutableRegularFile(at: bridgeURL)
        let bridgeMatches = bridgeIsExecutable && installedBridgeMatchesBundledSource()
        var overallState = combinedHealth(hooks: hookState, notify: notifyState)
        if overallState == .installed {
            if !bridgeIsExecutable {
                overallState = .bridgeMissing
            } else if !bridgeMatches {
                overallState = .needsRepair
            }
        }

        return CodexIntegrationHealth(
            integration: HookIntegrationHealth(
                provider: .codex,
                state: overallState,
                configurationURL: configurationURL,
                bridgeURL: bridgeURL
            ),
            hookConfigurationState: hookState,
            completionNotifyConfigurationState: notifyState,
            installedBridgeMatchesBundledSource: bridgeMatches
        )
    }

    @discardableResult
    func install(_ provider: HookProvider) throws -> HookIntegrationChange {
        let configurationURL = provider.configurationURL(homeDirectory: homeDirectory)
        let original = try configurationSnapshot(at: configurationURL)

        // Preflight both the JSON mutation and executable before touching disk.
        let edit = try HookConfigurationEditor.installing(
            in: original.data,
            provider: provider,
            appBundleIdentifier: appBundleIdentifier,
            homeDirectory: homeDirectory
        )
        let paseoPluginNeedsWrite = try provider == .paseo
            ? preflightPaseoPluginInstall()
            : false
        let notifyConfigurationURL = HookIntegrationPaths.codexConfigurationURL(
            homeDirectory: homeDirectory
        )
        let notifyOriginal: HookConfigurationSnapshot?
        let notifyEdit: HookConfigurationEdit?
        if provider == .codex {
            let snapshot = try configurationSnapshot(at: notifyConfigurationURL)
            notifyOriginal = snapshot
            notifyEdit = try CodexNotifyConfigurationEditor.installing(
                in: snapshot.data,
                homeDirectory: homeDirectory,
                appBundleIdentifier: appBundleIdentifier
            )
        } else {
            notifyOriginal = nil
            notifyEdit = nil
        }
        guard let bridgeSourceURL else { throw HookIntegrationError.bridgeExecutableMissing }
        guard isExecutableRegularFile(at: bridgeSourceURL) else {
            throw HookIntegrationError.unsafeBridgeSource
        }

        let shouldInstallBridge = !isExecutableRegularFile(at: bridgeURL)
            || !regularFilesHaveEqualContents(bridgeSourceURL, bridgeURL)
        if edit.changed {
            try validateConfigurationDestination(configurationURL, matches: original)
        }
        if notifyEdit?.changed == true, let notifyOriginal {
            try validateConfigurationDestination(notifyConfigurationURL, matches: notifyOriginal)
        }
        let backupURL = try edit.changed
            ? backupIfPresent(original, configurationURL: configurationURL)
            : nil
        let notifyBackupURL = try notifyEdit?.changed == true
            ? notifyOriginal.flatMap {
                try backupIfPresent($0, configurationURL: notifyConfigurationURL)
            }
            : nil

        if shouldInstallBridge {
            try installBridge(from: bridgeSourceURL)
        }
        if paseoPluginNeedsWrite {
            try installPaseoPluginFiles()
        }
        if edit.changed {
            try validateConfigurationDestination(configurationURL, matches: original)
            try writeConfiguration(
                edit.data,
                to: configurationURL,
                replacing: original
            )
        }
        if let notifyEdit, notifyEdit.changed, let notifyOriginal {
            try commitConfigurationEdit(
                notifyEdit,
                to: notifyConfigurationURL,
                replacing: notifyOriginal
            )
        }

        return HookIntegrationChange(
            provider: provider,
            configurationChanged: edit.changed || paseoPluginNeedsWrite,
            bridgeChanged: shouldInstallBridge,
            backupURL: backupURL,
            notifyConfigurationChanged: notifyEdit?.changed == true,
            notifyBackupURL: notifyBackupURL
        )
    }

    @discardableResult
    func uninstall(_ provider: HookProvider) throws -> HookIntegrationChange {
        let configurationURL = provider.configurationURL(homeDirectory: homeDirectory)
        let original = try configurationSnapshot(at: configurationURL)
        let edit = try HookConfigurationEditor.uninstalling(
            from: original.data,
            provider: provider,
            appBundleIdentifier: appBundleIdentifier,
            homeDirectory: homeDirectory
        )
        if provider == .paseo {
            try preflightPaseoPluginUninstall()
        }
        let notifyConfigurationURL = HookIntegrationPaths.codexConfigurationURL(
            homeDirectory: homeDirectory
        )
        let notifyOriginal: HookConfigurationSnapshot?
        let notifyEdit: HookConfigurationEdit?
        if provider == .codex {
            let snapshot = try configurationSnapshot(at: notifyConfigurationURL)
            notifyOriginal = snapshot
            notifyEdit = try CodexNotifyConfigurationEditor.uninstalling(
                from: snapshot.data,
                homeDirectory: homeDirectory,
                appBundleIdentifier: appBundleIdentifier
            )
        } else {
            notifyOriginal = nil
            notifyEdit = nil
        }
        if edit.changed {
            try validateConfigurationDestination(configurationURL, matches: original)
        }
        let backupURL = try edit.changed
            ? backupIfPresent(original, configurationURL: configurationURL)
            : nil
        let notifyBackupURL = try notifyEdit?.changed == true
            ? notifyOriginal.flatMap {
                try backupIfPresent($0, configurationURL: notifyConfigurationURL)
            }
            : nil

        if edit.changed {
            try validateConfigurationDestination(configurationURL, matches: original)
            if edit.data.isEmpty {
                beforeConfigurationCommit?()
                try validateConfigurationDestination(configurationURL, matches: original)
                guard Darwin.unlink(configurationURL.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                try synchronizeDirectory(configurationURL.deletingLastPathComponent())
            } else {
                try writeConfiguration(
                    edit.data,
                    to: configurationURL,
                    replacing: original
                )
            }
        }
        if let notifyEdit, notifyEdit.changed, let notifyOriginal {
            try commitConfigurationEdit(
                notifyEdit,
                to: notifyConfigurationURL,
                replacing: notifyOriginal
            )
        }
        let paseoPluginRemoved = try provider == .paseo
            ? removePaseoPluginFilesIfPresent()
            : false

        let bridgeRemoved = try removeBridgeIfUnused()
        return HookIntegrationChange(
            provider: provider,
            configurationChanged: edit.changed || paseoPluginRemoved,
            bridgeChanged: bridgeRemoved,
            backupURL: backupURL,
            notifyConfigurationChanged: notifyEdit?.changed == true,
            notifyBackupURL: notifyBackupURL
        )
    }

    private func combinedHealth(
        hooks: HookIntegrationHealthState,
        notify: HookIntegrationHealthState
    ) -> HookIntegrationHealthState {
        if hooks == .conflict || notify == .conflict { return .conflict }
        if hooks == .invalidConfiguration || notify == .invalidConfiguration {
            return .invalidConfiguration
        }
        if hooks == .installed, notify == .installed { return .installed }
        if hooks == .notInstalled, notify == .notInstalled { return .notInstalled }
        return .needsRepair
    }

    /// Opens hook configuration without following links and never performs an
    /// unbounded Foundation read. `O_NONBLOCK` is intentional: even if a path
    /// is exchanged for a FIFO between `lstat` and `open`, this call cannot wait
    /// indefinitely for a writer.
    private func configurationSnapshot(at url: URL) throws -> HookConfigurationSnapshot {
        var pathInformation = stat()
        guard lstat(url.path, &pathInformation) == 0 else {
            if errno == ENOENT { return .missing }
            throw HookIntegrationError.configurationReadFailed
        }
        guard (pathInformation.st_mode & S_IFMT) == S_IFREG else {
            throw HookIntegrationError.unsafeConfigurationFile
        }
        try validateConfigurationSize(pathInformation.st_size)

        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw errno == ELOOP
                ? HookIntegrationError.unsafeConfigurationFile
                : HookIntegrationError.configurationReadFailed
        }
        defer { Darwin.close(descriptor) }

        var openedInformation = stat()
        guard fstat(descriptor, &openedInformation) == 0 else {
            throw HookIntegrationError.configurationReadFailed
        }
        guard (openedInformation.st_mode & S_IFMT) == S_IFREG else {
            throw HookIntegrationError.unsafeConfigurationFile
        }
        try validateConfigurationSize(openedInformation.st_size)
        guard HookConfigurationFileIdentity(pathInformation)
            == HookConfigurationFileIdentity(openedInformation) else {
            throw HookIntegrationError.configurationChangedDuringRead
        }

        let data = try readBoundedConfiguration(from: descriptor)

        var completedInformation = stat()
        guard fstat(descriptor, &completedInformation) == 0 else {
            throw HookIntegrationError.configurationReadFailed
        }
        try validateConfigurationSize(completedInformation.st_size)
        let completedIdentity = HookConfigurationFileIdentity(completedInformation)
        guard completedIdentity == HookConfigurationFileIdentity(openedInformation) else {
            throw HookIntegrationError.configurationChangedDuringRead
        }

        var finalPathInformation = stat()
        guard lstat(url.path, &finalPathInformation) == 0,
              (finalPathInformation.st_mode & S_IFMT) == S_IFREG,
              HookConfigurationFileIdentity(finalPathInformation) == completedIdentity else {
            throw HookIntegrationError.configurationChangedDuringRead
        }

        return HookConfigurationSnapshot(
            data: data,
            permissions: NSNumber(value: Int(completedInformation.st_mode & 0o777)),
            identity: completedIdentity
        )
    }

    private func validateConfigurationSize(_ size: off_t) throws {
        guard size >= 0 else { throw HookIntegrationError.unsafeConfigurationFile }
        guard size <= Self.maximumConfigurationFileBytes else {
            throw HookIntegrationError.configurationTooLarge
        }
    }

    private func readBoundedConfiguration(from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            let remaining = Self.maximumConfigurationFileBytes + 1 - data.count
            guard remaining > 0 else { throw HookIntegrationError.configurationTooLarge }
            let requestedCount = min(buffer.count, remaining)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requestedCount)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(Int(count)))
                if data.count > Self.maximumConfigurationFileBytes {
                    throw HookIntegrationError.configurationTooLarge
                }
                continue
            }
            if count == 0 { return data }
            if errno == EINTR { continue }
            throw HookIntegrationError.configurationReadFailed
        }
    }

    private func validateConfigurationDestination(
        _ url: URL,
        matches snapshot: HookConfigurationSnapshot
    ) throws {
        var information = stat()
        if let identity = snapshot.identity {
            guard lstat(url.path, &information) == 0 else {
                throw HookIntegrationError.configurationChangedDuringRead
            }
            guard (information.st_mode & S_IFMT) == S_IFREG else {
                throw HookIntegrationError.unsafeConfigurationFile
            }
            guard HookConfigurationFileIdentity(information) == identity else {
                throw HookIntegrationError.configurationChangedDuringRead
            }
            return
        }

        guard lstat(url.path, &information) != 0, errno == ENOENT else {
            throw HookIntegrationError.configurationChangedDuringRead
        }
    }

    private func backupIfPresent(
        _ snapshot: HookConfigurationSnapshot,
        configurationURL: URL
    ) throws -> URL? {
        guard let data = snapshot.data else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = URL(
            fileURLWithPath: configurationURL.path
                + ".lidless-ai-backup-\(stamp)-\(UUID().uuidString)"
        )
        // Create at 0600 from the first inode-visible moment. Writing first and
        // chmodding afterwards can expose the complete private hook settings if
        // the process crashes between those operations under a permissive umask.
        try writeExclusivePrivateFile(data, to: backupURL)
        return backupURL
    }

    private func writeExclusivePrivateFile(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var complete = false
        defer {
            Darwin.close(descriptor)
            if !complete { _ = Darwin.unlink(url.path) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        complete = true
    }

    private func installedBridgeMatchesBundledSource() -> Bool {
        guard let bridgeSourceURL,
              isExecutableRegularFile(at: bridgeSourceURL) else { return false }
        return regularFilesHaveEqualContents(bridgeSourceURL, bridgeURL)
    }

    private func regularFilesHaveEqualContents(_ leftURL: URL, _ rightURL: URL) -> Bool {
        guard let left = openRegularFileForComparison(leftURL),
              let right = openRegularFileForComparison(rightURL) else { return false }
        defer {
            Darwin.close(left.descriptor)
            Darwin.close(right.descriptor)
        }
        guard left.size == right.size else { return false }

        var leftBuffer = [UInt8](repeating: 0, count: 32 * 1024)
        var rightBuffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            guard let leftCount = readComparisonChunk(left.descriptor, into: &leftBuffer),
                  let rightCount = readComparisonChunk(right.descriptor, into: &rightBuffer),
                  leftCount == rightCount else { return false }
            if leftCount == 0 { return true }
            guard leftBuffer.prefix(leftCount).elementsEqual(rightBuffer.prefix(rightCount)) else {
                return false
            }
        }
    }

    private func openRegularFileForComparison(_ url: URL) -> (descriptor: Int32, size: off_t)? {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { return nil }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            return nil
        }
        return (descriptor, information.st_size)
    }

    private func readComparisonChunk(
        _ descriptor: Int32,
        into buffer: inout [UInt8]
    ) -> Int? {
        while true {
            let capacity = buffer.count
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, capacity)
            }
            if count >= 0 { return Int(count) }
            if errno != EINTR { return nil }
        }
    }

    private func writeConfiguration(
        _ data: Data,
        to url: URL,
        replacing original: HookConfigurationSnapshot
    ) throws {
        let directory = url.deletingLastPathComponent()
        try createPrivateDirectoryIfNeeded(directory)

        let permissions = mode_t((original.permissions?.uintValue ?? 0o600) & 0o777)
        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).lidless-ai-\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            permissions
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var renamed = false
        defer {
            Darwin.close(descriptor)
            if !renamed { _ = Darwin.unlink(temporaryURL.path) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        guard Darwin.fchmod(descriptor, permissions) == 0,
              Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Creating/fsyncing the replacement can take long enough for the Agent
        // itself to update hooks.json/settings.json. Re-check the exact original
        // inode/size/mtime immediately before the atomic rename so we fail with
        // a repair instruction instead of silently overwriting that newer data.
        beforeConfigurationCommit?()
        try validateConfigurationDestination(url, matches: original)
        guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        renamed = true
        try synchronizeDirectory(directory)
    }

    private func commitConfigurationEdit(
        _ edit: HookConfigurationEdit,
        to url: URL,
        replacing original: HookConfigurationSnapshot
    ) throws {
        try validateConfigurationDestination(url, matches: original)
        if edit.data.isEmpty {
            beforeConfigurationCommit?()
            try validateConfigurationDestination(url, matches: original)
            guard Darwin.unlink(url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try synchronizeDirectory(url.deletingLastPathComponent())
        } else {
            try writeConfiguration(edit.data, to: url, replacing: original)
        }
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFDIR,
              Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func installBridge(from sourceURL: URL) throws {
        let directory = bridgeURL.deletingLastPathComponent()
        try createPrivateDirectoryIfNeeded(directory)
        let executableData = try Data(contentsOf: sourceURL)
        try executableData.write(to: bridgeURL, options: .atomic)
        guard Darwin.chmod(bridgeURL.path, 0o755) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func createPrivateDirectoryIfNeeded(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Tighten directories created by an older build; never follow a symlink.
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard Darwin.chmod(url.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func removeBridgeIfUnused() throws -> Bool {
        for provider in HookProvider.allCases {
            let url = provider.configurationURL(homeDirectory: homeDirectory)
            // An unsafe, oversized, unreadable, or concurrently changing
            // configuration may still contain a live bridge reference. Keep
            // the executable rather than breaking it.
            guard let snapshot = try? configurationSnapshot(at: url) else { return false }
            switch HookConfigurationEditor.health(
                of: snapshot.data,
                provider: provider,
                appBundleIdentifier: appBundleIdentifier,
                homeDirectory: homeDirectory
            ) {
            case .installed, .needsRepair, .bridgeMissing, .invalidConfiguration, .conflict:
                return false
            case .notInstalled:
                continue
            }
        }
        let notifyURL = HookIntegrationPaths.codexConfigurationURL(homeDirectory: homeDirectory)
        // An unreadable config might still launch the relay; retain the binary.
        guard let notifySnapshot = try? configurationSnapshot(at: notifyURL) else { return false }
        switch CodexNotifyConfigurationEditor.health(
            of: notifySnapshot.data,
            homeDirectory: homeDirectory,
            appBundleIdentifier: appBundleIdentifier
        ) {
        case .installed, .needsRepair, .bridgeMissing, .invalidConfiguration, .conflict:
            return false
        case .notInstalled:
            break
        }
        guard fileManager.fileExists(atPath: bridgeURL.path) else { return false }
        guard isRegularFile(at: bridgeURL) else { return false }
        try fileManager.removeItem(at: bridgeURL)
        return true
    }

    // MARK: Paseo Managed Plugin Files & Live Daemon Sync

    private func paseoPluginFilesHealth() -> HookIntegrationHealthState {
        let directory = HookIntegrationPaths.paseoPluginDirectory(homeDirectory: homeDirectory)
        var dirInfo = stat()
        guard lstat(directory.path, &dirInfo) == 0 else {
            return errno == ENOENT ? .needsRepair : .invalidConfiguration
        }
        guard (dirInfo.st_mode & S_IFMT) == S_IFDIR else {
            return .invalidConfiguration
        }

        let manifestURL = HookIntegrationPaths.paseoPluginManifestURL(homeDirectory: homeDirectory)
        let entryURL = HookIntegrationPaths.paseoPluginServerEntryURL(homeDirectory: homeDirectory)
        let manifestSnapshot: HookConfigurationSnapshot
        let entrySnapshot: HookConfigurationSnapshot
        do {
            manifestSnapshot = try configurationSnapshot(at: manifestURL)
            entrySnapshot = try configurationSnapshot(at: entryURL)
        } catch {
            return .invalidConfiguration
        }

        if let entryData = entrySnapshot.data,
           paseoPluginEntryBelongsToOtherAppBundle(entryData) {
            return .conflict
        }

        let expectedManifest = HookIntegrationPaths.paseoPluginManifestData()
        let expectedEntry = HookIntegrationPaths.paseoPluginServerEntryData(
            homeDirectory: homeDirectory,
            appBundleIdentifier: appBundleIdentifier
        )
        guard manifestSnapshot.data == expectedManifest,
              entrySnapshot.data == expectedEntry else {
            return .needsRepair
        }
        return .installed
    }

    private func preflightPaseoPluginInstall() throws -> Bool {
        let directory = HookIntegrationPaths.paseoPluginDirectory(homeDirectory: homeDirectory)
        var dirInfo = stat()
        if lstat(directory.path, &dirInfo) == 0 {
            guard (dirInfo.st_mode & S_IFMT) == S_IFDIR else {
                throw HookIntegrationError.unsafeConfigurationFile
            }
        } else if errno != ENOENT {
            throw HookIntegrationError.configurationReadFailed
        }

        let manifestURL = HookIntegrationPaths.paseoPluginManifestURL(homeDirectory: homeDirectory)
        let entryURL = HookIntegrationPaths.paseoPluginServerEntryURL(homeDirectory: homeDirectory)
        let manifestSnapshot = try configurationSnapshot(at: manifestURL)
        let entrySnapshot = try configurationSnapshot(at: entryURL)
        if let entryData = entrySnapshot.data,
           paseoPluginEntryBelongsToOtherAppBundle(entryData) {
            throw HookIntegrationError.conflictingBridgeCommand(
                HookIntegrationPaths.paseoPluginIdentifier
            )
        }

        let expectedManifest = HookIntegrationPaths.paseoPluginManifestData()
        let expectedEntry = HookIntegrationPaths.paseoPluginServerEntryData(
            homeDirectory: homeDirectory,
            appBundleIdentifier: appBundleIdentifier
        )
        return manifestSnapshot.data != expectedManifest || entrySnapshot.data != expectedEntry
    }

    private func preflightPaseoPluginUninstall() throws {
        let directory = HookIntegrationPaths.paseoPluginDirectory(homeDirectory: homeDirectory)
        var dirInfo = stat()
        if lstat(directory.path, &dirInfo) == 0 {
            guard (dirInfo.st_mode & S_IFMT) == S_IFDIR else {
                throw HookIntegrationError.unsafeConfigurationFile
            }
        } else if errno != ENOENT {
            throw HookIntegrationError.configurationReadFailed
        }

        let manifestURL = HookIntegrationPaths.paseoPluginManifestURL(homeDirectory: homeDirectory)
        let entryURL = HookIntegrationPaths.paseoPluginServerEntryURL(homeDirectory: homeDirectory)
        _ = try configurationSnapshot(at: manifestURL)
        let entrySnapshot = try configurationSnapshot(at: entryURL)
        if let entryData = entrySnapshot.data,
           paseoPluginEntryBelongsToOtherAppBundle(entryData) {
            throw HookIntegrationError.conflictingBridgeCommand(
                HookIntegrationPaths.paseoPluginIdentifier
            )
        }
    }

    private func paseoPluginEntryBelongsToOtherAppBundle(_ data: Data) -> Bool {
        let otherBundleID = appBundleIdentifier == HookIntegrationPaths.developmentAppBundleIdentifier
            ? HookIntegrationPaths.releaseAppBundleIdentifier
            : HookIntegrationPaths.developmentAppBundleIdentifier
        return String(data: data, encoding: .utf8)?
            .contains("const APP_BUNDLE_ID = \"\(otherBundleID)\";") == true
    }

    private func installPaseoPluginFiles() throws {
        let directory = HookIntegrationPaths.paseoPluginDirectory(homeDirectory: homeDirectory)
        try createPrivateDirectoryIfNeeded(directory)

        let manifestURL = HookIntegrationPaths.paseoPluginManifestURL(homeDirectory: homeDirectory)
        let entryURL = HookIntegrationPaths.paseoPluginServerEntryURL(homeDirectory: homeDirectory)
        let manifestOriginal = try configurationSnapshot(at: manifestURL)
        let entryOriginal = try configurationSnapshot(at: entryURL)
        let expectedManifest = HookIntegrationPaths.paseoPluginManifestData()
        let expectedEntry = HookIntegrationPaths.paseoPluginServerEntryData(
            homeDirectory: homeDirectory,
            appBundleIdentifier: appBundleIdentifier
        )

        if manifestOriginal.data != expectedManifest {
            try writeConfiguration(
                expectedManifest,
                to: manifestURL,
                replacing: manifestOriginal
            )
        }
        if entryOriginal.data != expectedEntry {
            try writeConfiguration(
                expectedEntry,
                to: entryURL,
                replacing: entryOriginal
            )
        }
    }

    private func removePaseoPluginFilesIfPresent() throws -> Bool {
        let directory = HookIntegrationPaths.paseoPluginDirectory(homeDirectory: homeDirectory)
        var dirInfo = stat()
        guard lstat(directory.path, &dirInfo) == 0 else {
            if errno == ENOENT { return false }
            throw HookIntegrationError.configurationReadFailed
        }
        guard (dirInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw HookIntegrationError.unsafeConfigurationFile
        }

        var removed = false
        for url in [
            HookIntegrationPaths.paseoPluginManifestURL(homeDirectory: homeDirectory),
            HookIntegrationPaths.paseoPluginServerEntryURL(homeDirectory: homeDirectory),
        ] {
            var fileInfo = stat()
            if lstat(url.path, &fileInfo) == 0 {
                guard (fileInfo.st_mode & S_IFMT) == S_IFREG else {
                    throw HookIntegrationError.unsafeConfigurationFile
                }
                if Darwin.unlink(url.path) == 0 {
                    removed = true
                }
            }
        }
        if let remaining = try? fileManager.contentsOfDirectory(atPath: directory.path),
           remaining.isEmpty {
            _ = Darwin.rmdir(directory.path)
        }
        return removed
    }

    /// Best-effort live reload when a local Paseo daemon is already running.
    /// File configuration is the durable source of truth; CLI absence or an
    /// offline daemon never fails installation or removal.
    static func syncRunningPaseoDaemonIfPresent(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        installed: Bool
    ) {
        let paseoHome = homeDirectory.appendingPathComponent(".paseo", isDirectory: true)
        let hasLivePIDFile = ["paseo.pid", "daemon.pid"].contains { fileName in
            let pidURL = paseoHome.appendingPathComponent(fileName, isDirectory: false)
            var pidInfo = stat()
            return lstat(pidURL.path, &pidInfo) == 0 && (pidInfo.st_mode & S_IFMT) == S_IFREG
        }
        guard hasLivePIDFile,
              let cliURL = discoverPaseoCLI(homeDirectory: homeDirectory) else {
            return
        }

        let pluginID = HookIntegrationPaths.paseoPluginIdentifier
        let pluginDirectory = HookIntegrationPaths.paseoPluginDirectory(
            homeDirectory: homeDirectory
        ).path

        if installed {
            _ = runPaseoCLI(cliURL, arguments: ["--home", paseoHome.path, "reload"])
            let listResult = runPaseoCLI(
                cliURL,
                arguments: ["--home", paseoHome.path, "plugin", "ls", "--json"]
            )
            guard listResult.exitCode == 0 else { return }
            let entries = (try? JSONSerialization.jsonObject(with: listResult.stdout))
                as? [[String: Any]] ?? []
            if let existing = entries.first(where: { ($0["id"] as? String) == pluginID }) {
                if (existing["path"] as? String) != pluginDirectory {
                    _ = runPaseoCLI(
                        cliURL,
                        arguments: ["--home", paseoHome.path, "plugin", "remove", pluginID]
                    )
                    _ = runPaseoCLI(
                        cliURL,
                        arguments: [
                            "--home", paseoHome.path,
                            "plugin", "install", pluginDirectory,
                            "--id", pluginID,
                        ]
                    )
                } else {
                    _ = runPaseoCLI(
                        cliURL,
                        arguments: ["--home", paseoHome.path, "plugin", "enable", pluginID]
                    )
                    _ = runPaseoCLI(
                        cliURL,
                        arguments: ["--home", paseoHome.path, "plugin", "reload", pluginID]
                    )
                }
            } else {
                _ = runPaseoCLI(
                    cliURL,
                    arguments: [
                        "--home", paseoHome.path,
                        "plugin", "install", pluginDirectory,
                        "--id", pluginID,
                    ]
                )
            }
        } else {
            _ = runPaseoCLI(
                cliURL,
                arguments: ["--home", paseoHome.path, "plugin", "remove", pluginID]
            )
        }
    }

    private static func discoverPaseoCLI(homeDirectory: URL) -> URL? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Paseo.app/Contents/Resources/bin/paseo"),
            homeDirectory.appendingPathComponent("Applications/Paseo.app/Contents/Resources/bin/paseo"),
            homeDirectory.appendingPathComponent(".homebrew/bin/paseo"),
            URL(fileURLWithPath: "/opt/homebrew/bin/paseo"),
            URL(fileURLWithPath: "/usr/local/bin/paseo"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func runPaseoCLI(
        _ cliURL: URL,
        arguments: [String],
        timeout: TimeInterval = 5.0
    ) -> (exitCode: Int32, stdout: Data) {
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = cliURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        var output = Data()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            output = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            _ = readGroup.wait(timeout: .now() + 0.5)
            return (-1, Data())
        }
        try? stdoutPipe.fileHandleForWriting.close()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 0.5)
            _ = readGroup.wait(timeout: .now() + 0.5)
            return (-1, Data())
        }
        _ = readGroup.wait(timeout: .now() + 0.5)
        return (process.terminationStatus, output)
    }

    private func isExecutableRegularFile(at url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return (info.st_mode & 0o111) != 0
    }

    private func isRegularFile(at url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }
}
