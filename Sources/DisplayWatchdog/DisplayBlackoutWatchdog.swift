import CoreGraphics
import Darwin
import Foundation

/// Snapshot of the last HID event at arm time. The comparison uses an event's
/// derived uptime, not a small idle-duration threshold, so input remains
/// detectable after the panel has been black for minutes or hours.
public struct DisplayBlackoutHIDBaseline: Equatable {
    public static let newerEventTolerance: TimeInterval = 0.020

    public let lastInputUptime: TimeInterval

    public init?(systemUptime: TimeInterval, idleSeconds: TimeInterval) {
        guard systemUptime.isFinite,
              idleSeconds.isFinite,
              systemUptime >= 0,
              idleSeconds >= 0 else { return nil }
        lastInputUptime = max(0, systemUptime - idleSeconds)
    }

    public func hasNewerInput(
        systemUptime: TimeInterval,
        idleSeconds: TimeInterval,
        tolerance: TimeInterval = Self.newerEventTolerance
    ) -> Bool {
        guard systemUptime.isFinite,
              idleSeconds.isFinite,
              tolerance.isFinite,
              systemUptime >= 0,
              idleSeconds >= 0,
              tolerance >= 0 else { return false }
        let observedLastInputUptime = max(0, systemUptime - idleSeconds)
        return observedLastInputUptime > lastInputUptime + tolerance
    }
}

/// A permission-free snapshot of aggregate HID state. CoreGraphics exposes
/// both the last input's idle duration and per-event counters without an event
/// tap, so the watchdog can distinguish a fresh click/key press from the
/// initiating gesture's release while the panel is black.
public struct DisplayBlackoutHIDSnapshot: Equatable {
    public let sampledAtUptime: TimeInterval
    public let lastInputUptime: TimeInterval
    public let eventCounters: [UInt32: UInt32]

    public init?(
        systemUptime: TimeInterval,
        idleSeconds: TimeInterval,
        eventCounters: [UInt32: UInt32]
    ) {
        guard let baseline = DisplayBlackoutHIDBaseline(
            systemUptime: systemUptime,
            idleSeconds: idleSeconds
        ) else { return nil }
        sampledAtUptime = systemUptime
        lastInputUptime = baseline.lastInputUptime
        self.eventCounters = eventCounters
    }
}

public enum DisplayBlackoutHIDGateDecision: Equatable {
    case noNewInput
    case suppressedDuringGrace
    case restore
}

/// Consumes release/movement/drag/scroll input through the grace deadline,
/// while a genuinely new mouse-down or ordinary key-down always restores.
/// Event counters prevent an input consumed during grace from being replayed
/// as "new" after the deadline.
public struct DisplayBlackoutHIDInputGate {
    public static let graceDuration: TimeInterval = 1.5

    private static let immediateRestoreEventTypes: Set<UInt32> = [
        CGEventType.leftMouseDown.rawValue,
        CGEventType.rightMouseDown.rawValue,
        CGEventType.otherMouseDown.rawValue,
        CGEventType.keyDown.rawValue,
    ]

    public let graceDeadlineUptime: TimeInterval

    private var observedCounters: [UInt32: UInt32]
    private var observedLastInputUptime: TimeInterval

    public init?(
        armedAtUptime: TimeInterval,
        baseline: DisplayBlackoutHIDSnapshot,
        graceDuration: TimeInterval = Self.graceDuration
    ) {
        guard armedAtUptime.isFinite,
              graceDuration.isFinite,
              armedAtUptime >= 0,
              graceDuration >= 0 else { return nil }
        let deadline = armedAtUptime + graceDuration
        guard deadline.isFinite else { return nil }

        graceDeadlineUptime = deadline
        observedCounters = baseline.eventCounters
        observedLastInputUptime = baseline.lastInputUptime
    }

    public mutating func observe(
        _ snapshot: DisplayBlackoutHIDSnapshot
    ) -> DisplayBlackoutHIDGateDecision {
        var changedEventTypes = Set<UInt32>()
        for (eventType, counter) in snapshot.eventCounters {
            if observedCounters[eventType] != counter {
                changedEventTypes.insert(eventType)
            }
            observedCounters[eventType] = counter
        }

        // Keep the old 20 ms tolerance only as a fallback for an input type
        // outside the complete public CGEventType counter list. Tracked events
        // use counters, so a first movement just after 1.5 s is not delayed.
        let hasUntrackedNewInput = snapshot.lastInputUptime
            > observedLastInputUptime + DisplayBlackoutHIDBaseline.newerEventTolerance
        observedLastInputUptime = max(
            observedLastInputUptime,
            snapshot.lastInputUptime
        )

        guard !changedEventTypes.isEmpty || hasUntrackedNewInput else {
            return .noNewInput
        }
        if !changedEventTypes.isDisjoint(with: Self.immediateRestoreEventTypes) {
            return .restore
        }

        return snapshot.lastInputUptime <= graceDeadlineUptime
            ? .suppressedDuringGrace
            : .restore
    }
}

