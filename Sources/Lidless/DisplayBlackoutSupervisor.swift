import Darwin
import Foundation

/// App-side lifecycle for the short-lived display watchdog.
///
/// The watchdog is launched only for an arm request or while a durable recovery
/// record exists. Anonymous pipes keep the control surface private to the exact
/// child process the app launched; the random token and generation reject stale
/// responses and the exact advertisement rejects a mixed-version app bundle.
@MainActor
final class DisplayBlackoutSupervisor {
    enum Phase: Equatable {
        case idle
        case starting
        case armed
        case restoring
        case pendingRecovery
    }

    struct Snapshot: Equatable {
        var phase: Phase = .idle
        var capability: DisplayBlackoutCapability = .brightnessUnavailable
        var lastStatus: DisplayBlackoutResponseStatus?
        var failureCode: String?
        /// Recovery facts must not be overwritten by the separate arm-capability
        /// probe, which deliberately reports externalDisplayConnected first.
        var recoveryStatus: DisplayBlackoutResponseStatus?
        var recoveryFailure: AllDisplaysSleepPreparationFailure?

        var blackoutActive: Bool {
            phase == .armed || phase == .restoring
        }

        var busy: Bool {
            phase == .starting || phase == .restoring
        }

        var recoveryPending: Bool {
            phase == .pendingRecovery
        }
    }

    typealias SnapshotHandler = (Snapshot) -> Void
    typealias RestoreCompletion = (Bool) -> Void
    typealias CapabilityProbe = () -> DisplayBlackoutCapability
    typealias FallbackRecovery = @Sendable (
        URL
    ) -> Result<DisplayBlackoutRestoreResult, Error>

    var onSnapshotChange: SnapshotHandler?

    private(set) var snapshot = Snapshot() {
        didSet {
            guard snapshot != oldValue else { return }
            onSnapshotChange?(snapshot)
        }
    }

    private struct ChildContext {
        let id: UInt64
        let token: String
        let generation: UInt64
        let initialAction: DisplayBlackoutRequestAction
        let journalAtLaunch: DisplayBlackoutJournal?
        let process: Process
        let input: FileHandle
        let output: FileHandle
        var didReceiveArmed = false
        var restoreControlSent = false
        var acknowledgedRecoveryJournal: DisplayBlackoutJournal?
        var restoreCompletions: [RestoreCompletion] = []
    }

    private enum TimeoutPurpose: Equatable {
        case initialResponse
        case restore
    }

    private let watchdogURLProvider: () -> URL?
    private let journalStore: DisplayBlackoutJournalStore
    private let fileManager: FileManager
    private let capabilityProbe: CapabilityProbe
    private let fallbackRecovery: FallbackRecovery
    private let sleepTopologyProbe: () -> AllDisplaysSleepTopology
    private let readerQueue = DispatchQueue(
        label: "com.kenny.lidlessai.display-blackout.reader",
        qos: .userInitiated
    )
    private let recoveryQueue = DispatchQueue(
        label: "com.kenny.lidlessai.display-blackout.recovery",
        qos: .userInitiated
    )
    private var child: ChildContext?
    private var contextCounter: UInt64 = 0
    private var operationGeneration: UInt64
    private var timeoutWorkItem: DispatchWorkItem?
    private var fallbackRecoveryInFlight = false
    private var fallbackRestoreCompletions: [RestoreCompletion] = []
    private var sleepPreparationGeneration: UInt64 = 0
    private var sleepPreparationCompletion: ((AllDisplaysSleepPreparation) -> Void)?
    private var sleepPreparationTimer: DispatchWorkItem?
    private var sleepPreparationDeadline: TimeInterval = 0

