import Foundation

enum AudioInputSwitchPresentation: Equatable, Sendable {
    case needsConfiguration
    case switching
    case cooldown
    case currentInputInUse
    case currentInputActivityUnknown
    case currentInputReconnecting(String)
    case currentInputUnstable
    case targetReconnecting(String)
    case targetUnstable
    case targetUnavailable(String)
    case ready(String)

    var allowsButtonAction: Bool {
        switch self {
        case .needsConfiguration, .ready:
            return true
        case .switching, .cooldown, .currentInputInUse,
             .currentInputActivityUnknown, .currentInputReconnecting,
             .currentInputUnstable, .targetReconnecting, .targetUnstable,
             .targetUnavailable:
            return false
        }
    }

    /// Resolves only the states that block switching because of the current
    /// default input. Connection stability is intentionally evaluated before
    /// availability and activity: Core Audio reports a reconnecting device as
    /// unavailable, but that must not degrade into the less useful "activity
    /// unknown" presentation.
    static func blockingCurrentInputState(
        displayName: String,
        stability: AudioInputSwitchObservedStability,
        observationIsTrustworthy: Bool,
        isAvailable: Bool,
        isRunningSomewhere: Bool?
    ) -> AudioInputSwitchPresentation? {
        switch stability {
        case .reconnecting:
            return .currentInputReconnecting(displayName)
        case .unstable:
            return .currentInputUnstable
        case .stable:
            break
        }

        guard observationIsTrustworthy, isAvailable else {
            return .currentInputActivityUnknown
        }
        switch isRunningSomewhere {
        case true:
            return .currentInputInUse
        case nil:
            return .currentInputActivityUnknown
        case false:
            return nil
        }
    }

    /// A controller state error is useful only while it still describes the
    /// live button state. Operation-result errors use a separate path and stay
    /// visible until the controller replaces them.
    func matches(_ notice: AudioInputSwitchStateNotice) -> Bool {
        switch (self, notice) {
        case (.currentInputInUse, .currentInputInUse),
             (.currentInputActivityUnknown, .currentInputActivityUnknown),
             (.targetUnstable, .targetUnstable),
             (.targetUnavailable, .targetUnavailable):
            return true
        default:
            return false
        }
    }
}

enum AudioInputSwitchStateNotice: Equatable, Sendable {
    case currentInputInUse
    case currentInputActivityUnknown
    case targetUnstable
    case targetUnavailable
}

enum AudioInputSwitchObservedStability: Equatable, Sendable {
    case stable
    case reconnecting
    case unstable
}

/// Coalesces UI activations before an asynchronous audio-input switch starts.
///
/// The Core Audio controller rejects overlapping work, but a successful switch
/// can finish before the second half of a double-click is delivered. In that
/// case an in-flight-only guard would accept both activations and immediately
/// switch back. This gate owns the UI request lifetime and a short post-click
/// suppression window independently from the controller.
struct AudioInputSwitchRequestGate: Equatable, Sendable {
    static let duplicateSuppressionInterval: TimeInterval = 1
    static let minimumProgressDuration: TimeInterval = 0.25

    struct Token: Equatable, Sendable {
        let generation: UInt64
        let acceptedAt: TimeInterval
        let earliestProgressEnd: TimeInterval
    }

    private var nextGeneration: UInt64 = 0
    private var lastAcceptedAt: TimeInterval?
    private(set) var activeGeneration: UInt64?

    var hasActiveRequest: Bool {
        activeGeneration != nil
    }

    /// Accept one activation synchronously. Time is a monotonic uptime supplied
    /// by the caller so tests never sleep and wall-clock changes cannot reopen
    /// the double-click window.
    mutating func begin(at uptime: TimeInterval) -> Token? {
        guard uptime.isFinite, activeGeneration == nil else { return nil }
        if let lastAcceptedAt,
           uptime - lastAcceptedAt < Self.duplicateSuppressionInterval {
            return nil
        }

        nextGeneration &+= 1
        // Reserve zero as "no generation" even after the theoretical UInt64
        // wraparound, keeping diagnostics and optional storage unambiguous.
        if nextGeneration == 0 { nextGeneration = 1 }

        let token = Token(
            generation: nextGeneration,
            acceptedAt: uptime,
            earliestProgressEnd: uptime + Self.minimumProgressDuration
        )
        lastAcceptedAt = uptime
        activeGeneration = token.generation
        return token
    }

    /// Only the matching task may release the gate. A late completion can never
    /// clear a newer request's progress state.
    @discardableResult
    mutating func finish(_ token: Token) -> Bool {
        guard activeGeneration == token.generation else { return false }
        activeGeneration = nil
        return true
    }

    func remainingProgressDuration(
        for token: Token,
        at uptime: TimeInterval
    ) -> TimeInterval {
        guard activeGeneration == token.generation, uptime.isFinite else { return 0 }
        return max(0, token.earliestProgressEnd - uptime)
    }

    func remainingSuppressionDuration(at uptime: TimeInterval) -> TimeInterval {
        guard let lastAcceptedAt, uptime.isFinite else { return 0 }
        return max(
            0,
            Self.duplicateSuppressionInterval - (uptime - lastAcceptedAt)
        )
    }
}