private let displayBlackoutMonitoredHIDEventTypes: [CGEventType] = [
    .leftMouseDown,
    .leftMouseUp,
    .rightMouseDown,
    .rightMouseUp,
    .mouseMoved,
    .leftMouseDragged,
    .rightMouseDragged,
    .keyDown,
    .keyUp,
    .flagsChanged,
    .scrollWheel,
    .tabletPointer,
    .tabletProximity,
    .otherMouseDown,
    .otherMouseUp,
    .otherMouseDragged,
]

public struct DisplayBlackoutWatchdogDependencies {
    public let controller: BuiltInDisplayBrightnessController
    public let journalStore: DisplayBlackoutJournalStore
    public let hidInputSnapshot: () -> DisplayBlackoutHIDSnapshot?
    public let systemUptime: () -> TimeInterval
    public let pollIntervalMilliseconds: Int32

    public init(
        controller: BuiltInDisplayBrightnessController,
        journalStore: DisplayBlackoutJournalStore,
        hidInputSnapshot: @escaping () -> DisplayBlackoutHIDSnapshot?,
        systemUptime: @escaping () -> TimeInterval,
        pollIntervalMilliseconds: Int32 = 100
    ) {
        self.controller = controller
        self.journalStore = journalStore
        self.hidInputSnapshot = hidInputSnapshot
        self.systemUptime = systemUptime
        self.pollIntervalMilliseconds = max(25, min(pollIntervalMilliseconds, 1_000))
    }

    public static func system(
        journalStore: DisplayBlackoutJournalStore = DisplayBlackoutJournalStore()
    ) throws -> DisplayBlackoutWatchdogDependencies {
        let anyInputEvent = CGEventType(rawValue: UInt32.max)!
        return DisplayBlackoutWatchdogDependencies(
            controller: try .system(),
            journalStore: journalStore,
            hidInputSnapshot: {
                let counters = Dictionary(uniqueKeysWithValues:
                    displayBlackoutMonitoredHIDEventTypes.map { eventType in
                        (
                            eventType.rawValue,
                            CGEventSource.counterForEventType(
                                .hidSystemState,
                                eventType: eventType
                            )
                        )
                    }
                )
                // Sample monotonic uptime before reading the aggregate idle
                // duration. The derived event uptime can therefore skew only
                // slightly earlier by the query cost, never later across the
                // grace deadline and cause a premature restore. Reading the
                // counters first still makes a racing event visible either by
                // the aggregate timestamp now or by its counter next poll.
                let sampledAtUptime = ProcessInfo.processInfo.systemUptime
                let idleSeconds = CGEventSource.secondsSinceLastEventType(
                    .hidSystemState,
                    eventType: anyInputEvent
                )
                return DisplayBlackoutHIDSnapshot(
                    systemUptime: sampledAtUptime,
                    idleSeconds: idleSeconds,
                    eventCounters: counters
                )
            },
            systemUptime: { ProcessInfo.processInfo.systemUptime }
        )
    }
}

/// One process, one generation. Status and immediately successful recovery are
/// one-shot operations. A pending recovery remains alive until the built-in
/// panel returns. A successfully armed request emits `.armed`, remains
/// alive, then emits one unsolicited final `.restored` response for HID input,
/// external hot-plug, EOF, or an accepted explicit restore. When the built-in
/// panel is temporarily offline, it first emits a pending response and keeps
/// retrying until recovery succeeds.
public final class DisplayBlackoutWatchdog {
    public static let successExitCode: Int32 = 0
    public static let requestErrorExitCode: Int32 = 64
    public static let operationErrorExitCode: Int32 = 70

    private let inputDescriptor: Int32
    private let outputDescriptor: Int32
    private let dependencies: DisplayBlackoutWatchdogDependencies