    init(
        watchdogURLProvider: @escaping () -> URL? = {
            Bundle.main.url(forAuxiliaryExecutable: "LidlessDisplayWatchdog")
        },
        journalStore: DisplayBlackoutJournalStore? = nil,
        fileManager: FileManager = .default,
        capabilityProbe: @escaping CapabilityProbe = {
            do {
                return try BuiltInDisplayBrightnessController.system()
                    .blackoutCapability()
            } catch {
                return .brightnessUnavailable
            }
        },
        sleepTopologyProbe: @escaping () -> AllDisplaysSleepTopology = {
            AllDisplaysSleepTopology.system()
        },
        fallbackRecovery: @escaping FallbackRecovery = { journalFileURL in
            do {
                let recoveryStore = DisplayBlackoutJournalStore(
                    fileURL: journalFileURL
                )
                return .success(
                    try BuiltInDisplayBrightnessController.system()
                        .restoreIfNeeded(journalStore: recoveryStore)
                )
            } catch {
                return .failure(error)
            }
        }
    ) {
        self.watchdogURLProvider = watchdogURLProvider
        self.journalStore = journalStore ?? Self.defaultJournalStore()
        self.fileManager = fileManager
        self.capabilityProbe = capabilityProbe
        self.fallbackRecovery = fallbackRecovery
        self.sleepTopologyProbe = sleepTopologyProbe
        let uptimeNanoseconds = ProcessInfo.processInfo.systemUptime * 1_000_000_000
        operationGeneration = max(1, UInt64(uptimeNanoseconds.rounded(.down)))
    }

    private static func defaultJournalStore() -> DisplayBlackoutJournalStore {
        let rawIdentifier = Bundle.main.bundleIdentifier ?? "com.kenny.lidlessai"
        let safeIdentifier = rawIdentifier.unicodeScalars.map { scalar -> Character in
            let allowed = CharacterSet.alphanumerics
                .union(CharacterSet(charactersIn: ".-_"))
            return allowed.contains(scalar) ? Character(String(scalar)) : "_"
        }
        let fileName = String(safeIdentifier) + "-display-blackout-recovery.json"
        let defaultURL = DisplayBlackoutJournalStore.defaultFileURL()
        return DisplayBlackoutJournalStore(
            fileURL: defaultURL.deletingLastPathComponent()
                .appendingPathComponent(fileName, isDirectory: false)
        )
    }

    deinit {
        timeoutWorkItem?.cancel()
        sleepPreparationTimer?.cancel()
        child?.input.closeFile()
        child?.output.closeFile()
    }

    /// Read-only capability probe. The watchdog repeats the same check after the
    /// recovery journal is durable and immediately before its only zero write.
    @discardableResult
    func refreshCapability() -> DisplayBlackoutCapability {
        let capability: DisplayBlackoutCapability
        guard let watchdogURL = watchdogURLProvider(),
              fileManager.isExecutableFile(atPath: watchdogURL.path) else {
            capability = .brightnessUnavailable
            snapshot.capability = capability
            return capability
        }

        capability = capabilityProbe()
        snapshot.capability = capability
        return capability
    }

    /// Recover only when a journal entry exists. A clean launch does not start
    /// the watchdog, preserving its intentionally ephemeral lifecycle.
    func recoverAtLaunchIfNeeded() {
        guard journalMayExist else {
            refreshCapability()
            return
        }
        start(action: .recover)
    }

    func arm() {
        guard child == nil, !fallbackRecoveryInFlight else { return }
        guard case .ready = refreshCapability() else { return }
        start(action: .arm)
    }

    /// End an active blackout or retry a pending recovery. Completion is invoked
    /// once the panel has been restored, the user's own brightness change was
    /// preserved, or a durable pending state has been confirmed. That boundary
    /// lets AppState restore brightness before releasing its Helper lease.
    func restore(completion: RestoreCompletion? = nil) {
        if fallbackRecoveryInFlight {
            if let completion { fallbackRestoreCompletions.append(completion) }
            return
        }

        if var child {
            if snapshot.phase == .pendingRecovery {
                completion?(false)
                return
            }
            if let completion { child.restoreCompletions.append(completion) }
            self.child = child

            switch snapshot.phase {
            case .armed:
                sendRestoreControlIfNeeded()
            case .starting:
                // Closing the parent control pipe is itself a watchdog restore
                // trigger. This also covers Quit racing the initial arm reply.
                snapshot.phase = .restoring
                child.input.closeFile()
                scheduleTimeout(for: child.id, purpose: .restore)
            case .restoring:
                break
            case .pendingRecovery, .idle:
                break
            }
            return
        }

        if let completion {
            if !journalMayExist {
                completion(true)
                return
            }
        } else if !journalMayExist {
            return
        }

        start(action: .recover, restoreCompletion: completion)
    }

