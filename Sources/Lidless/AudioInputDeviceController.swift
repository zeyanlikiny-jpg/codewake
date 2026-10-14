import Combine
import CoreAudio
import Foundation
import OSLog

enum AudioInputDeviceStability: String, Equatable, Sendable {
    case stable
    case reconnecting
    case unstable
}

struct AudioInputChoice: Identifiable, Equatable, Sendable {
    let uid: String
    let displayName: String
    let isAvailable: Bool
    let stability: AudioInputDeviceStability
    let isRunningSomewhere: Bool?

    init(
        uid: String,
        displayName: String,
        isAvailable: Bool,
        stability: AudioInputDeviceStability = .stable,
        isRunningSomewhere: Bool? = false
    ) {
        self.uid = uid
        self.displayName = displayName
        self.isAvailable = isAvailable
        self.stability = stability
        self.isRunningSomewhere = isRunningSomewhere
    }

    var id: String { uid }
    var isSwitchEligible: Bool { isAvailable && stability == .stable }
}

enum AudioInputDeviceControllerError: Error, Equatable {
    case configurationIncomplete
    case switchAlreadyInProgress
    case targetUnavailable(AudioInputSlot)
    case targetBecameUnavailable(AudioInputSlot)
    case targetUnstable(AudioInputSlot)
    case topologyChanged
    case inputInUse
    case inputActivityUnknown
    case refreshFailed
    case setFailed
    case confirmationTimedOut(AudioInputSlot)
    case observationFailed
}

struct AudioInputDeviceSnapshot: Equatable, Sendable {
    /// HAL object IDs are transient and valid only in the sampled generation.
    let objectID: UInt32
    let uid: String
    let displayName: String
    let transportType: UInt32
    let hasInput: Bool
    let isAlive: Bool
    let canBeDefaultInput: Bool
    let isHidden: Bool
    /// `nil` means Core Audio could not prove whether the device is running.
    let isRunningSomewhere: Bool?
}

struct AudioInputTopologySample: Equatable, Sendable {
    let devices: [AudioInputDeviceSnapshot]
    let defaultInputUID: String?
}

enum AudioInputSystemEvent: Hashable, Sendable {
    case devicesChanged
    case defaultInputChanged
}

final class AudioInputObservation {
    private var cancellation: (() -> Void)?

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation?()
        cancellation = nil
    }

    deinit { cancel() }
}

/// The setter is bound to one transient object ID and verifies its UID before
/// writing. A re-enumerated device is never selected by an implicit remap.
struct AudioInputDeviceClient {
    let readTopology: () throws -> AudioInputTopologySample
    let setDefaultInput: (_ objectID: UInt32, _ expectedUID: String) throws -> Void
    let observeChanges: (@escaping (AudioInputSystemEvent) -> Void) throws
        -> AudioInputObservation

    static var system: AudioInputDeviceClient {
        AudioInputDeviceClient(
            readTopology: CoreAudioInputSystem.readTopology,
            setDefaultInput: CoreAudioInputSystem.setDefaultInput,
            observeChanges: CoreAudioInputSystem.observeChanges
        )
    }
}

struct AudioInputControllerClock {
    let now: () -> TimeInterval
    let sleep: (TimeInterval) async -> Void

    static let system = AudioInputControllerClock(
        now: { ProcessInfo.processInfo.systemUptime },
        sleep: { seconds in
            let bounded = min(max(seconds, 0), Double(UInt64.max) / 1_000_000_000)
            try? await Task.sleep(nanoseconds: UInt64(bounded * 1_000_000_000))
        }
    )
}

struct AudioInputStabilityPolicy: Equatable, Sendable {
    let eventCoalesce: TimeInterval
    let reconnectWindow: TimeInterval
    let flapWindow: TimeInterval
    let recoveryQuiet: TimeInterval
    let recoveryProbeGap: TimeInterval
    let confirmationTimeout: TimeInterval
    let successStability: TimeInterval

    static let `default` = AudioInputStabilityPolicy(
        eventCoalesce: 0.2,
        reconnectWindow: 2,
        flapWindow: 20,
        recoveryQuiet: 15,
        recoveryProbeGap: 0.5,
        confirmationTimeout: 2,
        successStability: 0.5
    )
}

struct AudioInputDiagnosticEvent: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case observationStarted
        case observationFailed
        case topologyBatch
        case reconnecting
        case unstable
        case recovered
        case switchStarted
        case setterIssued
        case switchSucceeded
        case switchFailed
    }

    enum Reason: String, Equatable, Sendable {
        case none
        case devicesChanged
        case objectReenumerated
        case duplicateUID
        case readFailed
        case topologyDrift
        case unavailable
        case busy
        case activityUnknown
        case setFailed
        case confirmationTimedOut
    }

    let kind: Kind
    let reason: Reason
    let generation: UInt64
    let attempt: UInt64?
    let slot: AudioInputSlot?
    let flapCount: Int?
}

