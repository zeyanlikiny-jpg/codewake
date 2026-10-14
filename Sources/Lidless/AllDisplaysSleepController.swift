import AppKit
import CoreGraphics
import Foundation

/// One manual request to macOS to sleep every display. This controller never
/// changes a power setting, creates a wake source, or repeats a sleep request.
@MainActor
final class AllDisplaysSleepController {
    enum Phase: Equatable {
        case idle, preparing, scheduled, requesting, confirming, asleep
    }

    enum Failure: String, Equatable {
        case preparationFailed
        case commandLaunchFailed
        case commandFailed
        case commandTimedOut
        case confirmationTimedOut
    }

    struct Snapshot: Equatable {
        var phase: Phase = .idle
        var failure: Failure?
        var preparationFailure: AllDisplaysSleepPreparationFailure?

        var isBusy: Bool {
            switch phase {
            case .preparing, .scheduled, .requesting, .confirming: return true
            case .idle, .asleep: return false
            }
        }

        var suspendsDisplayAwake: Bool { phase != .idle }
    }

    enum DisplayState: Equatable {
        case unknown
        /// One Boolean per online display, including mirrored displays.
        case online(asleep: [Bool])

        var allAsleep: Bool {
            guard case .online(let values) = self, !values.isEmpty else { return false }
            return values.allSatisfy { $0 }
        }
    }

    enum CommandResult: Equatable {
        case launchFailed
        case finished(exitStatus: Int32, stdout: String, stderr: String)
    }

    enum ScreenEvent {
        case displaysSlept, displaysWoke, systemWillSleep, systemDidWake, topologyChanged
    }

    /// Thread-safe, idempotent cleanup also usable from a deinitializer.
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (() -> Void)?

        init(_ action: @escaping () -> Void = {}) { self.action = action }