    public init(
        inputDescriptor: Int32 = STDIN_FILENO,
        outputDescriptor: Int32 = STDOUT_FILENO,
        dependencies: DisplayBlackoutWatchdogDependencies
    ) {
        self.inputDescriptor = inputDescriptor
        self.outputDescriptor = outputDescriptor
        self.dependencies = dependencies
    }

    @discardableResult
    public func run() -> Int32 {
        // A dead parent must be observed through stdin EOF and must never kill
        // us through stdout SIGPIPE before compare-before-restore completes.
        _ = Darwin.fcntl(outputDescriptor, F_SETNOSIGPIPE, 1)

        let request: DisplayBlackoutRequest
        do {
            guard let received = try DisplayBlackoutFrameCodec.read(
                DisplayBlackoutRequest.self,
                from: inputDescriptor
            ) else { return Self.requestErrorExitCode }
            request = received
        } catch {
            return Self.requestErrorExitCode
        }

        if let failure = request.validationFailure {
            let status: DisplayBlackoutResponseStatus = failure == .protocolMismatch
                ? .protocolMismatch
                : .invalidRequest
            send(DisplayBlackoutResponse(
                token: request.token,
                generation: request.generation,
                status: status,
                failureCode: failure.rawValue
            ))
            return Self.requestErrorExitCode
        }

        switch request.action {
        case .status:
            return runStatus(request)
        case .recover:
            return runOneShotRecovery(request, trigger: .startupRecovery, matchesIdentity: false)
        case .restore:
            return runOneShotRecovery(request, trigger: .requested, matchesIdentity: true)
        case .arm:
            return runArm(request)
        }
    }

    private func runStatus(_ request: DisplayBlackoutRequest) -> Int32 {
        do {
            if let journal = try dependencies.journalStore.load() {
                let capability = dependencies.controller.blackoutCapability()
                send(DisplayBlackoutResponse(
                    token: request.token,
                    generation: request.generation,
                    status: capability.responseStatus,
                    journalPhase: journal.phase,
                    recoveryPending: true
                ))
            } else {
                let capability = dependencies.controller.blackoutCapability()
                send(response(
                    request: request,
                    status: capability.responseStatus
                ))
            }
            return Self.successExitCode
        } catch {
            send(failureResponse(request, code: "journal_read"))
            return Self.operationErrorExitCode
        }
    }

    private func runOneShotRecovery(
        _ request: DisplayBlackoutRequest,
        trigger: DisplayBlackoutRestoreTrigger,
        matchesIdentity: Bool
    ) -> Int32 {
        var lastPendingReason: PendingRecoveryReason?
        while true {
            do {
                let result = try dependencies.controller.restoreIfNeeded(
                    journalStore: dependencies.journalStore,
                    matchingToken: matchesIdentity ? request.token : nil,
                    generation: matchesIdentity ? request.generation : nil
                )
                let currentResponse = recoveryResponse(
                    for: result,
                    request: request,
                    trigger: trigger
                )
                if currentResponse.recoveryPending {
                    let reason = PendingRecoveryReason(currentResponse)
                    if reason != lastPendingReason {
                        send(currentResponse)
                        lastPendingReason = reason
                    }
                    // Recovery deliberately permits external endpoints. Polling
                    // here therefore restores as soon as the unique built-in
                    // panel returns even if the external topology is unchanged,
                    // and it continues after parent stdin reaches EOF.
                    _ = Darwin.poll(
                        nil,
                        0,
                        dependencies.pollIntervalMilliseconds
                    )
                    continue
                }
                send(currentResponse)
                return Self.successExitCode
            } catch DisplayBlackoutControllerError.staleGeneration {
                send(response(request: request, status: .staleGeneration))
                return Self.requestErrorExitCode
            } catch {
                send(failureResponse(
                    request,
                    trigger: trigger,
                    code: "recovery_failed",
                    recoveryPending: ((try? dependencies.journalStore.load()) ?? nil) != nil
                ))
                return Self.operationErrorExitCode
            }
        }
    }