struct AudioInputDiagnosticLogger {
    let emit: (AudioInputDiagnosticEvent) -> Void

    static let system: AudioInputDiagnosticLogger = {
        let logger = Logger(subsystem: "com.kenny.lidlessai", category: "audio-input")
        return AudioInputDiagnosticLogger { event in
            // Never log names, UIDs, object IDs, or raw OSStatus values.
            logger.info(
                "event=\(event.kind.rawValue, privacy: .public) reason=\(event.reason.rawValue, privacy: .public) slot=\(event.slot?.rawValue ?? "none", privacy: .public) generation=\(event.generation, privacy: .public) attempt=\(event.attempt ?? 0, privacy: .public) flap_count=\(event.flapCount ?? 0, privacy: .public)"
            )
        }
    }()
}

@MainActor
final class AudioInputDeviceController: ObservableObject {
    @Published private(set) var availableInputs: [AudioInputChoice] = []
    @Published private(set) var defaultInputUID: String?
    @Published private(set) var topologyGeneration: UInt64 = 0
    @Published private(set) var isSwitching = false
    @Published private(set) var lastError: AudioInputDeviceControllerError?

    private struct LiveInput: Equatable {
        let objectID: UInt32
        let uid: String
        let displayName: String
        let isRunningSomewhere: Bool?

        var choice: AudioInputChoice {
            AudioInputChoice(
                uid: uid,
                displayName: displayName,
                isAvailable: true,
                isRunningSomewhere: isRunningSomewhere
            )
        }
    }

    private struct NormalizedTopology {
        let uniqueInputs: [String: LiveInput]
        let ambiguousUIDs: Set<String>
        let namesByUID: [String: String]
    }

    private struct PendingConfirmation {
        let attempt: UInt64
        let targetUID: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let client: AudioInputDeviceClient
    private let policy: AudioInputStabilityPolicy
    private let clock: AudioInputControllerClock
    private let logger: AudioInputDiagnosticLogger
    private let automaticallyObserves: Bool

    private var observation: AudioInputObservation?
    private var observationFailed = false
    private var hasInitialTopology = false
    private var liveInputs: [String: LiveInput] = [:]
    private var ambiguousUIDs: Set<String> = []
    private var knownChoices: [String: AudioInputChoice] = [:]
    private var reconnectingUIDs: Set<String> = []
    private var cycleOpenUIDs: Set<String> = []
    private var cycleCompletions: [String: [TimeInterval]] = [:]
    private var unstableUIDs: Set<String> = []
    private var topologyEventEpoch: UInt64 = 0
    private var defaultRevision: UInt64 = 0
    private var nextAttempt: UInt64 = 0

    private var deviceBatchToken: UUID?
    private var deviceBatchTask: Task<Void, Never>?
    private var defaultArbitrationToken: UUID?
    private var defaultArbitrationTask: Task<Void, Never>?
    private var deferredDefaultCandidate: String??
    private var lossTokens: [String: UUID] = [:]
    private var lossTasks: [String: Task<Void, Never>] = [:]
    private var recoveryTokens: [String: UUID] = [:]
    private var recoveryTasks: [String: Task<Void, Never>] = [:]
    private var confirmationTask: Task<Void, Never>?
    private var pendingConfirmation: PendingConfirmation?

    init(
        client: AudioInputDeviceClient = .system,
        policy: AudioInputStabilityPolicy = .default,
        clock: AudioInputControllerClock = .system,
        logger: AudioInputDiagnosticLogger = .system,
        automaticallyObserves: Bool = true
    ) {
        self.client = client
        self.policy = policy
        self.clock = clock
        self.logger = logger
        self.automaticallyObserves = automaticallyObserves

        if automaticallyObserves { startObservationIfNeeded() }
        refresh()
    }

    deinit {
        observation?.cancel()
        deviceBatchTask?.cancel()
        defaultArbitrationTask?.cancel()
        confirmationTask?.cancel()
        lossTasks.values.forEach { $0.cancel() }
        recoveryTasks.values.forEach { $0.cancel() }
    }

    func refresh() {
        startObservationIfNeeded()
        do {
            let sample = try client.readTopology()
            applyTopology(sample)
            publishDefault(sample.defaultInputUID, respectingReconnectGrace: true)
            restoreReadHealthError()
        } catch {
            publishError(.refreshFailed)
            log(.topologyBatch, reason: .readFailed)
        }
    }

    func choices(retaining selections: [AudioInputSelection]) -> [AudioInputChoice] {
        var choicesByUID = Dictionary(uniqueKeysWithValues: availableInputs.map {
            ($0.uid, $0)
        })
        for selection in selections {
            guard let clean = AudioInputSwitchConfiguration(
                primary: selection,
                secondary: nil
            ).sanitized().primary else { continue }
            guard choicesByUID[clean.uid] == nil else { continue }
            choicesByUID[clean.uid] = AudioInputChoice(
                uid: clean.uid,
                displayName: clean.lastKnownName.isEmpty ? clean.uid : clean.lastKnownName,
                isAvailable: false,
                isRunningSomewhere: nil
            )
        }
        return Self.sortedChoices(Array(choicesByUID.values))
    }