    /// A display-only handoff. The existing restore callback remains strict for
    /// Quit and normal-sleep release. This independent waiter can instead accept
    /// a *confirmed* offline panel, with its durable recovery still supervised.
    func prepareForAllDisplaysSleep(
        completion: @escaping (AllDisplaysSleepPreparation) -> Void
    ) {
        cancelAllDisplaysSleepPreparation()
        sleepPreparationCompletion = completion
        // Finish with the most specific reason before the outer controller's
        // five-second safety timeout; its timer is created before this call.
        sleepPreparationDeadline = ProcessInfo.processInfo.systemUptime + 4.5
        let generation = sleepPreparationGeneration
        restore()
        pollAllDisplaysSleepPreparation(generation: generation)
    }

    /// Cancels only the handoff waiter, never the watchdog or recovery record.
    func cancelAllDisplaysSleepPreparation() {
        sleepPreparationGeneration &+= 1
        sleepPreparationTimer?.cancel()
        sleepPreparationTimer = nil
        sleepPreparationCompletion = nil
    }

    /// Re-read immediately before the one-shot OS command. An earlier positive
    /// answer is not a lease to ignore a dead watchdog or changed recovery file.
    func revalidateAllDisplaysSleepPreparation() -> AllDisplaysSleepPreparation {
        currentAllDisplaysSleepPreparation() ?? .blocked(.recoveryUnavailable)
    }

    private func currentAllDisplaysSleepPreparation() -> AllDisplaysSleepPreparation? {
        let journal: DisplayBlackoutJournal?
        do { journal = try journalStore.load() }
        catch { return .blocked(.invalidRecoveryRecord) }

        guard let journal else {
            // A starting arm may not have written its journal yet. Wait until
            // the exact child has acknowledged restoration and exited our state.
            return child == nil && !fallbackRecoveryInFlight ? .ready : nil
        }
        if fallbackRecoveryInFlight { return nil }
        guard let child, child.process.isRunning else {
            return .blocked(.recoveryUnavailable)
        }
        if let failure = snapshot.recoveryFailure { return .blocked(failure) }
        guard snapshot.phase == .pendingRecovery else { return nil }
        guard snapshot.failureCode == nil else { return .blocked(.recoveryFailed) }
        guard snapshot.recoveryStatus == .builtInUnavailable else {
            switch snapshot.recoveryStatus {
            case .brightnessUnavailable: return .blocked(.brightnessUnavailable)
            case .topologyUnknown: return .blocked(.topologyUnknown)
            default: return .blocked(.recoveryFailed)
            }
        }
        guard journal.phase == .restoring,
              child.acknowledgedRecoveryJournal == journal else {
            return .blocked(.invalidRecoveryRecord)
        }
        let topology = sleepTopologyProbe()
        guard topology.isKnown, case .known(let lidClosed, _) = topology,
              lidClosed != nil else { return .blocked(.topologyUnknown) }
        guard topology.permitsDeferredBuiltInRecovery else {
            return .blocked(.builtInUnavailable)
        }
        return .deferredBuiltInRecovery
    }

    private func pollAllDisplaysSleepPreparation(generation: UInt64) {
        guard generation == sleepPreparationGeneration,
              sleepPreparationCompletion != nil else { return }
        let result = currentAllDisplaysSleepPreparation()
        let expired = ProcessInfo.processInfo.systemUptime >= sleepPreparationDeadline
        let terminal: AllDisplaysSleepPreparation?
        switch result {
        case .ready?, .deferredBuiltInRecovery?: terminal = result
        case .blocked(.invalidRecoveryRecord)?, .blocked(.recoveryUnavailable)?:
            terminal = result
        case .blocked?: terminal = expired ? result : nil
        case nil: terminal = expired ? .blocked(.timedOut) : nil
        }
        if let terminal {
            let completion = sleepPreparationCompletion
            cancelAllDisplaysSleepPreparation()
            completion?(terminal)
            return
        }
        let item = DispatchWorkItem { [weak self] in
            self?.pollAllDisplaysSleepPreparation(generation: generation)
        }
        sleepPreparationTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
    }