    private func runArm(_ request: DisplayBlackoutRequest) -> Int32 {
        // Warm up the CoreGraphics queries after the request exists, then
        // capture the initiating input immediately before arm. Do not
        // rebaseline after zeroing: its late mouseUp must be observed and
        // consumed by the grace gate rather than surfacing after 1.5 seconds.
        _ = dependencies.hidInputSnapshot()
        guard let hidBaseline = dependencies.hidInputSnapshot() else {
            send(failureResponse(request, code: "hid_baseline_unavailable"))
            return Self.operationErrorExitCode
        }

        let armResult: DisplayBlackoutArmResult
        do {
            armResult = try dependencies.controller.arm(
                token: request.token,
                generation: request.generation,
                journalStore: dependencies.journalStore
            )
        } catch {
            let pendingJournal = (try? dependencies.journalStore.load()) ?? nil
            send(DisplayBlackoutResponse(
                token: request.token,
                generation: request.generation,
                status: .failed,
                journalPhase: pendingJournal?.phase,
                recoveryPending: pendingJournal != nil,
                failureCode: "arm_failed"
            ))
            return Self.operationErrorExitCode
        }

        let armedJournal: DisplayBlackoutJournal
        switch armResult {
        case .armed(let journal), .alreadyArmed(let journal):
            armedJournal = journal
        case .blocked(let capability):
            send(response(request: request, status: capability.responseStatus))
            return Self.operationErrorExitCode
        case .recoveryPending(let capability, let journal):
            send(DisplayBlackoutResponse(
                token: request.token,
                generation: request.generation,
                status: capability.responseStatus,
                trigger: .startupRecovery,
                journalPhase: journal.phase,
                recoveryPending: true
            ))
            return Self.operationErrorExitCode
        }

        guard let hidInputGate = DisplayBlackoutHIDInputGate(
            armedAtUptime: dependencies.systemUptime(),
            baseline: hidBaseline
        ) else {
            // The panel is already black, so an unavailable monotonic clock is
            // a recovery condition, not a reason to abandon the journal.
            return runOneShotRecovery(
                request,
                trigger: .controlFailure,
                matchesIdentity: true
            )
        }

        send(DisplayBlackoutResponse(
            token: request.token,
            generation: request.generation,
            status: .armed,
            journalPhase: armedJournal.phase
        ))
        return runArmedLoop(request: request, hidInputGate: hidInputGate)
    }