    func choice(for selection: AudioInputSelection) -> AudioInputChoice {
        choices(retaining: [selection]).first(where: { $0.uid == selection.uid })
            ?? AudioInputChoice(
                uid: selection.uid,
                displayName: selection.lastKnownName.isEmpty
                    ? selection.uid
                    : selection.lastKnownName,
                isAvailable: false,
                isRunningSomewhere: nil
            )
    }

    /// Executes the exact route accepted by the click handler. It never asks
    /// the A/B router again and never retries or falls back to another device.
    @discardableResult
    func switchInput(
        route: AudioInputSwitchRoute,
        expectedTopologyGeneration: UInt64
    ) async throws -> AudioInputSwitchRoute {
        guard !isSwitching else { throw record(.switchAlreadyInProgress) }

        nextAttempt &+= 1
        if nextAttempt == 0 { nextAttempt = 1 }
        let attempt = nextAttempt
        publishSwitching(true)
        log(.switchStarted, attempt: attempt, slot: route.slot)
        defer { publishSwitching(false) }

        let preflight: AudioInputTopologySample
        do {
            preflight = try client.readTopology()
            applyTopology(preflight)
            publishDefault(preflight.defaultInputUID, respectingReconnectGrace: true)
        } catch {
            throw fail(.refreshFailed, attempt: attempt, reason: .readFailed, slot: route.slot)
        }

        guard expectedTopologyGeneration == topologyGeneration,
              route.fromUID == preflight.defaultInputUID else {
            throw fail(.topologyChanged, attempt: attempt, reason: .topologyDrift, slot: route.slot)
        }

        let normalized = normalize(preflight)
        guard let sourceUID = route.fromUID,
              !normalized.ambiguousUIDs.contains(sourceUID),
              let source = normalized.uniqueInputs[sourceUID] else {
            throw fail(.inputActivityUnknown, attempt: attempt, reason: .activityUnknown, slot: route.slot)
        }
        guard !unstableUIDs.contains(sourceUID) else {
            throw fail(.topologyChanged, attempt: attempt, reason: .topologyDrift, slot: route.slot)
        }
        switch source.isRunningSomewhere {
        case .some(true):
            throw fail(.inputInUse, attempt: attempt, reason: .busy, slot: route.slot)
        case .none:
            throw fail(.inputActivityUnknown, attempt: attempt, reason: .activityUnknown, slot: route.slot)
        case .some(false):
            break
        }

        let targetUID = route.target.uid
        if unstableUIDs.contains(targetUID) || normalized.ambiguousUIDs.contains(targetUID) {
            throw fail(.targetUnstable(route.slot), attempt: attempt, reason: .topologyDrift, slot: route.slot)
        }
        guard let target = normalized.uniqueInputs[targetUID] else {
            throw fail(.targetUnavailable(route.slot), attempt: attempt, reason: .unavailable, slot: route.slot)
        }

        let boundGeneration = topologyGeneration
        let boundEpoch = topologyEventEpoch
        log(.setterIssued, attempt: attempt, slot: route.slot)
        do {
            try client.setDefaultInput(target.objectID, targetUID)
        } catch {
            throw fail(.setFailed, attempt: attempt, reason: .setFailed, slot: route.slot)
        }

        let initiallyConfirmed: Bool
        if let sample = try? client.readTopology(), sample.defaultInputUID == targetUID {
            applyTopology(sample)
            publishDefault(targetUID, respectingReconnectGrace: false)
            initiallyConfirmed = true
        } else {
            initiallyConfirmed = await waitForConfirmation(
                attempt: attempt,
                targetUID: targetUID
            )
        }
        guard initiallyConfirmed else {
            if topologyEventEpoch != boundEpoch || topologyGeneration != boundGeneration {
                if liveInputs[targetUID] == nil {
                    throw fail(
                        .targetBecameUnavailable(route.slot),
                        attempt: attempt,
                        reason: .unavailable,
                        slot: route.slot
                    )
                }
                throw fail(
                    .topologyChanged,
                    attempt: attempt,
                    reason: .topologyDrift,
                    slot: route.slot
                )
            }
            throw fail(
                .confirmationTimedOut(route.slot),
                attempt: attempt,
                reason: .confirmationTimedOut,
                slot: route.slot
            )
        }

        let first = try readAndValidateTarget(
            uid: targetUID,
            objectID: target.objectID,
            generation: boundGeneration,
            eventEpoch: boundEpoch,
            slot: route.slot,
            attempt: attempt
        )
        applyTopology(first)
        publishDefault(first.defaultInputUID, respectingReconnectGrace: false)
        let stableDefaultRevision = defaultRevision

        await clock.sleep(policy.successStability)
        guard !Task.isCancelled else {
            throw fail(.topologyChanged, attempt: attempt, reason: .topologyDrift, slot: route.slot)
        }

        let second = try readAndValidateTarget(
            uid: targetUID,
            objectID: target.objectID,
            generation: boundGeneration,
            eventEpoch: boundEpoch,
            slot: route.slot,
            attempt: attempt
        )
        guard defaultRevision == stableDefaultRevision else {
            throw fail(.topologyChanged, attempt: attempt, reason: .topologyDrift, slot: route.slot)
        }
        applyTopology(second)
        publishDefault(second.defaultInputUID, respectingReconnectGrace: false)
        publishError(observationFailed ? .observationFailed : nil)
        log(.switchSucceeded, attempt: attempt, slot: route.slot)
        return route
    }