        func cancel() {
            lock.lock()
            let work = action
            action = nil
            lock.unlock()
            work?()
        }
    }

    struct Dependencies {
        var uptime: () -> TimeInterval
        var schedule: (TimeInterval, @escaping () -> Void) -> Cancellation
        var launch: (@escaping (CommandResult) -> Void) -> Cancellation
        var probe: () -> DisplayState
        var observe: (@escaping (ScreenEvent) -> Void) -> Cancellation
        var topology: () -> AllDisplaysSleepTopology = AllDisplaysSleepTopology.system

        static var system: Dependencies {
            Dependencies(
                uptime: { ProcessInfo.processInfo.systemUptime },
                schedule: { delay, action in
                    let item = DispatchWorkItem(block: action)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
                    return Cancellation { item.cancel() }
                },
                launch: { completion in
                    AllDisplaysSleepProcess.launch(completion: completion)
                },
                probe: Self.probeSystemDisplays,
                observe: { handler in
                    let center = NSWorkspace.shared.notificationCenter
                    let events: [(Notification.Name, ScreenEvent)] = [
                        (NSWorkspace.screensDidSleepNotification, .displaysSlept),
                        (NSWorkspace.screensDidWakeNotification, .displaysWoke),
                        (NSWorkspace.willSleepNotification, .systemWillSleep),
                        (NSWorkspace.didWakeNotification, .systemDidWake)
                    ]
                    let observers = events.map { name, event in
                        center.addObserver(forName: name, object: nil, queue: .main) { _ in
                            // Notifications already queued for a removed observer
                            // remain harmless because its request generation is
                            // captured by the controller's handler.
                            Task { @MainActor in handler(event) }
                        }
                    }
                    let screenObserver = NotificationCenter.default.addObserver(
                        forName: NSApplication.didChangeScreenParametersNotification,
                        object: nil,
                        queue: .main
                    ) { _ in
                        Task { @MainActor in handler(.topologyChanged) }
                    }
                    return Cancellation {
                        observers.forEach(center.removeObserver)
                        NotificationCenter.default.removeObserver(screenObserver)
                    }
                }
            )
        }

        private static func probeSystemDisplays() -> DisplayState {
            func onlineIDs() -> [CGDirectDisplayID]? {
                // A fixed upper bound avoids silently truncating the list when
                // a monitor arrives between a count query and a second query.
                let capacity: UInt32 = 64
                var ids = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
                var count: UInt32 = 0
                guard CGGetOnlineDisplayList(capacity, &ids, &count) == .success,
                      count < capacity else { return nil }
                let result = Array(ids.prefix(Int(count))).sorted()
                guard !result.contains(0), Set(result).count == result.count else { return nil }
                return result
            }

            guard let before = onlineIDs() else { return .unknown }
            let asleep = before.map { CGDisplayIsAsleep($0) != 0 }
            // An unplug/replug during the probe is not evidence that all of the
            // newly current display set is asleep. A later bounded poll retries.
            guard let after = onlineIDs(), before == after else { return .unknown }
            return .online(asleep: asleep)
        }
    }

    nonisolated static let clickDelay: TimeInterval = 1.5
    nonisolated static let preparationTimeout: TimeInterval = 5
    nonisolated static let commandTimeout: TimeInterval = 5
    nonisolated static let confirmationTimeout: TimeInterval = 5
    nonisolated static let confirmationPollInterval: TimeInterval = 0.25
    nonisolated static let topologyPollInterval: TimeInterval = 0.25

    var onSnapshotChange: ((Snapshot) -> Void)?
    private(set) var snapshot = Snapshot() {
        didSet {
            guard snapshot != oldValue else { return }
            onSnapshotChange?(snapshot)
        }
    }

    private let dependencies: Dependencies
    private var generation: UInt64 = 0
    private var startedAt: TimeInterval = 0
    private var confirmationDeadline: TimeInterval = 0
    private var stageTimer: Cancellation?
    private var pollTimer: Cancellation?
    private var command: Cancellation?
    private var observation: Cancellation?
    private var topologyTimer: Cancellation?
    private var requestedTopology: AllDisplaysSleepTopology?
    private var revalidatePreparation: (() -> AllDisplaysSleepPreparation)?

    init(dependencies: Dependencies = .system) {
        self.dependencies = dependencies
    }

    deinit {
        stageTimer?.cancel()
        pollTimer?.cancel()
        command?.cancel()
        observation?.cancel()
        topologyTimer?.cancel()
    }

    /// `prepare` restores an existing built-in-brightness blackout or confirms
    /// that its recovery can safely wait for the lid to open. A click starts the
    /// grace period immediately, so slow preparation does not add another delay.
    func request(
        prepare: @escaping (@escaping (AllDisplaysSleepPreparation) -> Void) -> Void,
        revalidate: (() -> AllDisplaysSleepPreparation)? = nil
    ) {
        guard snapshot.phase == .idle else { return }
        generation &+= 1
        let requestID = generation
        startedAt = dependencies.uptime()
        requestedTopology = dependencies.topology()
        revalidatePreparation = revalidate
        snapshot = Snapshot(phase: .preparing)
        guard isCurrent(requestID, phase: .preparing) else { return }
        guard validateTopology(requestID: requestID) else { return }

        let newObservation = dependencies.observe { [weak self] event in
            self?.handle(event, requestID: requestID)
        }
        // An injected observer may synchronously report wake/cancellation before
        // registration returns. Do not retain it or invoke stale preparation.
        guard isCurrent(requestID, phase: .preparing) else {
            newObservation.cancel()
            return
        }
        observation = newObservation
        scheduleStage(after: Self.preparationTimeout, requestID: requestID, phase: .preparing) { [weak self] in
            guard let self, self.isCurrent(requestID, phase: .preparing) else { return }
            self.finish(failure: .preparationFailed, preparationFailure: .timedOut)
        }
        scheduleTopologyCheck(requestID: requestID)
        guard isCurrent(requestID, phase: .preparing) else { return }
        prepare { [weak self] preparation in
            self?.prepared(preparation, requestID: requestID)
        }
    }

    /// Cancels pending work without waking displays or altering system policy.
    /// A request already submitted to macOS cannot be retracted; no later app
    /// timer or callback is allowed to launch another command after cancellation.
    func cancel() {
        finish(failure: nil)
    }

    /// A menu-open/tick fallback for a missed wake notification or a monitor
    /// connected after confirmation. An unavailable/empty display set cannot
    /// prove a wake and must not change the ongoing display-awake suspension.
    func refreshDisplayState() {
        guard snapshot.phase == .asleep,
              case .online(let states) = dependencies.probe(),
              !states.isEmpty,
              states.contains(false) else { return }
        cancel()
    }

    private func prepared(_ preparation: AllDisplaysSleepPreparation, requestID: UInt64) {
        guard isCurrent(requestID, phase: .preparing) else { return }
        let timer = stageTimer
        stageTimer = nil
        timer?.cancel()
        guard isCurrent(requestID, phase: .preparing) else { return }
        if case .blocked(let reason) = preparation {
            finish(failure: .preparationFailed, preparationFailure: reason)
            return
        }
        guard validateTopology(requestID: requestID) else { return }
        snapshot = Snapshot(phase: .scheduled)
        guard isCurrent(requestID, phase: .scheduled) else { return }
        let remaining = max(0, Self.clickDelay - (dependencies.uptime() - startedAt))
        scheduleStage(after: remaining, requestID: requestID, phase: .scheduled) { [weak self] in
            self?.beginCommand(requestID: requestID)
        }
    }

    private func beginCommand(requestID: UInt64) {
        guard isCurrent(requestID, phase: .scheduled) else { return }
        let timer = stageTimer
        stageTimer = nil
        timer?.cancel()
        guard isCurrent(requestID, phase: .scheduled),
              validateTopology(requestID: requestID) else { return }
        let preparation = revalidatePreparation?() ?? .ready
        guard isCurrent(requestID, phase: .scheduled) else { return }
        if case .blocked(let reason) = preparation {
            finish(failure: .preparationFailed, preparationFailure: reason)
            return
        }
        guard validateTopology(requestID: requestID) else { return }
        let topologyPoll = topologyTimer
        topologyTimer = nil
        topologyPoll?.cancel()
        guard isCurrent(requestID, phase: .scheduled) else { return }
        snapshot = Snapshot(phase: .requesting)
        guard isCurrent(requestID, phase: .requesting) else { return }
        scheduleStage(after: Self.commandTimeout, requestID: requestID, phase: .requesting) { [weak self] in
            guard let self, self.isCurrent(requestID, phase: .requesting) else { return }
            self.finish(failure: .commandTimedOut)
        }
        // Publishing requesting can itself cause UI observers to run. Recheck
        // after that boundary so an unplug or lid-open never launches old work.
        guard isCurrent(requestID, phase: .requesting),
              validateTopology(requestID: requestID) else { return }
        let runningCommand = dependencies.launch { [weak self] result in
            self?.commandFinished(result, requestID: requestID)
        }
        // Injected launchers may reply synchronously, or a snapshot observer may
        // cancel the operation while it is being published.
        if isCurrent(requestID, phase: .requesting) {
            command = runningCommand
        } else {
            runningCommand.cancel()
        }
    }

    private func commandFinished(_ result: CommandResult, requestID: UInt64) {
        guard isCurrent(requestID, phase: .requesting) else { return }
        let timer = stageTimer
        stageTimer = nil
        command = nil
        timer?.cancel()
        guard isCurrent(requestID, phase: .requesting) else { return }
        switch result {
        case .launchFailed:
            finish(failure: .commandLaunchFailed)
            return
        case .finished(let exitStatus, _, let stderr):
            // Apple's pmset can print an API failure while still exiting 0.
            guard exitStatus == 0,
                  stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                finish(failure: .commandFailed)
                return
            }
        }

        confirmationDeadline = dependencies.uptime() + Self.confirmationTimeout
        snapshot = Snapshot(phase: .confirming)
        guard isCurrent(requestID, phase: .confirming) else { return }
        scheduleStage(after: Self.confirmationTimeout, requestID: requestID, phase: .confirming) { [weak self] in
            guard let self, self.isCurrent(requestID, phase: .confirming) else { return }
            self.confirm(requestID: requestID, isFinalCheck: true)
        }
        confirm(requestID: requestID)
    }

    private func confirm(requestID: UInt64, isFinalCheck: Bool = false) {
        guard isCurrent(requestID, phase: .confirming) else { return }
        let oldPoll = pollTimer
        pollTimer = nil
        oldPoll?.cancel()
        guard isCurrent(requestID, phase: .confirming) else { return }
        let allAsleep = dependencies.probe().allAsleep
        guard isCurrent(requestID, phase: .confirming) else { return }
        if allAsleep {
            let timer = stageTimer
            stageTimer = nil
            timer?.cancel()
            guard isCurrent(requestID, phase: .confirming) else { return }
            snapshot = Snapshot(phase: .asleep)
            return
        }
        let remaining = confirmationDeadline - dependencies.uptime()
        guard !isFinalCheck, remaining > 0 else {
            finish(failure: .confirmationTimedOut)
            return
        }
        let nextPoll = dependencies.schedule(min(Self.confirmationPollInterval, remaining)) { [weak self] in
            self?.confirm(requestID: requestID)
        }
        if isCurrent(requestID, phase: .confirming) {
            pollTimer = nextPoll
        } else {
            nextPoll.cancel()
        }
    }

    private func handle(_ event: ScreenEvent, requestID: UInt64) {
        guard generation == requestID, snapshot.phase != .idle else { return }
        switch event {
        case .displaysSlept:
            // A notification alone does not prove every current display is off.
            // Sleep notifications received before the command completes are
            // covered by its immediate post-completion probe.
            confirm(requestID: requestID)
        case .displaysWoke, .systemWillSleep, .systemDidWake:
            cancel()
        case .topologyChanged:
            switch snapshot.phase {
            case .preparing, .scheduled:
                _ = validateTopology(requestID: requestID)
            case .confirming:
                confirm(requestID: requestID)
            case .asleep:
                refreshDisplayState()
            case .idle, .requesting:
                break
            }
        }
    }

    /// A pending manual request belongs to the complete topology at click time.
    /// A changed topology cancels normally; an unreadable topology fails closed.
    private func validateTopology(requestID: UInt64) -> Bool {
        guard generation == requestID, snapshot.phase != .idle else { return false }
        let current = dependencies.topology()
        guard generation == requestID, snapshot.phase != .idle else { return false }
        guard let requestedTopology, requestedTopology.isKnown, current.isKnown else {
            finish(failure: .preparationFailed, preparationFailure: .topologyUnknown)
            return false
        }
        guard current == requestedTopology else {
            cancel()
            return false
        }
        return true
    }

    private func scheduleTopologyCheck(requestID: UInt64) {
        guard generation == requestID,
              snapshot.phase == .preparing || snapshot.phase == .scheduled else { return }
        let timer = dependencies.schedule(Self.topologyPollInterval) { [weak self] in
            guard let self, self.generation == requestID,
                  self.snapshot.phase == .preparing || self.snapshot.phase == .scheduled else { return }
            self.topologyTimer = nil
            guard self.validateTopology(requestID: requestID) else { return }
            self.scheduleTopologyCheck(requestID: requestID)
        }
        if generation == requestID, snapshot.phase == .preparing || snapshot.phase == .scheduled {
            topologyTimer = timer
        } else {
            timer.cancel()
        }
    }

    private func scheduleStage(
        after delay: TimeInterval,
        requestID: UInt64,
        phase: Phase,
        action: @escaping () -> Void
    ) {
        guard isCurrent(requestID, phase: phase) else { return }
        let timer = dependencies.schedule(delay, action)
        if isCurrent(requestID, phase: phase) {
            stageTimer = timer
        } else {
            timer.cancel()
        }
    }

    private func isCurrent(_ requestID: UInt64, phase: Phase) -> Bool {
        generation == requestID && snapshot.phase == phase
    }

    private func finish(
        failure: Failure?,
        preparationFailure: AllDisplaysSleepPreparationFailure? = nil
    ) {
        // Invalidate first: cancellation callbacks may themselves be delivered
        // synchronously by a command adapter or fake scheduler.
        generation &+= 1
        let finishingGeneration = generation
        let oldStageTimer = stageTimer
        let oldPollTimer = pollTimer
        let oldTopologyTimer = topologyTimer
        let oldCommand = command
        let oldObservation = observation
        stageTimer = nil
        pollTimer = nil
        topologyTimer = nil
        command = nil
        observation = nil
        requestedTopology = nil
        revalidatePreparation = nil
        oldStageTimer?.cancel()
        oldPollTimer?.cancel()
        oldTopologyTimer?.cancel()
        oldCommand?.cancel()
        oldObservation?.cancel()
        guard generation == finishingGeneration else { return }
        snapshot = Snapshot(phase: .idle, failure: failure, preparationFailure: preparationFailure)
    }
}

