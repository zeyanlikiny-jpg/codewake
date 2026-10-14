import Foundation
import IOKit.pwr_mgt

/// Injectable boundary around the two IOKit calls used by the display hold.
struct DisplaySleepAssertionAPI: @unchecked Sendable {
    typealias CreateResult = (result: IOReturn, assertionID: IOPMAssertionID)

    let create: (_ timeout: TimeInterval) -> CreateResult
    let release: (_ assertionID: IOPMAssertionID) -> IOReturn

    static let system = DisplaySleepAssertionAPI(
        create: { timeout in
            var assertionID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithDescription(
                kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                DisplaySleepAssertionController.assertionName as CFString,
                DisplaySleepAssertionController.assertionDetails as CFString,
                nil,
                nil,
                timeout,
                kIOPMAssertionTimeoutActionRelease as CFString,
                &assertionID
            )
            return (result, assertionID)
        },
        release: { assertionID in
            IOPMAssertionRelease(assertionID)
        }
    )
}

enum DisplaySleepAssertionError: Error, Equatable {
    case createFailed(code: IOReturn)
    case releaseFailed(code: IOReturn)

    /// Stable category for presentation/localization. The raw IOKit value is
    /// retained separately for diagnostics and must not become user-facing UI.
    var presentationKey: String {
        switch self {
        case .createFailed:
            return "display.assertion.error.create"
        case .releaseFailed:
            return "display.assertion.error.release"
        }
    }

    var diagnosticCode: String {
        switch self {
        case .createFailed:
            return "display_assertion_create_failed"
        case .releaseFailed:
            return "display_assertion_release_failed"
        }
    }

    var ioReturn: IOReturn {
        switch self {
        case .createFailed(let code), .releaseFailed(let code):
            return code
        }
    }
}

enum DisplaySleepAssertionResult: Equatable {
    case unchanged
    case acquired
    case renewed
    case released
    case failed(DisplaySleepAssertionError)
}

/// Owns the app-process `PreventUserIdleDisplaySleep` assertion.
///
/// Assertions expire in 90 seconds at the operating-system boundary. While a
/// hold is still desired, this controller atomically creates a replacement
/// every 30 seconds before releasing the previous ID. A hung or crashed app can
/// therefore never leave an unbounded display hold behind.
@MainActor
final class DisplaySleepAssertionController {
    nonisolated static let assertionName = "CodeWake Active Work Display Hold"
    nonisolated static let assertionDetails =
        "Prevents idle display sleep only while manual or AI work is active."
    nonisolated static let assertionTimeout: TimeInterval = 90
    nonisolated static let renewalInterval: TimeInterval = 30

    private let api: DisplaySleepAssertionAPI
    private let now: () -> Date
    private let automaticallyRenews: Bool
    private struct LiveAssertion {
        let id: IOPMAssertionID
        let expiresAt: Date
    }

    /// Usually contains one current assertion. A failed old-ID release during
    /// renewal remains here as an additional bounded orphan until a later
    /// cleanup succeeds or its 90-second system timeout elapses.
    private var liveAssertions: [LiveAssertion] = []
    private var nextRenewalAt: Date?
    private var nextReleaseAttemptAt: Date?
    private var renewalTimer: Timer?
    private var shouldHold = false

    private(set) var lastResult: DisplaySleepAssertionResult = .unchanged
    private(set) var lastError: DisplaySleepAssertionError?

    var isHolding: Bool {
        pruneExpiredAssertions(at: now())
        return !liveAssertions.isEmpty
    }

    init(
        api: DisplaySleepAssertionAPI = .system,
        now: @escaping () -> Date = Date.init,
        automaticallyRenews: Bool = true
    ) {
        self.api = api
        self.now = now
        self.automaticallyRenews = automaticallyRenews
    }

    deinit {
        renewalTimer?.invalidate()
        let current = now()
        for assertion in liveAssertions where current < assertion.expiresAt {
            _ = api.release(assertion.id)
        }
    }

    /// Applies the latest pure-policy result. Repeating the same result does
    /// not create or release an additional assertion.
    @discardableResult
    func reconcile(shouldHold: Bool) -> DisplaySleepAssertionResult {
        self.shouldHold = shouldHold
        guard shouldHold else { return release() }

        let current = now()
        pruneExpiredAssertions(at: current)
        startRenewalTimerIfNeeded()
        nextReleaseAttemptAt = nil
        clearReleaseErrorIfResolved()
        guard liveAssertions.isEmpty else {
            return finish(.unchanged, clearingError: false)
        }

        if let nextRenewalAt, current < nextRenewalAt {
            return finish(.unchanged, clearingError: false)
        }
        return acquire(at: current, result: .acquired)
    }