    private func readAndValidateTarget(
        uid: String,
        objectID: UInt32,
        generation: UInt64,
        eventEpoch: UInt64,
        slot: AudioInputSlot,
        attempt: UInt64
    ) throws -> AudioInputTopologySample {
        let sample: AudioInputTopologySample
        do {
            sample = try client.readTopology()
        } catch {
            throw fail(.refreshFailed, attempt: attempt, reason: .readFailed, slot: slot)
        }
        let normalized = normalize(sample)
        guard let target = normalized.uniqueInputs[uid] else {
            throw fail(.targetBecameUnavailable(slot), attempt: attempt, reason: .unavailable, slot: slot)
        }
        guard !normalized.ambiguousUIDs.contains(uid),
              target.objectID == objectID,
              topologyGeneration == generation,
              topologyEventEpoch == eventEpoch,
              sample.defaultInputUID == uid else {
            throw fail(.topologyChanged, attempt: attempt, reason: .topologyDrift, slot: slot)
        }
        return sample
    }

    private func handleSystemEvent(_ event: AudioInputSystemEvent) {
        switch event {
        case .devicesChanged:
            topologyEventEpoch &+= 1
            restartRecoveryTimers()
            if defaultArbitrationTask != nil {
                defaultArbitrationTask?.cancel()
                defaultArbitrationTask = nil
                defaultArbitrationToken = nil
            }
            scheduleDeviceBatchIfNeeded()
        case .defaultInputChanged:
            if deviceBatchTask == nil { scheduleDefaultArbitrationIfNeeded() }
        }
    }

    /// Fixed window: later events join it rather than resetting it, so a
    /// notification storm cannot starve the topology read.
    private func scheduleDeviceBatchIfNeeded() {
        guard deviceBatchTask == nil else { return }
        let token = UUID()
        deviceBatchToken = token
        deviceBatchTask = Task { [weak self, clock, policy] in
            await clock.sleep(policy.eventCoalesce)
            guard !Task.isCancelled else { return }
            self?.consumeDeviceBatch(token: token)
        }
    }

    private func consumeDeviceBatch(token: UUID) {
        guard deviceBatchToken == token else { return }
        deviceBatchToken = nil
        deviceBatchTask = nil
        do {
            let sample = try client.readTopology()
            applyTopology(sample)
            publishDefault(sample.defaultInputUID, respectingReconnectGrace: true)
            restoreReadHealthError()
            log(.topologyBatch, reason: .devicesChanged)
        } catch {
            publishError(.refreshFailed)
            log(.topologyBatch, reason: .readFailed)
        }
    }

    /// Pure default changes wait at most 200ms. A devices event arriving in
    /// that window cancels this path and owns the joint topology publication.
    private func scheduleDefaultArbitrationIfNeeded() {
        guard defaultArbitrationTask == nil else { return }
        let token = UUID()
        defaultArbitrationToken = token
        defaultArbitrationTask = Task { [weak self, clock, policy] in
            await clock.sleep(policy.eventCoalesce)
            guard !Task.isCancelled else { return }
            self?.consumeDefaultArbitration(token: token)
        }
    }

    private func consumeDefaultArbitration(token: UUID) {
        guard defaultArbitrationToken == token else { return }
        defaultArbitrationToken = nil
        defaultArbitrationTask = nil
        do {
            let sample = try client.readTopology()
            applyTopology(sample)
            publishDefault(sample.defaultInputUID, respectingReconnectGrace: true)
            restoreReadHealthError()
        } catch {
            publishError(.refreshFailed)
        }
    }