/// Uses the documented OS CLI, which selects the appropriate privileged Apple
/// display-control implementation for the installed macOS version. It runs as
/// the existing user and never shells, asks for authorization, or changes prefs.
private enum AllDisplaysSleepProcess {
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()

        func drain(_ handle: FileHandle) {
            defer { try? handle.close() }
            do {
                while let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty {
                    lock.lock()
                    // Keep diagnostics bounded while continuing to drain a
                    // chatty child so it cannot block on a full pipe.
                    bytes.append(chunk.prefix(max(0, 16_384 - bytes.count)))
                    lock.unlock()
                }
            } catch {
                lock.lock()
                if bytes.isEmpty { bytes = Data("output-read-failed".utf8) }
                lock.unlock()
            }
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    static func launch(
        completion: @escaping (AllDisplaysSleepController.CommandResult) -> Void
    ) -> AllDisplaysSleepController.Cancellation {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let out = Output()
        let err = Output()
        let readers = DispatchGroup()
        readers.enter()
        readers.enter()
        process.terminationHandler = { finished in
            DispatchQueue.global(qos: .userInitiated).async {
                readers.wait()
                let result = AllDisplaysSleepController.CommandResult.finished(
                    exitStatus: finished.terminationStatus,
                    stdout: out.text,
                    stderr: err.text
                )
                Task { @MainActor in completion(result) }
            }
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            try? stdout.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForReading.close()
            try? stderr.fileHandleForWriting.close()
            Task { @MainActor in completion(.launchFailed) }
            return AllDisplaysSleepController.Cancellation()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            out.drain(stdout.fileHandleForReading)
            readers.leave()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            err.drain(stderr.fileHandleForReading)
            readers.leave()
        }
        return AllDisplaysSleepController.Cancellation {
            if process.isRunning { process.terminate() }
        }
    }
}