    private func runArmedLoop(
        request: DisplayBlackoutRequest,
        hidInputGate initialHIDInputGate: DisplayBlackoutHIDInputGate
    ) -> Int32 {
        let oldFlags = Darwin.fcntl(inputDescriptor, F_GETFL)
        if oldFlags >= 0 {
            _ = Darwin.fcntl(inputDescriptor, F_SETFL, oldFlags | O_NONBLOCK)
        }

        var decoder = DisplayBlackoutFrameStreamDecoder()
        var restoreTrigger: DisplayBlackoutRestoreTrigger?
        var lastPendingReason: PendingRecoveryReason?
        var hidInputGate = initialHIDInputGate

        while true {
            if let trigger = restoreTrigger {
                do {
                    let result = try dependencies.controller.restoreIfNeeded(
                        journalStore: dependencies.journalStore,
                        matchingToken: request.token,
                        generation: request.generation
                    )
                    let currentResponse = recoveryResponse(
                        for: result,
                        request: request,
                        trigger: trigger
                    )
                    if currentResponse.recoveryPending {
                        let reason = PendingRecoveryReason(currentResponse)
                        if reason != lastPendingReason {
                            send(currentResponse)
                            lastPendingReason = reason
                        }
                        _ = Darwin.poll(
                            nil,
                            0,
                            dependencies.pollIntervalMilliseconds
                        )
                        continue
                    } else {
                        send(currentResponse)
                        return Self.successExitCode
                    }
                } catch DisplayBlackoutControllerError.staleGeneration {
                    send(response(request: request, status: .staleGeneration))
                    return Self.operationErrorExitCode
                } catch {
                    send(failureResponse(
                        request,
                        trigger: trigger,
                        code: "recovery_failed",
                        recoveryPending: true
                    ))
                    return Self.operationErrorExitCode
                }
            }

            // A positively identified non-built-in endpoint is sufficient to
            // restore. Unknown/empty topology is not treated as external; a
            // closed panel can temporarily disappear from the online list.
            if restoreTrigger == nil,
               case .connected = dependencies.controller.externalDisplayState() {
                restoreTrigger = .externalDisplayConnected
                continue
            }

            if restoreTrigger == nil {
                guard let snapshot = dependencies.hidInputSnapshot() else {
                    restoreTrigger = .controlFailure
                    continue
                }
                if hidInputGate.observe(snapshot) == .restore {
                    restoreTrigger = .hidInput
                    continue
                }
            }

            var pollDescriptor = pollfd(
                fd: inputDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = Darwin.poll(
                &pollDescriptor,
                1,
                dependencies.pollIntervalMilliseconds
            )
            if pollResult < 0 {
                if errno == EINTR { continue }
                restoreTrigger = .controlFailure
                continue
            }
            guard pollResult > 0 else { continue }

            if (pollDescriptor.revents & Int16(POLLIN)) != 0 {
                switch consumeControlInput(request: request, decoder: &decoder) {
                case .restoreRequested:
                    restoreTrigger = .requested
                    continue
                case .staleRequest:
                    send(response(request: request, status: .staleGeneration))
                case .noCompleteFrame:
                    break
                case .endOfFile:
                    restoreTrigger = .parentPipeClosed
                    continue
                case .invalid:
                    restoreTrigger = .controlFailure
                    continue
                }
            }
            if (pollDescriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 {
                // Drain any already-buffered restore command first. If none was
                // complete, EOF itself still restores before the process exits.
                if restoreTrigger == nil { restoreTrigger = .parentPipeClosed }
            }
        }
    }

    private enum ControlInputResult {
        case restoreRequested
        case staleRequest
        case noCompleteFrame
        case endOfFile
        case invalid
    }

    private func consumeControlInput(
        request: DisplayBlackoutRequest,
        decoder: inout DisplayBlackoutFrameStreamDecoder
    ) -> ControlInputResult {
        var bytes = [UInt8](repeating: 0, count: DisplayBlackoutProtocol.maximumPayloadBytes + 4)
        while true {
            let count = Darwin.read(inputDescriptor, &bytes, bytes.count)
            if count > 0 {
                do {
                    let frames = try decoder.append(Data(bytes.prefix(count)))
                    guard let frame = frames.first else { return .noCompleteFrame }
                    let control = try DisplayBlackoutFrameCodec.decode(
                        DisplayBlackoutRequest.self,
                        from: frame
                    )
                    guard control.validationFailure == nil,
                          control.action == .restore else { return .invalid }
                    guard control.token == request.token,
                          control.generation == request.generation else {
                        return .staleRequest
                    }
                    return .restoreRequested
                } catch {
                    return .invalid
                }
            }
            if count == 0 {
                do { try decoder.finish() }
                catch { return .invalid }
                return .endOfFile
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return .noCompleteFrame }
            return .invalid
        }
    }

    /// A returning panel can change an offline recovery into a brightness API
    /// failure. Publish that distinction without repeating the same pending
    /// response on every poll, and retain the existing response wire format.
    private struct PendingRecoveryReason: Equatable {
        let status: DisplayBlackoutResponseStatus
        let failureCode: String?

        init(_ response: DisplayBlackoutResponse) {
            status = response.status
            failureCode = response.failureCode
        }
    }

    private func recoveryResponse(
        for result: DisplayBlackoutRestoreResult,
        request: DisplayBlackoutRequest,
        trigger: DisplayBlackoutRestoreTrigger
    ) -> DisplayBlackoutResponse {
        switch result {
        case .noJournal:
            return response(
                request: request,
                status: .noRecoveryNeeded,
                trigger: trigger
            )
        case .restored, .userAlreadyRestored:
            return response(request: request, status: .restored, trigger: trigger)
        case .pending(let capability, let journal):
            return DisplayBlackoutResponse(
                token: request.token,
                generation: request.generation,
                status: capability.responseStatus,
                trigger: trigger,
                journalPhase: journal.phase,
                recoveryPending: true
            )
        }
    }

    private func failureResponse(
        _ request: DisplayBlackoutRequest,
        trigger: DisplayBlackoutRestoreTrigger? = nil,
        code: String,
        recoveryPending: Bool = false
    ) -> DisplayBlackoutResponse {
        DisplayBlackoutResponse(
            token: request.token,
            generation: request.generation,
            status: .failed,
            trigger: trigger,
            recoveryPending: recoveryPending,
            failureCode: code
        )
    }

    private func response(
        request: DisplayBlackoutRequest,
        status: DisplayBlackoutResponseStatus,
        trigger: DisplayBlackoutRestoreTrigger? = nil
    ) -> DisplayBlackoutResponse {
        DisplayBlackoutResponse(
            token: request.token,
            generation: request.generation,
            status: status,
            trigger: trigger
        )
    }

    private func send(_ response: DisplayBlackoutResponse) {
        try? DisplayBlackoutFrameCodec.write(response, to: outputDescriptor)
    }
}