    private func applyTopology(_ sample: AudioInputTopologySample) {
        let normalized = normalize(sample)
        let previousInputs = liveInputs
        let previousAmbiguous = ambiguousUIDs

        if !hasInitialTopology {
            liveInputs = normalized.uniqueInputs
            ambiguousUIDs = normalized.ambiguousUIDs
            normalized.uniqueInputs.values.forEach { knownChoices[$0.uid] = $0.choice }
            normalized.namesByUID.forEach { uid, name in
                if knownChoices[uid] == nil {
                    knownChoices[uid] = AudioInputChoice(
                        uid: uid,
                        displayName: name,
                        isAvailable: false,
                        stability: .unstable,
                        isRunningSomewhere: nil
                    )
                }
            }
            hasInitialTopology = true
            advanceTopologyGeneration()
            rebuildPublishedChoices()
            return
        }

        let now = safeNow()
        var topologyChanged = previousAmbiguous != normalized.ambiguousUIDs

        for (uid, oldInput) in previousInputs {
            guard let newInput = normalized.uniqueInputs[uid] else {
                topologyChanged = true
                knownChoices[uid] = oldInput.choice
                cycleOpenUIDs.insert(uid)
                if normalized.ambiguousUIDs.contains(uid) {
                    beginReconnectGrace(uid: uid)
                    log(.unstable, reason: .duplicateUID)
                } else {
                    beginReconnectGrace(uid: uid)
                }
                continue
            }
            if oldInput.objectID != newInput.objectID {
                topologyChanged = true
                completeFlapCycle(uid: uid, at: now, reason: .objectReenumerated)
            }
        }

        // An ambiguous UID can subsequently disappear without an intermediate
        // unique sample. Preserve the original grace instead of dropping the
        // published device immediately.
        for uid in previousAmbiguous
        where normalized.uniqueInputs[uid] == nil
            && !normalized.ambiguousUIDs.contains(uid) {
            beginReconnectGrace(uid: uid)
        }

        for (uid, newInput) in normalized.uniqueInputs {
            knownChoices[uid] = newInput.choice
            if previousInputs[uid] == nil, cycleOpenUIDs.remove(uid) != nil {
                topologyChanged = true
                completeFlapCycle(uid: uid, at: now, reason: .devicesChanged)
            } else if previousInputs[uid] == nil {
                topologyChanged = true
            }
            reconnectingUIDs.remove(uid)
            cancelLossTimer(uid: uid)
        }

        for uid in normalized.ambiguousUIDs {
            if let name = normalized.namesByUID[uid], knownChoices[uid] == nil {
                knownChoices[uid] = AudioInputChoice(
                    uid: uid,
                    displayName: name,
                    isAvailable: false,
                    stability: .unstable,
                    isRunningSomewhere: nil
                )
            }
        }

        if previousInputs.count != normalized.uniqueInputs.count { topologyChanged = true }
        liveInputs = normalized.uniqueInputs
        ambiguousUIDs = normalized.ambiguousUIDs
        if topologyChanged {
            advanceTopologyGeneration()
            restartRecoveryTimers()
        }
        rebuildPublishedChoices()
    }

    private func normalize(_ sample: AudioInputTopologySample) -> NormalizedTopology {
        var groups: [String: [AudioInputDeviceSnapshot]] = [:]
        var names: [String: String] = [:]
        for snapshot in sample.devices {
            let uid = snapshot.uid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uid.isEmpty else { continue }
            groups[uid, default: []].append(snapshot)
            let name = snapshot.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            names[uid] = name.isEmpty ? uid : name
        }

        var unique: [String: LiveInput] = [:]
        var ambiguous: Set<String> = []
        for (uid, snapshots) in groups {
            guard snapshots.count == 1, let snapshot = snapshots.first else {
                ambiguous.insert(uid)
                continue
            }
            guard snapshot.hasInput,
                  snapshot.isAlive,
                  snapshot.canBeDefaultInput,
                  !snapshot.isHidden else { continue }
            unique[uid] = LiveInput(
                objectID: snapshot.objectID,
                uid: uid,
                displayName: names[uid] ?? uid,
                isRunningSomewhere: snapshot.isRunningSomewhere
            )
        }
        return NormalizedTopology(
            uniqueInputs: unique,
            ambiguousUIDs: ambiguous,
            namesByUID: names
        )
    }

    private func beginReconnectGrace(uid: String) {
        guard !reconnectingUIDs.contains(uid) else { return }
        reconnectingUIDs.insert(uid)
        let token = UUID()
        lossTokens[uid] = token
        lossTasks[uid] = Task { [weak self, clock, policy] in
            await clock.sleep(policy.reconnectWindow)
            guard !Task.isCancelled else { return }
            self?.expireReconnectGrace(uid: uid, token: token)
        }
        log(.reconnecting, reason: .devicesChanged)
    }

    private func expireReconnectGrace(uid: String, token: UUID) {
        guard lossTokens[uid] == token, liveInputs[uid] == nil else { return }
        lossTokens[uid] = nil
        lossTasks[uid] = nil
        reconnectingUIDs.remove(uid)
        rebuildPublishedChoices()

        // A non-default device can share the same timer deadline. It must not
        // release a deferred default while the actual old default is still in
        // its own reconnect window.
        if defaultInputUID.map(reconnectingUIDs.contains) == true { return }
        if let deferredDefaultCandidate {
            publishDefault(deferredDefaultCandidate, respectingReconnectGrace: false)
            self.deferredDefaultCandidate = nil
        } else if let sample = try? client.readTopology() {
            publishDefault(sample.defaultInputUID, respectingReconnectGrace: false)
        }
    }

