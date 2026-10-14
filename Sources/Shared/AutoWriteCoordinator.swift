import Foundation

/// Tracks the one system write auto mode is allowed to have outstanding.
///
/// Auto mode writes from places that can fire while an earlier write is still
/// resolving: the poll tick, and adopting a state observed from outside. On the
/// privileged-helper path `setEnabled` only *dispatches* the write — the reply,
/// the read-back, and any mismatch all land later, in a separate turn. A claim
/// scoped to the call that issued the write is therefore worthless: it is
/// already released by the time the reply arrives, so a write that reads back
/// wrong immediately asks for another, recursing through the mismatch path and
/// queueing XPC retries that supersede each other's callbacks.
///
/// So the claim spans the whole write — `issued` until `resolved` — and a
/// resolution does *not* reopen writing in the same turn.
///
/// Recovery is a poll tick, but a tick cannot simply drop the claim: it carries
/// no evidence that the request it would drop is finished. A tick landing a
/// moment after a dispatch would otherwise send a second write while the first
/// is still alive. So `advanceTick()` retires a claim over *two* ticks — an
/// outstanding write loses this tick's attempt and only reopens on the next one
/// — which gives the two properties that make a claim safe to hold across an
/// async boundary:
///
/// - A concluded write always gets another attempt, one tick later.
/// - A claim that never concludes cannot wedge the feature: worst case two ticks
///   pass and writing reopens on the assumption the reply was lost.
///
/// That second property is only safe because the reply is bounded. The helper
/// call resolves within its own timeout whether or not the daemon answers — the
/// deadline is armed unconditionally alongside the request — and that bound is
/// several times shorter than the poll interval. So by the tick that demotes a
/// claim, its callback has already run; reopening a tick after *that* cannot
/// dispatch alongside a pending one. (The timeout settles the callback, not the
/// message: a daemon that eventually processes a timed-out request is the
/// existing failure path's problem, and writing the flag is idempotent.)
///
/// `clear()` is the deliberate exception, for when something genuinely takes the
/// flag away from auto mode — a user-driven reconcile, or a write from another
/// origin. Those supersede the outstanding reply rather than racing it.
public struct AutoWriteCoordinator: Equatable {
    public enum State: Equatable {
        /// Nothing outstanding — auto mode may write.
        case idle
        /// A write was dispatched and hasn't resolved yet. On the helper path
        /// this spans the XPC round trip and the read-back that follows it.
        case inFlight(target: Bool)
        /// A write resolved this turn, whatever its outcome. Another attempt
        /// waits for the next tick rather than chasing the result immediately.
        case deferred
    }

    public private(set) var state: State

    public init(state: State = .idle) {
        self.state = state
    }

    /// Whether auto mode may dispatch a write right now.
    public var mayWrite: Bool { state == .idle }

    /// The target of the write currently outstanding, if there is one.
    public var inFlightTarget: Bool? {
        guard case .inFlight(let target) = state else { return nil }
        return target
    }

    /// Auto mode dispatched a write.
    public mutating func issued(target: Bool) {
        state = .inFlight(target: target)
    }

    /// The outstanding write reached a conclusion — confirmed, contradicted by
    /// the read-back, unverifiable, or failed outright. All of them defer the
    /// next attempt to the following tick; the distinction between them is the
    /// caller's business, not this type's.
    ///
    /// Ignored unless a write is actually outstanding, so a late reply that lost
    /// its claim — to `clear()`, or to a tick that already demoted it — can't
    /// retroactively defer a fresh claim or reopen a deferral early.
    public mutating func resolved() {
        guard case .inFlight = state else { return }
        state = .deferred
    }

    /// A new poll tick began.
    ///
    /// A concluded write reopens here — that is the retry. An *outstanding* one
    /// does not: the tick boundary says nothing about whether the request is
    /// finished, and reopening on it would dispatch a second write alongside a
    /// live first. It is demoted instead, so it forfeits this tick's attempt and
    /// reopens on the next — the point by which a reply that was coming would
    /// have come, and a lost one can be written off.
    public mutating func advanceTick() {
        switch state {
        case .idle:
            break
        case .inFlight:
            state = .deferred
        case .deferred:
            state = .idle
        }
    }

    /// Drop any claim and allow a write immediately, superseding whatever is
    /// outstanding. Only for the paths that genuinely take the flag away from
    /// auto mode: a reconcile the user just drove, and a write from another
    /// origin. In both cases auto mode's pending reply, if one is still in
    /// flight, is rejected as superseded rather than raced.
    ///
    /// Not for the poll tick — see `advanceTick()`, which exists because a tick
    /// has no such authority over a live request.
    public mutating func clear() {
        state = .idle
    }
}