    func retryPendingRecovery() {
        guard child == nil, !fallbackRecoveryInFlight, journalMayExist else {
            if !journalMayExist, snapshot.phase == .pendingRecovery {
                snapshot.phase = .idle
                snapshot.lastStatus = .noRecoveryNeeded
                snapshot.failureCode = nil
                refreshCapability()
            }
            return
        }
        start(action: .recover)
    }

    /// Used from the final AppKit notification as a last line of defence. Normal
    /// Quit has already awaited `restore`; closing the pipe here handles every
    /// unexpected termination path without issuing a Helper or brightness write
    /// on the main thread.
    func closeControlPipeForTermination() {
        child?.input.closeFile()
    }

    private var journalMayExist: Bool {
        var metadata = stat()
        if Darwin.lstat(journalStore.fileURL.path, &metadata) == 0 { return true }
        return errno != ENOENT
    }

    private func nextIdentity() -> (token: String, generation: UInt64) {
        operationGeneration &+= 1
        if operationGeneration == 0 { operationGeneration = 1 }
        return (DisplayBlackoutProtocol.makeToken(), operationGeneration)
    }

    private func start(
        action: DisplayBlackoutRequestAction,
        restoreCompletion: RestoreCompletion? = nil
    ) {
        guard child == nil, !fallbackRecoveryInFlight else {
            restoreCompletion?(false)
            return
        }
        guard let executableURL = watchdogURLProvider(),
              fileManager.isExecutableFile(atPath: executableURL.path) else {
            snapshot.capability = .brightnessUnavailable
            snapshot.lastStatus = .brightnessUnavailable
            snapshot.failureCode = "watchdog-unavailable"
            if journalMayExist {
                scheduleStandaloneFallbackRecovery(
                    failureCode: "watchdog-unavailable",
                    restoreCompletion: restoreCompletion
                )
            } else {
                snapshot.phase = .idle
                restoreCompletion?(false)
            }
            return
        }

        let identity = nextIdentity()
        let journalAtLaunch = try? journalStore.load()
        let request = DisplayBlackoutRequest(
            token: identity.token,
            generation: identity.generation,
            action: action
        )
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        Self.markCloseOnExec(inputPipe.fileHandleForWriting.fileDescriptor)
        Self.markCloseOnExec(outputPipe.fileHandleForReading.fileDescriptor)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = []
        var environment = ProcessInfo.processInfo.environment
        environment["LIDLESS_DISPLAY_BLACKOUT_JOURNAL_PATH"] = journalStore.fileURL.path
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        contextCounter &+= 1
        if contextCounter == 0 { contextCounter = 1 }
        let contextID = contextCounter
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.handleProcessTermination(
                    contextID: contextID,
                    status: process.terminationStatus
                )
            }
        }

        do {
            try process.run()
        } catch {
            snapshot.lastStatus = .failed
            snapshot.failureCode = "watchdog-launch-failed"
            if journalMayExist {
                scheduleStandaloneFallbackRecovery(
                    failureCode: "watchdog-launch-failed",
                    restoreCompletion: restoreCompletion
                )
            } else {
                snapshot.phase = .idle
                restoreCompletion?(false)
            }
            return
        }

        // Process has duplicated its configured ends. Close our unused copies so
        // EOF is observable, and suppress SIGPIPE on the remaining control end.
        inputPipe.fileHandleForReading.closeFile()
        outputPipe.fileHandleForWriting.closeFile()
        _ = Darwin.fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        child = ChildContext(
            id: contextID,
            token: identity.token,
            generation: identity.generation,
            initialAction: action,
            journalAtLaunch: journalAtLaunch,
            process: process,
            input: inputPipe.fileHandleForWriting,
            output: outputPipe.fileHandleForReading,
            restoreCompletions: restoreCompletion.map { [$0] } ?? []
        )
        snapshot.phase = .starting
        snapshot.lastStatus = nil
        snapshot.failureCode = nil
        snapshot.recoveryStatus = nil
        scheduleTimeout(for: contextID, purpose: .initialResponse)

        let outputDescriptor = outputPipe.fileHandleForReading.fileDescriptor
        readerQueue.async { [weak self] in
            do {
                while let response = try DisplayBlackoutFrameCodec.read(
                    DisplayBlackoutResponse.self,
                    from: outputDescriptor
                ) {
                    DispatchQueue.main.async {
                        self?.handle(response, contextID: contextID)
                    }
                }
                DispatchQueue.main.async {
                    self?.handleReaderEnd(contextID: contextID, failureCode: nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.handleReaderEnd(
                        contextID: contextID,
                        failureCode: "watchdog-response-invalid"
                    )
                }
            }
        }

        do {
            try DisplayBlackoutFrameCodec.write(
                request,
                to: inputPipe.fileHandleForWriting.fileDescriptor
            )
        } catch {
            failChild(contextID: contextID, failureCode: "watchdog-request-failed")
        }
    }

    private func sendRestoreControlIfNeeded() {
        guard var child, !child.restoreControlSent else { return }
        child.restoreControlSent = true
        self.child = child
        snapshot.phase = .restoring
        scheduleTimeout(for: child.id, purpose: .restore)

        let request = DisplayBlackoutRequest(
            token: child.token,
            generation: child.generation,
            action: .restore
        )
        do {
            try DisplayBlackoutFrameCodec.write(request, to: child.input.fileDescriptor)
        } catch {
            child.input.closeFile()
            scheduleFallbackRecovery(
                contextID: child.id,
                failureCode: "watchdog-restore-request-failed"
            )
        }
    }

    private static func markCloseOnExec(_ descriptor: Int32) {
        let flags = Darwin.fcntl(descriptor, F_GETFD)
        if flags >= 0 {
            _ = Darwin.fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC)
        }
    }

    private func handle(_ response: DisplayBlackoutResponse, contextID: UInt64) {
        guard var child, child.id == contextID else { return }
        guard response.protocolVersion == DisplayBlackoutProtocol.currentVersion,
              response.versionAdvertisement
                == DisplayBlackoutProtocol.currentVersionAdvertisement,
              response.token == child.token,
              response.generation == child.generation else {
            failChild(contextID: contextID, failureCode: "watchdog-handshake-mismatch")
            return
        }

        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        snapshot.lastStatus = response.status
        snapshot.failureCode = response.failureCode

        if response.recoveryPending {
            let pendingCapability = capability(for: response.status)
            snapshot.phase = .pendingRecovery
            snapshot.capability = pendingCapability
            snapshot.recoveryStatus = response.status
            if response.status == .brightnessUnavailable {
                snapshot.recoveryFailure = .brightnessUnavailable
            } else if response.failureCode != nil || response.status == .failed {
                snapshot.recoveryFailure = .recoveryFailed
            } else if snapshot.recoveryFailure == .recoveryUnavailable {
                // A fresh authenticated child has taken over after a transport
                // failure. This does not erase any actual brightness fault.
                snapshot.recoveryFailure = nil
            }
            // The pipe handshake authenticates this child; bind its pending
            // acknowledgement to the exact valid durable record as well.
            if let record = try? journalStore.load(),
               recoveryRecord(record, belongsTo: child) {
                child.acknowledgedRecoveryJournal = record
            } else {
                child.acknowledgedRecoveryJournal = nil
                snapshot.recoveryFailure = .invalidRecoveryRecord
            }
            // Every v1 watchdog keeps polling after a pending recovery response,
            // including startup recovery before an `.armed` response. Retain the
            // exact child and response pipe so a built-in panel that comes back
            // while an external display remains connected can still produce the
            // final `.restored` without relying on AppKit topology equality.
            let completions = child.restoreCompletions
            child.restoreCompletions.removeAll()
            self.child = child
            completions.forEach { $0(false) }
            return
        }

        switch response.status {
        case .armed:
            child.didReceiveArmed = true
            self.child = child
            if snapshot.phase == .restoring {
                // The input may already be closed by a Quit that raced arm.
                scheduleTimeout(for: contextID, purpose: .restore)
            } else {
                snapshot.phase = .armed
            }
        case .restored, .noRecoveryNeeded:
            finishChild(
                contextID: contextID,
                phase: .idle,
                restored: true,
                status: response.status,
                failureCode: nil
            )
            refreshCapability()
        case .ready:
            finishChild(
                contextID: contextID,
                phase: .idle,
                restored: true,
                status: .ready,
                failureCode: nil
            )
            refreshCapability()
        case .externalDisplayConnected, .topologyUnknown,
             .builtInUnavailable, .brightnessUnavailable:
            let capability = capability(for: response.status)
            snapshot.capability = capability
            finishChild(
                contextID: contextID,
                phase: .idle,
                restored: !journalMayExist,
                status: response.status,
                failureCode: response.failureCode
            )
        case .protocolMismatch, .invalidRequest, .staleGeneration, .failed:
            failChild(
                contextID: contextID,
                failureCode: response.failureCode ?? response.status.rawValue
            )
        }
    }

    private func capability(
        for status: DisplayBlackoutResponseStatus
    ) -> DisplayBlackoutCapability {
        switch status {
        case .externalDisplayConnected:
            return .externalDisplayConnected(count: 1)
        case .topologyUnknown:
            return .topologyUnknown
        case .builtInUnavailable:
            return .builtInUnavailable
        case .brightnessUnavailable:
            return .brightnessUnavailable
        default:
            return snapshot.capability
        }
    }

    /// A queued response for an older record cannot acknowledge a replacement
    /// that happened to be present when the app read the response. Recovery may
    /// advance phase/time, but never change the transaction's immutable values.
    private func recoveryRecord(
        _ record: DisplayBlackoutJournal,
        belongsTo child: ChildContext
    ) -> Bool {
        guard let original = child.journalAtLaunch else {
            return child.initialAction == .arm
                && record.token == child.token && record.generation == child.generation
        }
        return record.schemaVersion == original.schemaVersion
            && record.token == original.token && record.generation == original.generation
            && record.displayID == original.displayID
            && record.originalBrightness == original.originalBrightness
            && record.createdAt == original.createdAt
    }

    private func handleReaderEnd(contextID: UInt64, failureCode: String?) {
        guard let child, child.id == contextID else { return }
        if let failureCode {
            scheduleFallbackRecovery(contextID: contextID, failureCode: failureCode)
            return
        }
        // A terminal response normally clears the context before EOF reaches the
        // main actor. If it did not, give that queued response one run-loop turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.child?.id == contextID else { return }
            self.scheduleFallbackRecovery(
                contextID: contextID,
                failureCode: "watchdog-closed-without-terminal-response"
            )
        }
    }

    private func handleProcessTermination(contextID: UInt64, status: Int32) {
        guard child?.id == contextID else { return }
        scheduleFallbackRecovery(
            contextID: contextID,
            failureCode: "watchdog-exited-\(status)"
        )
    }

    private func failChild(contextID: UInt64, failureCode: String) {
        guard let child, child.id == contextID else { return }
        child.input.closeFile()
        scheduleFallbackRecovery(contextID: contextID, failureCode: failureCode)
    }

    private func scheduleTimeout(for contextID: UInt64, purpose: TimeoutPurpose) {
        timeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.child?.id == contextID else { return }
            let code = purpose == .initialResponse
                ? "watchdog-initial-response-timeout"
                : "watchdog-restore-timeout"
            self.scheduleFallbackRecovery(contextID: contextID, failureCode: code)
        }
        timeoutWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (purpose == .initialResponse ? 2.0 : 1.5),
            execute: item
        )
    }

    private func scheduleFallbackRecovery(contextID: UInt64, failureCode: String) {
        guard let current = child, current.id == contextID,
              !fallbackRecoveryInFlight else { return }
        fallbackRecoveryInFlight = true
        fallbackRestoreCompletions.append(contentsOf: current.restoreCompletions)
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        current.input.closeFile()
        current.output.closeFile()
        if current.process.isRunning { current.process.terminate() }
        child = nil
        snapshot.phase = journalMayExist ? .restoring : .idle
        snapshot.lastStatus = .failed
        snapshot.failureCode = failureCode

        let journalFileURL = journalStore.fileURL
        let fallbackRecovery = self.fallbackRecovery
        recoveryQueue.async { [weak self] in
            let result = fallbackRecovery(journalFileURL)
            DispatchQueue.main.async {
                self?.finishFallbackRecovery(
                    result,
                    failureCode: failureCode
                )
            }
        }
    }

    /// Launch failures have no child context to tear down, but an existing
    /// journal is still an immediate recovery obligation. Use the same in-app
    /// controller fallback as a crashed watchdog instead of merely advertising a
    /// pending state that cannot make progress by itself.
    private func scheduleStandaloneFallbackRecovery(
        failureCode: String,
        restoreCompletion: RestoreCompletion?
    ) {
        guard !fallbackRecoveryInFlight else {
            if let restoreCompletion {
                fallbackRestoreCompletions.append(restoreCompletion)
            }
            return
        }
        fallbackRecoveryInFlight = true
        if let restoreCompletion {
            fallbackRestoreCompletions.append(restoreCompletion)
        }
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        snapshot.phase = .restoring
        snapshot.lastStatus = .failed
        snapshot.failureCode = failureCode

        let journalFileURL = journalStore.fileURL
        let fallbackRecovery = self.fallbackRecovery
        recoveryQueue.async { [weak self] in
            let result = fallbackRecovery(journalFileURL)
            DispatchQueue.main.async {
                self?.finishFallbackRecovery(result, failureCode: failureCode)
            }
        }
    }

    private func finishFallbackRecovery(
        _ result: Result<DisplayBlackoutRestoreResult, Error>,
        failureCode: String
    ) {
        fallbackRecoveryInFlight = false
        let restored: Bool
        switch result {
        case .success(.noJournal), .success(.restored),
             .success(.userAlreadyRestored):
            snapshot.phase = .idle
            snapshot.lastStatus = .restored
            snapshot.failureCode = failureCode
            snapshot.recoveryStatus = nil
            snapshot.recoveryFailure = nil
            restored = true
        case .success(.pending(let capability, _)):
            snapshot.phase = .pendingRecovery
            snapshot.capability = capability
            snapshot.lastStatus = capability.responseStatus
            snapshot.failureCode = failureCode
            snapshot.recoveryStatus = capability.responseStatus
            if capability == .brightnessUnavailable {
                snapshot.recoveryFailure = .brightnessUnavailable
            } else if snapshot.recoveryFailure == nil
                        || snapshot.recoveryFailure == .recoveryUnavailable {
                // Losing a child while the lid is closed cannot convert an
                // unresolved brightness fault into a transport-only failure.
                snapshot.recoveryFailure = .recoveryUnavailable
            }
            restored = false
        case .failure:
            snapshot.phase = journalMayExist ? .pendingRecovery : .idle
            snapshot.lastStatus = .failed
            snapshot.failureCode = failureCode
            snapshot.recoveryFailure = .recoveryFailed
            restored = !journalMayExist
        }
        let completions = fallbackRestoreCompletions
        fallbackRestoreCompletions.removeAll()
        completions.forEach { $0(restored) }
        if snapshot.phase == .idle { refreshCapability() }
    }

    private func finishChild(
        contextID: UInt64,
        phase: Phase,
        restored: Bool,
        status: DisplayBlackoutResponseStatus,
        failureCode: String?
    ) {
        guard let current = child, current.id == contextID else { return }
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        current.input.closeFile()
        current.output.closeFile()
        let completions = current.restoreCompletions
        child = nil
        snapshot.phase = phase
        snapshot.lastStatus = status
        snapshot.failureCode = failureCode
        if restored {
            snapshot.recoveryStatus = nil
            snapshot.recoveryFailure = nil
        }
        completions.forEach { $0(restored) }
    }
}