    private func cancelLossTimer(uid: String) {
        lossTasks[uid]?.cancel()
        lossTasks[uid] = nil
        lossTokens[uid] = nil
    }

    private func completeFlapCycle(
        uid: String,
        at now: TimeInterval,
        reason: AudioInputDiagnosticEvent.Reason
    ) {
        var completions = cycleCompletions[uid, default: []]
        completions.removeAll { now - $0 > policy.flapWindow || now < $0 }
        completions.append(now)
        cycleCompletions[uid] = completions
        guard completions.count >= 2 else { return }
        if unstableUIDs.insert(uid).inserted {
            advanceTopologyGeneration()
            log(.unstable, reason: reason, flapCount: completions.count)
            scheduleRecovery(uid: uid)
        }
    }

    private func restartRecoveryTimers() {
        for uid in unstableUIDs { scheduleRecovery(uid: uid) }
    }

    private func scheduleRecovery(uid: String) {
        recoveryTasks[uid]?.cancel()
        let token = UUID()
        recoveryTokens[uid] = token
        recoveryTasks[uid] = Task { [weak self, clock, policy] in
            await clock.sleep(policy.recoveryQuiet)
            guard !Task.isCancelled else { return }
            await self?.attemptRecovery(uid: uid, token: token)
        }
    }

    private func attemptRecovery(uid: String, token: UUID) async {
        guard recoveryTokens[uid] == token, unstableUIDs.contains(uid) else { return }
        let epoch = topologyEventEpoch
        guard let first = recoveryProbe(uid: uid) else {
            scheduleRecovery(uid: uid)
            return
        }
        await clock.sleep(policy.recoveryProbeGap)
        guard !Task.isCancelled, recoveryTokens[uid] == token else { return }
        guard topologyEventEpoch == epoch,
              let second = recoveryProbe(uid: uid),
              second.objectID == first.objectID else {
            // A failed second proof is not terminal. Keep fail-closed and start
            // a fresh quiet interval even if Core Audio sends no later event.
            scheduleRecovery(uid: uid)
            return
        }
        guard liveInputs[uid]?.objectID == second.objectID else {
            scheduleRecovery(uid: uid)
            return
        }

        unstableUIDs.remove(uid)
        recoveryTokens[uid] = nil
        recoveryTasks[uid] = nil
        cycleCompletions[uid] = []
        liveInputs[uid] = second
        knownChoices[uid] = second.choice
        advanceTopologyGeneration()
        rebuildPublishedChoices()
        if case .targetUnstable = lastError { publishError(nil) }
        log(.recovered)
    }

    private func recoveryProbe(uid: String) -> LiveInput? {
        guard let sample = try? client.readTopology() else { return nil }
        let normalized = normalize(sample)
        guard !normalized.ambiguousUIDs.contains(uid) else { return nil }
        return normalized.uniqueInputs[uid]
    }

    private func rebuildPublishedChoices() {
        var choices: [AudioInputChoice] = liveInputs.map { uid, input in
            AudioInputChoice(
                uid: uid,
                displayName: input.displayName,
                isAvailable: true,
                stability: unstableUIDs.contains(uid) ? .unstable : .stable,
                isRunningSomewhere: input.isRunningSomewhere
            )
        }
        for uid in reconnectingUIDs
        where liveInputs[uid] == nil && !ambiguousUIDs.contains(uid) {
            guard let known = knownChoices[uid] else { continue }
            choices.append(AudioInputChoice(
                uid: uid,
                displayName: known.displayName,
                isAvailable: false,
                stability: unstableUIDs.contains(uid) ? .unstable : .reconnecting,
                isRunningSomewhere: nil
            ))
        }
        for uid in ambiguousUIDs where liveInputs[uid] == nil {
            guard let known = knownChoices[uid] else { continue }
            choices.append(AudioInputChoice(
                uid: uid,
                displayName: known.displayName,
                isAvailable: false,
                stability: .unstable,
                isRunningSomewhere: nil
            ))
        }
        let sorted = Self.sortedChoices(choices)
        if availableInputs != sorted { availableInputs = sorted }
    }

    private static func sortedChoices(_ choices: [AudioInputChoice]) -> [AudioInputChoice] {
        choices.sorted { lhs, rhs in
            let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if comparison == .orderedSame { return lhs.uid < rhs.uid }
            return comparison == .orderedAscending
        }
    }

    private func publishDefault(
        _ candidate: String?,
        respectingReconnectGrace: Bool
    ) {
        if respectingReconnectGrace,
           candidate != defaultInputUID,
           defaultInputUID.map(reconnectingUIDs.contains) == true {
            deferredDefaultCandidate = .some(candidate)
            return
        }
        deferredDefaultCandidate = nil
        guard defaultInputUID != candidate else {
            completeConfirmationIfMatched(candidate)
            return
        }
        defaultInputUID = candidate
        defaultRevision &+= 1
        completeConfirmationIfMatched(candidate)
    }

