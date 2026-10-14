import AppKit
import Foundation
import ServiceManagement

enum HelperConditionalReleaseResult: Equatable {
    case completed(HelperReleaseOutcome, warning: String?)
    case failed(String)
    case cancelled
}

/// Manages the privileged helper: registration via SMAppService and XPC calls.
/// All completion handlers are delivered on the main queue.
final class HelperManager {
    private var connection: NSXPCConnection?

    /// Helper label / Mach service name, derived from this app's bundle id so the
    /// `.dev` build talks to its own daemon and never the Release one.
    private var helperLabel: String {
        LidlessHelper.label(appBundleID: Bundle.main.bundleIdentifier ?? "com.kenny.lidlessai")
    }

    /// The generated LaunchDaemon plist embedded at `Contents/Library/LaunchDaemons`.
    private var plistName: String { "\(helperLabel).plist" }

    private var service: SMAppService {
        SMAppService.daemon(plistName: plistName)
    }

    // MARK: Registration

    var isEnabled: Bool { service.status == .enabled }
    var requiresApproval: Bool { service.status == .requiresApproval }

    /// Register the daemon. Throws if registration fails outright. After this,
    /// `status` may be `.requiresApproval` until the user approves in Settings.
    func register() throws { try service.register() }

    /// Resume a registration that was interrupted after the old job had already
    /// been removed. Transient Background Task Management errors are retried in
    /// process; AppState also persists a repair-pending bit so a later launch
    /// retries if the app exits or every attempt fails.
    func registerWithRetry(completion: @escaping (Error?) -> Void) {
        registerWithRetries(
            service,
            attemptsRemaining: 3,
            delay: 0,
            leaseIsClear: false
        ) { _, error in
            completion(error)
        }
    }

    func unregister() throws { try service.unregister() }

    /// Rebuild the registration from scratch so launchd picks up the *current*
    /// binary. After an app update the daemon's code signature changes and its
    /// launchd job keeps a stale bundle/requirement reference, so launchd refuses
    /// to start the new binary (EX_CONFIG / "could not find and/or execute
    /// program"). A plain re-`register()` does *not* clear that — only a full
    /// unregister (which boots the old job) followed by a fresh register does.
    ///
    /// `unregister` is asynchronous, so we register from its completion (a
    /// register issued immediately after fails with the unregister still settling).
    /// Before unregistering, prove that no durable wake lease will be orphaned.
    /// If a lease owned by this app exists, release it through the old helper
    /// first. A failed state read/release aborts the operation and deliberately
    /// leaves the launchd watchdog registered.
    ///
    /// `leaseIsClear` is true only when the helper proved the journal absent or
    /// successfully released the matching lease. `completion` is delivered on
    /// the main queue.
    func reregister(leaseID: String,
                    completion: @escaping (_ leaseIsClear: Bool, _ error: Error?) -> Void) {
        getLeaseState { [weak self] state, stateError in
            guard let self else { return }
            if let stateError {
                // A stale/EX_CONFIG launchd registration cannot answer the
                // state call; aborting here would make the repair path itself
                // permanently unreachable. Confirm that all XPC is down, then
                // replace the job so the new KeepAlive helper can load and
                // recover the same root journal. If version still answers, this
                // is a journal error and remains fail-closed.
                self.checkReachable { reachable in
                    if reachable {
                        completion(false, self.reregistrationError(stateError))
                    } else {
                        self.performReregistration(
                            leaseIsClear: false,
                            completion: completion
                        )
                    }
                }
                return
            }
            guard let state else {
                self.performReregistration(leaseIsClear: true, completion: completion)
                return
            }
            guard let storedLeaseID = state["leaseID"] as? String,
                  storedLeaseID == leaseID else {
                completion(false, self.reregistrationError(
                    "The helper has a wake lease that CodeWake cannot safely release."
                ))
                return
            }
            self.releaseLease(id: leaseID) { ok, error in
                guard ok else {
                    completion(false, self.reregistrationError(
                        error ?? "The current wake lease could not be released safely."
                    ))
                    return
                }
                self.performReregistration(leaseIsClear: true, completion: completion)
            }
        }
    }

    private func performReregistration(
        leaseIsClear: Bool,
        completion: @escaping (_ leaseIsClear: Bool, _ error: Error?) -> Void
    ) {
        let svc = service
        connection?.invalidate()
        connection = nil
        svc.unregister { unregisterError in
            DispatchQueue.main.async {
                guard unregisterError == nil else {
                    completion(leaseIsClear, unregisterError)
                    return
                }
                // Give launchd/BTM a moment to drop the old job before re-adding
                // it. Retry transient registration failures; AppState records
                // the new build only after success, so a later launch retries
                // rather than abandoning a root journal with a stale job.
                self.registerWithRetries(
                    svc,
                    attemptsRemaining: 3,
                    delay: 0.5,
                    leaseIsClear: leaseIsClear,
                    completion: completion
                )
            }
        }
    }