    /// Renews only when the 30-second boundary has elapsed. If an earlier
    /// creation failed, the same bounded cadence is also used for retry.
    @discardableResult
    func renewIfNeeded() -> DisplaySleepAssertionResult {
        guard shouldHold else { return finish(.unchanged, clearingError: false) }

        let current = now()
        pruneExpiredAssertions(at: current)
        if let nextRenewalAt, current < nextRenewalAt {
            return finish(.unchanged, clearingError: false)
        }
        guard !liveAssertions.isEmpty else {
            return acquire(at: current, result: .acquired)
        }

        let previousAssertions = liveAssertions
        let creation = api.create(Self.assertionTimeout)
        nextRenewalAt = current.addingTimeInterval(Self.renewalInterval)
        guard creation.result == kIOReturnSuccess else {
            return fail(.createFailed(code: creation.result))
        }

        let freshAssertion = LiveAssertion(
            id: creation.assertionID,
            expiresAt: current.addingTimeInterval(Self.assertionTimeout)
        )
        // Publish the fresh ID before attempting any old-ID release. Every old
        // release is attempted, and each failure remains tracked independently.
        var retainedOldAssertions: [LiveAssertion] = []
        var firstReleaseFailure: IOReturn?
        for assertion in previousAssertions {
            let result = api.release(assertion.id)
            if result != kIOReturnSuccess {
                retainedOldAssertions.append(assertion)
                if firstReleaseFailure == nil { firstReleaseFailure = result }
            }
        }
        liveAssertions = retainedOldAssertions + [freshAssertion]

        if let firstReleaseFailure {
            nextReleaseAttemptAt = current.addingTimeInterval(Self.renewalInterval)
            return fail(.releaseFailed(code: firstReleaseFailure))
        }
        nextReleaseAttemptAt = nil
        return finish(.renewed)
    }

    /// Stops renewal and releases the current assertion. Repeated calls are a
    /// no-op after a successful release. A failed release retains the ID so a
    /// later call can retry; the OS timeout still bounds the hold independently.
    @discardableResult
    func release() -> DisplaySleepAssertionResult {
        release(force: false)
    }

    /// Explicit lifecycle spelling for restore-normal-sleep and app exit. This
    /// is allowed to bypass a previous release backoff for one immediate retry.
    @discardableResult
    func stop() -> DisplaySleepAssertionResult {
        release(force: true)
    }

    private func release(force: Bool) -> DisplaySleepAssertionResult {
        shouldHold = false
        stopRenewalTimer()
        nextRenewalAt = nil
        let current = now()
        pruneExpiredAssertions(at: current)
        guard !liveAssertions.isEmpty else {
            nextReleaseAttemptAt = nil
            return finish(.unchanged)
        }

        if !force, let nextReleaseAttemptAt, current < nextReleaseAttemptAt {
            return finish(.unchanged, clearingError: false)
        }

        var retainedAssertions: [LiveAssertion] = []
        var firstReleaseFailure: IOReturn?
        for assertion in liveAssertions {
            let result = api.release(assertion.id)
            if result != kIOReturnSuccess {
                retainedAssertions.append(assertion)
                if firstReleaseFailure == nil { firstReleaseFailure = result }
            }
        }
        liveAssertions = retainedAssertions

        if let firstReleaseFailure {
            nextReleaseAttemptAt = current.addingTimeInterval(Self.renewalInterval)
            return fail(.releaseFailed(code: firstReleaseFailure))
        }
        nextReleaseAttemptAt = nil
        return finish(.released)
    }

    private func acquire(
        at date: Date,
        result successResult: DisplaySleepAssertionResult
    ) -> DisplaySleepAssertionResult {
        let creation = api.create(Self.assertionTimeout)
        nextRenewalAt = date.addingTimeInterval(Self.renewalInterval)
        guard creation.result == kIOReturnSuccess else {
            return fail(.createFailed(code: creation.result))
        }
        liveAssertions.append(LiveAssertion(
            id: creation.assertionID,
            expiresAt: date.addingTimeInterval(Self.assertionTimeout)
        ))
        return finish(successResult)
    }

    private func pruneExpiredAssertions(at date: Date) {
        let previousCount = liveAssertions.count
        liveAssertions.removeAll { date >= $0.expiresAt }
        guard liveAssertions.count != previousCount else { return }

        if liveAssertions.isEmpty { nextReleaseAttemptAt = nil }
        clearReleaseErrorIfResolved()
    }

    /// A release warning remains relevant while any assertion is unwanted: all
    /// live IDs after policy turns off, or older IDs alongside the fresh renewal
    /// while policy remains on.
    private func clearReleaseErrorIfResolved() {
        guard case .releaseFailed? = lastError else { return }
        let hasUnwantedAssertion = shouldHold
            ? liveAssertions.count > 1
            : !liveAssertions.isEmpty
        if !hasUnwantedAssertion { lastError = nil }
    }

    private func startRenewalTimerIfNeeded() {
        guard automaticallyRenews, renewalTimer == nil else { return }
        renewalTimer = Timer.scheduledTimer(
            withTimeInterval: Self.renewalInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.renewIfNeeded()
            }
        }
    }

    private func stopRenewalTimer() {
        renewalTimer?.invalidate()
        renewalTimer = nil
    }

    private func fail(_ error: DisplaySleepAssertionError) -> DisplaySleepAssertionResult {
        lastError = error
        lastResult = .failed(error)
        return lastResult
    }

    private func finish(
        _ result: DisplaySleepAssertionResult,
        clearingError: Bool = true
    ) -> DisplaySleepAssertionResult {
        if clearingError { lastError = nil }
        lastResult = result
        return result
    }
}