    private func waitForConfirmation(attempt: UInt64, targetUID: String) async -> Bool {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                pendingConfirmation = PendingConfirmation(
                    attempt: attempt,
                    targetUID: targetUID,
                    continuation: continuation
                )
                confirmationTask = Task { [weak self, clock, policy] in
                    await clock.sleep(policy.confirmationTimeout)
                    guard !Task.isCancelled else { return }
                    self?.handleConfirmationTimeout(attempt: attempt)
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.completeConfirmation(attempt: attempt, confirmed: false)
            }
        })
    }

    private func handleConfirmationTimeout(attempt: UInt64) {
        guard pendingConfirmation?.attempt == attempt else { return }
        let confirmed: Bool
        if let sample = try? client.readTopology() {
            applyTopology(sample)
            publishDefault(sample.defaultInputUID, respectingReconnectGrace: false)
            confirmed = sample.defaultInputUID == pendingConfirmation?.targetUID
        } else {
            confirmed = false
        }
        completeConfirmation(attempt: attempt, confirmed: confirmed)
    }

    private func completeConfirmationIfMatched(_ uid: String?) {
        guard let pendingConfirmation, pendingConfirmation.targetUID == uid else { return }
        completeConfirmation(attempt: pendingConfirmation.attempt, confirmed: true)
    }

    private func completeConfirmation(attempt: UInt64, confirmed: Bool) {
        guard let pendingConfirmation, pendingConfirmation.attempt == attempt else { return }
        self.pendingConfirmation = nil
        confirmationTask?.cancel()
        confirmationTask = nil
        pendingConfirmation.continuation.resume(returning: confirmed)
    }

    private func startObservationIfNeeded() {
        guard automaticallyObserves, observation == nil else { return }
        do {
            observation = try client.observeChanges { [weak self] event in
                Task { @MainActor in self?.handleSystemEvent(event) }
            }
            observationFailed = false
            if lastError == .observationFailed { publishError(nil) }
            log(.observationStarted)
        } catch {
            observationFailed = true
            publishError(.observationFailed)
            log(.observationFailed, reason: .readFailed)
        }
    }

    private func restoreReadHealthError() {
        if observationFailed {
            publishError(.observationFailed)
        } else if lastError == .refreshFailed || lastError == .observationFailed {
            publishError(nil)
        }
    }

    private func advanceTopologyGeneration() {
        topologyGeneration &+= 1
        if topologyGeneration == 0 { topologyGeneration = 1 }
    }

    private func safeNow() -> TimeInterval {
        let value = clock.now()
        return value.isFinite && value >= 0 ? value : 0
    }

    private func publishSwitching(_ value: Bool) {
        if isSwitching != value { isSwitching = value }
    }

    private func publishError(_ value: AudioInputDeviceControllerError?) {
        if lastError != value { lastError = value }
    }

    private func record(
        _ error: AudioInputDeviceControllerError
    ) -> AudioInputDeviceControllerError {
        publishError(error)
        return error
    }

    private func fail(
        _ error: AudioInputDeviceControllerError,
        attempt: UInt64,
        reason: AudioInputDiagnosticEvent.Reason,
        slot: AudioInputSlot
    ) -> AudioInputDeviceControllerError {
        publishError(error)
        log(.switchFailed, reason: reason, attempt: attempt, slot: slot)
        return error
    }

    private func log(
        _ kind: AudioInputDiagnosticEvent.Kind,
        reason: AudioInputDiagnosticEvent.Reason = .none,
        attempt: UInt64? = nil,
        slot: AudioInputSlot? = nil,
        flapCount: Int? = nil
    ) {
        logger.emit(AudioInputDiagnosticEvent(
            kind: kind,
            reason: reason,
            generation: topologyGeneration,
            attempt: attempt,
            slot: slot,
            flapCount: flapCount
        ))
    }
}

private struct AudioInputCoreAudioError: Error {
    let operation: String
    let status: OSStatus
}

private enum CoreAudioInputSystem {
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private static let mainElement = AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
    private static let listenerQueue = DispatchQueue(
        label: "com.kenny.lidlessai.audio-input-observer",
        qos: .userInitiated
    )