    private func registerWithRetries(
        _ service: SMAppService,
        attemptsRemaining: Int,
        delay: TimeInterval,
        leaseIsClear: Bool,
        completion: @escaping (_ leaseIsClear: Bool, _ error: Error?) -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            do {
                try service.register()
                completion(leaseIsClear, nil)
            } catch {
                guard attemptsRemaining > 1 else {
                    completion(leaseIsClear, error)
                    return
                }
                self.registerWithRetries(
                    service,
                    attemptsRemaining: attemptsRemaining - 1,
                    delay: delay == 0 ? 0.5 : min(delay * 2, 2),
                    leaseIsClear: leaseIsClear,
                    completion: completion
                )
            }
        }
    }

    private func reregistrationError(_ message: String) -> NSError {
        NSError(
            domain: "com.kenny.lidlessai.helper-registration",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
        // Fallback: the SMAppService call silently no-ops for LSUIElement apps
        // or when System Settings is already running in the background, so also
        // open the Login Items pane by URL, which brings Settings to the front.
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: XPC

    private func connect() -> NSXPCConnection {
        if let existing = connection { return existing }
        let conn = NSXPCConnection(machServiceName: helperLabel, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: LidlessHelperProtocol.self)
        conn.invalidationHandler = { [weak self] in self?.connection = nil }
        conn.interruptionHandler = { }
        conn.resume()
        connection = conn
        return conn
    }

    private func remote(_ onError: @escaping (String) -> Void) -> LidlessHelperProtocol? {
        let proxy = connect().remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async { onError(error.localizedDescription) }
        }
        return proxy as? LidlessHelperProtocol
    }

    func acquireLease(id: String,
                      notAfter: Date,
                      completion: @escaping (Bool, String?) -> Void) {
        callWithTimeout(completion: completion) { proxy, done in
            proxy.acquireLease(id, notAfter: notAfter.timeIntervalSince1970) { ok, err in
                done(ok, err)
            }
        }
    }

    func updateLease(id: String,
                     notAfter: Date,
                     completion: @escaping (Bool, String?) -> Void) {
        callWithTimeout(completion: completion) { proxy, done in
            proxy.updateLease(id, notAfter: notAfter.timeIntervalSince1970) { ok, err in
                done(ok, err)
            }
        }
    }

    func heartbeatLease(id: String, completion: ((Bool, String?) -> Void)? = nil) {
        callWithTimeout(completion: completion ?? { _, _ in }) { proxy, done in
            proxy.heartbeatLease(id) { ok, err in done(ok, err) }
        }
    }

    func releaseLease(id: String, completion: @escaping (Bool, String?) -> Void) {
        callWithTimeout(completion: completion) { proxy, done in
            proxy.releaseLease(id) { ok, err in done(ok, err) }
        }
    }

    /// Policy-only emergency restore. This intentionally calls the original
    /// release selector directly instead of waiting for a helper-version probe:
    /// no immediate sleep is requested, and every supported helper implements
    /// `releaseLease`.
    func releaseLeaseForPolicyRestore(
        id: String,
        completion: @escaping (HelperConditionalReleaseResult) -> Void
    ) {
        releaseLease(id: id) { ok, error in
            guard ok else {
                completion(.failed(
                    error ?? "The background helper could not release the wake lease."
                ))
                return
            }
            completion(.completed(.legacyRelease, warning: nil))
        }
    }

    /// Release the aggregate lease and, on a protocol-v2 helper, atomically ask
    /// it to sleep only when the verified clamshell conditions permit it.
    ///
    /// Compatibility is deliberately gated through `version`, a selector every
    /// legacy helper already implements. A plain/unknown advertisement never
    /// receives the new selector; it takes the ordinary release path and returns
    /// `.legacyHelper`, preserving normal sleep without risking a helper crash.
    func releaseLeaseAndSleepIfEligible(
        id: String,
        sleepMode: HelperSleepMode,
        shouldProceed: @escaping () -> Bool,
        completion: @escaping (HelperConditionalReleaseResult) -> Void
    ) {
        switch SleepReleasePreparationGate.action(sleepMode: sleepMode) {
        case .directLeaseRelease:
            dispatchPrecondition(condition: .onQueue(.main))
            guard shouldProceed() else {
                completion(.cancelled)
                return
            }
            releaseLeaseForPolicyRestore(id: id, completion: completion)
            return
        case .probeConditionalSleepSupport:
            break
        }

        getHelperVersion { [weak self] advertisement, versionError in
            guard let self else { return }
            // getHelperVersion delivers on main. Keep the cancellation decision
            // and selector submission in this same main-queue turn so a Prompt
            // handled before us can cancel, while nothing can interleave after
            // permission is granted and before the XPC mutation is submitted.
            dispatchPrecondition(condition: .onQueue(.main))
            switch ConditionalSleepReleaseTransportGate.action(
                advertisement: advertisement,
                shouldProceed: shouldProceed()
            ) {
            case .cancelled:
                completion(.cancelled)
            case .legacyRelease:
                if versionError != nil {
                    // Force the safe legacy retry to establish a fresh XPC
                    // connection after an interruption or timed-out probe.
                    self.connection?.invalidate()
                    self.connection = nil
                }
                self.releaseLease(id: id) { ok, releaseError in
                    guard ok else {
                        completion(.failed(releaseError ?? versionError ??
                            "The background helper could not release the wake lease."))
                        return
                    }
                    completion(.completed(.legacyRelease, warning: nil))
                }
            case .conditionalSleepV2:
                self.callDictionaryWithTimeout(completion: { dictionary, error in
                    guard let dictionary else {
                        completion(.failed(
                            error ?? "The background helper returned no release result."
                        ))
                        return
                    }
                    guard let outcome = HelperReleaseOutcome(dictionary: dictionary) else {
                        completion(.failed(
                            "The background helper returned an invalid release result."
                        ))
                        return
                    }
                    completion(.completed(outcome, warning: error))
                }) { proxy, done in
                    proxy.releaseLeaseAndSleepIfEligible(
                        id,
                        sleepMode: sleepMode.rawValue,
                        withReply: done
                    )
                }
            }
        }
    }

    func getLeaseState(completion: @escaping (NSDictionary?, String?) -> Void) {
        var finished = false
        let finish: (NSDictionary?, String?) -> Void = { state, error in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                completion(state, error)
            }
        }
        guard let proxy = remote({ finish(nil, $0) }) else {
            finish(nil, "No helper connection")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            finish(nil, "The background helper isn’t responding.")
        }
        proxy.getLeaseState { state, error in finish(state, error) }
    }

    private func getHelperVersion(completion: @escaping (String?, String?) -> Void) {
        var finished = false
        let finish: (String?, String?) -> Void = { version, error in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                completion(version, error)
            }
        }
        guard let proxy = remote({ finish(nil, $0) }) else {
            finish(nil, "No helper connection")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            finish(nil, "The background helper isn’t responding.")
        }
        proxy.version { version in finish(version, nil) }
    }

    /// Read-only proof that launchd is running the exact helper embedded by this
    /// app version. A merely reachable or protocol-compatible old daemon is not
    /// current enough to record the app build as repaired.
    func checkCurrentVersion(completion: @escaping (Bool, String?) -> Void) {
        getHelperVersion { advertisement, error in
            guard LidlessHelper.isCurrentVersionAdvertisement(advertisement) else {
                completion(
                    false,
                    error ?? "The running background helper is from an older app build."
                )
                return
            }
            completion(true, nil)
        }
    }

    /// True if the daemon answers an XPC call, false if it can't be reached
    /// (connection error or no reply within the timeout). Used to detect a
    /// registered-but-unlaunchable helper after an app update.
    func checkReachable(completion: @escaping (Bool) -> Void) {
        callWithTimeout(timeout: 5, completion: { ok, _ in completion(ok) }) { proxy, done in
            proxy.version { _ in done(true, nil) }
        }
    }

    /// Run a single XPC call, guaranteeing `completion` fires exactly once on the
    /// main queue. If the daemon never replies — e.g. it fails to launch after an
    /// update, so neither the reply nor the connection's error handler ever fires
    /// — a timeout reports failure instead of leaving the UI hung and silent.
    private func callWithTimeout(timeout: TimeInterval = 6,
                                 completion: @escaping (Bool, String?) -> Void,
                                 _ body: (LidlessHelperProtocol, @escaping (Bool, String?) -> Void) -> Void) {
        var finished = false
        let finish: (Bool, String?) -> Void = { ok, err in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                completion(ok, err)
            }
        }
        guard let proxy = remote({ finish(false, $0) }) else {
            finish(false, "No helper connection")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            finish(false, "The background helper isn’t responding.")
        }
        body(proxy) { ok, err in finish(ok, err) }
    }

    private func callDictionaryWithTimeout(
        timeout: TimeInterval = 6,
        completion: @escaping (NSDictionary?, String?) -> Void,
        _ body: (
            LidlessHelperProtocol,
            @escaping (NSDictionary?, String?) -> Void
        ) -> Void
    ) {
        var finished = false
        let finish: (NSDictionary?, String?) -> Void = { dictionary, error in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                completion(dictionary, error)
            }
        }
        guard let proxy = remote({ finish(nil, $0) }) else {
            finish(nil, "No helper connection")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            finish(nil, "The background helper isn’t responding.")
        }
        body(proxy) { dictionary, error in finish(dictionary, error) }
    }
}
