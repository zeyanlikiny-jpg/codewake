import Foundation

/// Coordinates the app-side window between deciding that the final AI turn may
/// sleep and actually submitting the helper mutation. The helper version probe
/// is asynchronous, so a normal stale-reply token is insufficient: a continued
/// turn must revoke permission before the probe can submit any release at all.
public struct ConditionalSleepReleaseCoordinator: Equatable, Sendable {
    public struct Token: Equatable, Hashable, Sendable {
        fileprivate let generation: UInt64
    }

    private var nextGeneration: UInt64 = 0
    public private(set) var inFlight: Token?

    public init() {}

    public var isInFlight: Bool { inFlight != nil }

    /// Begin one conditional release. A timer tick while one is already waiting
    /// receives nil and must not submit a second release.
    public mutating func beginIfIdle() -> Token? {
        guard inFlight == nil else { return nil }
        nextGeneration &+= 1
        let token = Token(generation: nextGeneration)
        inFlight = token
        return token
    }

    /// Synchronous gate checked on the main queue immediately before either the
    /// v2 selector or legacy release selector is submitted.
    public func shouldProceed(_ token: Token) -> Bool {
        inFlight == token
    }

    /// Revoke an uncommitted release when work/sources/vetoes reappear or the
    /// relevant settings/helper lifecycle change.
    @discardableResult
    public mutating func cancel() -> Bool {
        guard inFlight != nil else { return false }
        inFlight = nil
        return true
    }

    /// Consume exactly one matching callback. A stale callback cannot clear a
    /// newer transaction or make a later timer tick repeat the old release.
    @discardableResult
    public mutating func complete(_ token: Token) -> Bool {
        guard inFlight == token else { return false }
        inFlight = nil
        return true
    }
}

public enum ConditionalSleepReleaseTransportAction: Equatable, Sendable {
    case cancelled
    case legacyRelease
    case conditionalSleepV2
}

/// Chooses whether a release needs helper-version negotiation at all. A
/// policy-only restore never submits the conditional-sleep selector, so the
/// legacy `releaseLease` method is both sufficient and safer: it is supported by
/// every helper version and can be sent immediately during a bounded Quit.
public enum SleepReleasePreparationAction: Equatable, Sendable {
    case directLeaseRelease
    case probeConditionalSleepSupport
}

public enum SleepReleasePreparationGate {
    public static func action(
        sleepMode: HelperSleepMode
    ) -> SleepReleasePreparationAction {
        sleepMode == .never ? .directLeaseRelease : .probeConditionalSleepSupport
    }
}

/// Pure routing seam used by HelperManager after its version reply. Cancellation
/// wins before both transport variants, including the legacy fallback.
public enum ConditionalSleepReleaseTransportGate {
    public static func action(
        advertisement: String?,
        shouldProceed: Bool
    ) -> ConditionalSleepReleaseTransportAction {
        guard shouldProceed else { return .cancelled }
        switch LidlessHelper.releaseTransportRoute(for: advertisement) {
        case .legacyRelease: return .legacyRelease
        case .conditionalSleepV2: return .conditionalSleepV2
        }
    }
}

/// Local ownership state after a release reply is missing or reports failure.
/// The durable helper journal remains the authority and its watchdog performs
/// eventual recovery; the app must stop heartbeating and must not hammer a
/// possibly-unreachable helper once per reconciliation tick.
public struct FailedLeaseReleaseTransition: Equatable, Sendable {
    public let helperLeaseActive: Bool
    public let aggregateWakeRequested: Bool
    public let shouldKeepHeartbeat: Bool

    public static let deferToWatchdog = FailedLeaseReleaseTransition(
        helperLeaseActive: false,
        aggregateWakeRequested: false,
        shouldKeepHeartbeat: false
    )

    /// Mirrors the idle-release branch in AppState's reconciliation.
    public var needsAnotherIdleRelease: Bool {
        !aggregateWakeRequested && helperLeaseActive
    }

    /// A later Prompt/manual source can still claim a fresh lease.
    public func needsAcquire(whenWakeRequested shouldWake: Bool) -> Bool {
        shouldWake && !aggregateWakeRequested
    }
}