    static func readTopology() throws -> AudioInputTopologySample {
        // Required-property failures invalidate the whole sample instead of
        // masquerading as a disappearance. Only activity may be unknown.
        let snapshots = try readDeviceIDs().map { deviceID in
            let uid = try stringProperty(
                object: deviceID,
                selector: kAudioDevicePropertyDeviceUID
            )
            let name = (try? stringProperty(
                object: deviceID,
                selector: kAudioObjectPropertyName
            )) ?? uid
            let transport = (try? uint32Property(
                object: deviceID,
                selector: kAudioDevicePropertyTransportType
            )) ?? 0
            let inputStreamBytes = try propertyDataSize(
                object: deviceID,
                selector: kAudioDevicePropertyStreams,
                scope: kAudioObjectPropertyScopeInput
            )
            let alive = try uint32Property(
                object: deviceID,
                selector: kAudioDevicePropertyDeviceIsAlive
            )
            let canDefault = try uint32Property(
                object: deviceID,
                selector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
                scope: kAudioObjectPropertyScopeInput
            )
            let hidden = try uint32Property(
                object: deviceID,
                selector: kAudioDevicePropertyIsHidden
            )
            let running = try? uint32Property(
                object: deviceID,
                selector: kAudioDevicePropertyDeviceIsRunningSomewhere
            )
            return AudioInputDeviceSnapshot(
                objectID: UInt32(deviceID),
                uid: uid,
                displayName: name,
                transportType: transport,
                hasInput: inputStreamBytes > 0,
                isAlive: alive == 1,
                canBeDefaultInput: canDefault == 1,
                isHidden: hidden != 0,
                isRunningSomewhere: running.map { $0 == 1 }
            )
        }
        return AudioInputTopologySample(
            devices: snapshots,
            defaultInputUID: try readDefaultInputUID()
        )
    }

    static func setDefaultInput(objectID: UInt32, expectedUID: String) throws {
        let targetID = AudioObjectID(objectID)
        guard try readDeviceIDs().contains(targetID),
              try stringProperty(
                object: targetID,
                selector: kAudioDevicePropertyDeviceUID
              ) == expectedUID else {
            throw AudioInputCoreAudioError(
                operation: "validate-input-instance",
                status: kAudioHardwareBadDeviceError
            )
        }

        var address = defaultInputAddress
        var writableTargetID = targetID
        let status = AudioObjectSetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &writableTargetID
        )
        try requireSuccess(status, operation: "set-default-input")
    }

    static func observeChanges(
        _ handler: @escaping (AudioInputSystemEvent) -> Void
    ) throws -> AudioInputObservation {
        let block: AudioObjectPropertyListenerBlock = { count, addresses in
            var events = Set<AudioInputSystemEvent>()
            for index in 0..<Int(count) {
                switch addresses[index].mSelector {
                case kAudioHardwarePropertyDevices:
                    events.insert(.devicesChanged)
                case kAudioHardwarePropertyDefaultInputDevice:
                    events.insert(.defaultInputChanged)
                default:
                    break
                }
            }
            events.forEach(handler)
        }

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: mainElement
        )
        var status = AudioObjectAddPropertyListenerBlock(
            systemObject,
            &devicesAddress,
            listenerQueue,
            block
        )
        try requireSuccess(status, operation: "observe-audio-devices")

        var defaultAddress = defaultInputAddress
        status = AudioObjectAddPropertyListenerBlock(
            systemObject,
            &defaultAddress,
            listenerQueue,
            block
        )
        if status != noErr {
            _ = AudioObjectRemovePropertyListenerBlock(
                systemObject,
                &devicesAddress,
                listenerQueue,
                block
            )
            try requireSuccess(status, operation: "observe-default-input")
        }

        return AudioInputObservation {
            var devicesAddress = devicesAddress
            var defaultAddress = defaultAddress
            _ = AudioObjectRemovePropertyListenerBlock(
                systemObject,
                &devicesAddress,
                listenerQueue,
                block
            )
            _ = AudioObjectRemovePropertyListenerBlock(
                systemObject,
                &defaultAddress,
                listenerQueue,
                block
            )
        }
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: mainElement
        )
    }

    private static func readDefaultInputUID() throws -> String? {
        var address = defaultInputAddress
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        try requireSuccess(status, operation: "read-default-input")
        guard deviceID != kAudioObjectUnknown else { return nil }
        return try stringProperty(
            object: deviceID,
            selector: kAudioDevicePropertyDeviceUID
        )
    }

    private static func readDeviceIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: mainElement
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            systemObject,
            &address,
            0,
            nil,
            &size
        )
        try requireSuccess(status, operation: "size-audio-devices")
        guard size > 0 else { return [] }

        var deviceIDs = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        status = deviceIDs.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(
                systemObject,
                &address,
                0,
                nil,
                &size,
                buffer.baseAddress!
            )
        }
        try requireSuccess(status, operation: "read-audio-devices")
        return Array(deviceIDs.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func propertyDataSize(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: mainElement
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            object,
            &address,
            0,
            nil,
            &size
        )
        try requireSuccess(status, operation: "read-property-size")
        return size
    }

    private static func uint32Property(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: mainElement
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &value
        )
        try requireSuccess(status, operation: "read-uint32-property")
        return value
    }

    private static func stringProperty(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: mainElement
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                object,
                &address,
                0,
                nil,
                &size,
                pointer
            )
        }
        try requireSuccess(status, operation: "read-string-property")
        return value as String
    }

    private static func requireSuccess(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw AudioInputCoreAudioError(operation: operation, status: status)
        }
    }
}
