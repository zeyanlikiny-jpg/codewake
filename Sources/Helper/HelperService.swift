import Foundation
import CoreGraphics
import IOKit
import IOKit.pwr_mgt

/// Small value snapshot read from IOPMrootDomain. Optional fields are
/// intentional: desktops and failed registry reads have no trustworthy lid
/// state, and must never be treated as a closed notebook.
struct HelperClamshellState: Equatable {
    let isClosed: Bool?
    let causesSleep: Bool?
}

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: HelperService
    private let peerIdentity: LidlessHelperPeerIdentity

    init(service: HelperService = HelperService(),
         peerIdentity: LidlessHelperPeerIdentity = LidlessHelper.configuredPeerIdentity()) {
        self.service = service
        self.peerIdentity = peerIdentity
        super.init()
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Missing packaging identity is a hard failure. Weakening the requirement
        // would expose a root power-management method to every local process.
        guard !peerIdentity.appBundleID.isEmpty,
              let teamID = peerIdentity.teamID,
              !teamID.isEmpty else { return false }

        newConnection.setCodeSigningRequirement(
            LidlessHelper.codeSigningRequirement(
                appBundleID: peerIdentity.appBundleID,
                teamID: teamID
            )
        )
        newConnection.exportedInterface = NSXPCInterface(with: LidlessHelperProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

/// Privileged power controller with a durable, single aggregate lease.
///
/// The JSON journal is the ownership proof. The helper clears `SleepDisabled`
/// only when that proof says its acquire started from 0 and therefore owned the
/// 0→1, including after a reboot where the flag persisted.
final class HelperService: NSObject, LidlessHelperProtocol {
    typealias PowerWriteResult = (ok: Bool, error: String?)

    private let queue = DispatchQueue(label: "com.kenny.lidlessai.helper.state")
    private let watchdogTimeout: TimeInterval
    private let journalStore: HelperLeaseJournalStore
    private var bootID: String
    private let clock: () -> TimeInterval
    private let readSleepDisabled: () -> Bool?
    private let writeSleepDisabled: (Bool) -> PowerWriteResult
    /// `nil` is an unreadable display topology. Conditional sleep fails closed
    /// in that case; releasing the wake lease is still always allowed.
    private let externalDisplayConnected: () -> Bool?
    private let readClamshellState: () -> HelperClamshellState
    private let requestSystemSleep: () -> PowerWriteResult

    // Durable lease state. `leaseError` remains visible through getLeaseState;
    // malformed journals are never overwritten because doing so would discard
    // ownership evidence we could not interpret.
    private var leaseJournal: HelperLeaseJournal?
    private var leaseError: String?
    /// True only when the on-disk evidence could not be decoded (or no boot ID
    /// exists). Transient I/O errors remain visible but must not prevent a later
    /// release/recovery attempt.
    private var leaseOperationsBlocked = false
    /// Startup could temporarily fail before the journal is readable or the
    /// boot-session UUID is available. KeepAlive keeps this process resident,
    /// so the watchdog must retry those transient cases instead of leaving an
    /// owned system flag stranded forever.
    private var journalReloadPending = false
    private var watchdogTimer: DispatchSourceTimer?

    init(journalStore: HelperLeaseJournalStore = HelperLeaseJournalStore(
            fileURL: HelperLeaseRuntime.journalFileURL()),
         bootID: String? = HelperLeaseRuntime.currentBootID(),
         watchdogTimeout: TimeInterval = 90,
         clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         readSleepDisabled: @escaping () -> Bool? = HelperService.readSleepDisabledFromSystem,
         writeSleepDisabled: @escaping (Bool) -> PowerWriteResult = HelperService.writeSleepDisabledToSystem,
         externalDisplayConnected: @escaping () -> Bool? =
            HelperService.externalDisplayConnectedFromSystem,
         readClamshellState: @escaping () -> HelperClamshellState =
            HelperService.readClamshellStateFromSystem,
         requestSystemSleep: @escaping () -> PowerWriteResult =
            HelperService.requestSystemSleepFromSystem,
         startsWatchdog: Bool = true) {
        self.journalStore = journalStore
        self.bootID = bootID ?? ""
        self.watchdogTimeout = watchdogTimeout
        self.clock = clock
        self.readSleepDisabled = readSleepDisabled
        self.writeSleepDisabled = writeSleepDisabled
        self.externalDisplayConnected = externalDisplayConnected
        self.readClamshellState = readClamshellState
        self.requestSystemSleep = requestSystemSleep
        super.init()

        queue.sync { loadAndRecoverLeaseAtStartup() }
        if startsWatchdog { startWatchdog() }
    }

    // MARK: - Persistent lease protocol

    func acquireLease(_ leaseID: String,
                      notAfter: Double,
                      withReply reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            let now = self.clock()
            if let error = self.requestError(leaseID: leaseID, notAfter: notAfter, now: now) {
                reply(false, error)
                return
            }

            // Retire an expired/incomplete record before considering this
            // request. A recovery failure keeps the record and blocks acquire.
            if let existing = self.leaseJournal,
               let reason = HelperLeasePolicy.recoveryReason(
                    for: existing,
                    currentBootID: self.bootID,
                    now: now,
                    heartbeatTimeout: self.watchdogTimeout,
                    atStartup: false) {
                let recovered = self.recoverLease(existing, reason: reason)
                guard recovered.ok else {
                    reply(false, recovered.error)
                    return
                }
            }

            if let existing = self.leaseJournal {
                guard existing.leaseID == leaseID, existing.phase == .active else {
                    reply(false, "Another persistent keep-awake lease is already active.")
                    return
                }
                guard let currentlyEnabled = self.readSleepDisabled() else {
                    reply(false, "Could not verify the current SleepDisabled state.")
                    return
                }
                if currentlyEnabled {
                    // Same-ID acquire is intentionally idempotent. It lets the
                    // app reconnect after an XPC reply loss without creating a
                    // second root-owned hold.
                    self.updateExistingLease(existing, notAfter: notAfter, now: now, reply: reply)
                    return
                }

                // The system flag was cleared outside Lidless AI while our
                // aggregate lease remained live. Retire that old baseline first,
                // then fall through and acquire a fresh 0→1 transaction. Merely
                // updating the journal would leave the UI claiming a hold that
                // can no longer survive lid close; blindly writing 1 under the
                // old baseline could later undo an external user's change.
                var retiring = existing
                retiring.phase = .releasing
                do {
                    try self.persist(retiring)
                } catch {
                    reply(false, self.recordLeaseError("Could not retire stale lease journal", error))
                    return
                }
                let retired = self.recoverLease(retiring, reason: .incompleteTransaction)
                guard retired.ok else {
                    reply(false, retired.error)
                    return
                }
            }

            guard let baseline = self.readSleepDisabled() else {
                reply(false, "Could not read the current SleepDisabled state.")
                return
            }

            // Persist ownership before the system mutation. `changedByUs` is
            // true only for a baseline 0, so recovery never undoes a pre-existing
            // keep-awake setting.
            let pending = HelperLeaseJournal.pending(
                leaseID: leaseID,
                baselineEnabled: baseline,
                bootID: self.bootID,
                now: now,
                notAfter: notAfter
            )
            do {
                try self.persist(pending)
            } catch {
                reply(false, self.recordLeaseError("Could not write pending lease journal", error))
                return
            }

            if !baseline {
                let enabled = self.writeSleepDisabled(true)
                guard enabled.ok else {
                    let recovery = self.recoverLease(pending, reason: .incompleteTransaction)
                    let detail = enabled.error ?? "pmset could not enable SleepDisabled."
                    let suffix = recovery.ok ? "" : " Recovery also failed: \(recovery.error ?? "unknown error")"
                    reply(false, detail + suffix)
                    return
                }
            }

            var active = pending
            active.phase = .active
            do {
                try self.persist(active)
                reply(true, nil)
            } catch {
                // The pending file is still durable. Roll back now; if rollback
                // itself fails, startup/watchdog will keep retrying from it.
                let persistenceError = self.recordLeaseError("Could not activate lease journal", error)
                let recovery = self.recoverLease(pending, reason: .incompleteTransaction)
                let suffix = recovery.ok ? "" : " Recovery also failed: \(recovery.error ?? "unknown error")"
                reply(false, persistenceError + suffix)
            }
        }
    }

    func updateLease(_ leaseID: String,
                     notAfter: Double,
                     withReply reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            let now = self.clock()
            if let error = self.requestError(leaseID: leaseID, notAfter: notAfter, now: now) {
                reply(false, error)
                return
            }
            guard let existing = self.liveLease(leaseID: leaseID, now: now, reply: reply) else { return }
            self.updateExistingLease(existing, notAfter: notAfter, now: now, reply: reply)
        }
    }

    func heartbeatLease(_ leaseID: String,
                        withReply reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            let now = self.clock()
            if let error = self.requestError(leaseID: leaseID, now: now) {
                reply(false, error)
                return
            }
            guard var journal = self.liveLease(leaseID: leaseID, now: now, reply: reply) else { return }
            journal.lastHeartbeat = now
            do {
                try self.persist(journal)
                reply(true, nil)
            } catch {
                reply(false, self.recordLeaseError("Could not persist lease heartbeat", error))
            }
        }
    }

    func releaseLease(_ leaseID: String,
                      withReply reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            let now = self.clock()
            if let error = self.requestError(leaseID: leaseID, now: now) {
                reply(false, error)
                return
            }
            let released = self.releaseLeaseTransaction(leaseID: leaseID)
            reply(released.ok, released.error)
        }
    }

    func releaseLeaseAndSleepIfEligible(
        _ leaseID: String,
        sleepMode rawSleepMode: String,
        withReply reply: @escaping (NSDictionary?, String?) -> Void
    ) {
        queue.async {
            let now = self.clock()
            if let error = self.requestError(leaseID: leaseID, now: now) {
                reply(nil, error)
                return
            }

            // An unknown future value degrades to release-only. Stranding a
            // finished task's wake lease would be worse, while guessing that an
            // unknown value authorizes immediate system sleep would be unsafe.
            let sleepMode = HelperSleepMode(rawValue: rawSleepMode) ?? .never
            let released = self.releaseLeaseTransaction(leaseID: leaseID)
            guard released.ok else {
                reply(nil, released.error)
                return
            }

            guard released.hadLease else {
                reply(HelperReleaseOutcome(
                    leaseReleased: true,
                    restoredOwnedTransition: false,
                    lidClosed: nil,
                    clamshellCausesSleep: nil,
                    sleepAttempted: false,
                    sleepRequestAccepted: false,
                    disposition: .noLease
                ).dictionary, nil)
                return
            }

            // A pre-existing SleepDisabled=1 belongs to another power tool or
            // the user. The journal is retired, but this helper has no authority
            // to infer that normal sleep was restored or to force system sleep.
            guard released.restoredOwnedTransition else {
                reply(HelperReleaseOutcome(
                    leaseReleased: true,
                    restoredOwnedTransition: false,
                    lidClosed: nil,
                    clamshellCausesSleep: nil,
                    sleepAttempted: false,
                    sleepRequestAccepted: false,
                    disposition: .preexistingWakeSetting
                ).dictionary, nil)
                return
            }

            guard sleepMode != .never else {
                reply(HelperReleaseOutcome(
                    leaseReleased: true,
                    restoredOwnedTransition: true,
                    lidClosed: nil,
                    clamshellCausesSleep: nil,
                    sleepAttempted: false,
                    sleepRequestAccepted: false,
                    disposition: .releasedWithoutSleep
                ).dictionary, nil)
                return
            }

            // The normal AI-completion policy must never force a docked Mac to
            // sleep. Read the display topology only after our lease has been
            // durably released, inside the same serialized helper transaction,
            // so a last-moment display hot-plug cannot race an app-side check.
            // Display safety is absolute for every immediate-sleep request,
            // including a legacy caller that still sends
            // `closedLidIncludingDocked` after this upgrade.
            if sleepMode == .closedLid || sleepMode == .closedLidIncludingDocked {
                guard let hasExternalDisplay = self.externalDisplayConnected() else {
                    reply(HelperReleaseOutcome(
                        leaseReleased: true,
                        restoredOwnedTransition: true,
                        lidClosed: nil,
                        clamshellCausesSleep: nil,
                        sleepAttempted: false,
                        sleepRequestAccepted: false,
                        disposition: .externalDisplayStateUnknown
                    ).dictionary, nil)
                    return
                }
                guard !hasExternalDisplay else {
                    reply(HelperReleaseOutcome(
                        leaseReleased: true,
                        restoredOwnedTransition: true,
                        lidClosed: nil,
                        clamshellCausesSleep: nil,
                        sleepAttempted: false,
                        sleepRequestAccepted: false,
                        disposition: .dockedMode
                    ).dictionary, nil)
                    return
                }
            }

            // Read the lid only after normal sleep has been restored and the
            // journal removal is durable. A failed release never reaches this
            // point and therefore can never issue IOPMSleepSystem.
            let clamshell = self.readClamshellState()
            guard let lidClosed = clamshell.isClosed else {
                reply(self.outcome(
                    clamshell: clamshell,
                    disposition: .lidStateUnknown
                ).dictionary, nil)
                return
            }
            guard lidClosed else {
                reply(self.outcome(
                    clamshell: clamshell,
                    disposition: .lidOpen
                ).dictionary, nil)
                return
            }

            if sleepMode == .closedLid {
                guard let causesSleep = clamshell.causesSleep else {
                    reply(self.outcome(
                        clamshell: clamshell,
                        disposition: .clamshellBehaviorUnknown
                    ).dictionary, nil)
                    return
                }
                guard causesSleep else {
                    reply(self.outcome(
                        clamshell: clamshell,
                        disposition: .dockedMode
                    ).dictionary, nil)
                    return
                }
            }

            // Recheck immediately before IOPMSleepSystem as well. Display
            // hot-plug is independent of this helper queue and may change while
            // lid/clamshell properties are being read.
            guard let hasExternalDisplay = self.externalDisplayConnected() else {
                reply(self.outcome(
                    clamshell: clamshell,
                    disposition: .externalDisplayStateUnknown
                ).dictionary, nil)
                return
            }
            guard !hasExternalDisplay else {
                reply(self.outcome(
                    clamshell: clamshell,
                    disposition: .dockedMode
                ).dictionary, nil)
                return
            }

            let sleep = self.requestSystemSleep()
            guard sleep.ok else {
                let outcome = self.outcome(
                    clamshell: clamshell,
                    sleepAttempted: true,
                    sleepRequestAccepted: false,
                    disposition: .sleepRequestFailed
                )
                // The lease was already released successfully. Return the
                // outcome together with the sleep error so the app can surface
                // it without re-acquiring or retrying in a loop.
                reply(outcome.dictionary, sleep.error ?? "IOPMSleepSystem rejected the sleep request.")
                return
            }

            reply(self.outcome(
                clamshell: clamshell,
                sleepAttempted: true,
                sleepRequestAccepted: true,
                disposition: .sleepRequested
            ).dictionary, nil)
        }
    }

    func getLeaseState(withReply reply: @escaping (NSDictionary?, String?) -> Void) {
        queue.async {
            reply(self.leaseJournal?.stateDictionary, self.leaseError)
        }
    }

    func version(withReply reply: @escaping (String) -> Void) {
        reply(LidlessHelper.currentVersionAdvertisement)
    }

    // MARK: - Lease operations

    private func requestError(leaseID: String,
                              notAfter: TimeInterval? = nil,
                              now: TimeInterval) -> String? {
        if leaseOperationsBlocked { return leaseError ?? "Persistent lease operations are unavailable." }
        guard !bootID.isEmpty else { return "Could not determine the current boot session ID." }
        return HelperLeaseRequestValidator.error(leaseID: leaseID, notAfter: notAfter, now: now)
    }

    /// Return a matching active lease, first enforcing its heartbeat/expiry.
    private func liveLease(leaseID: String,
                           now: TimeInterval,
                           reply: @escaping (Bool, String?) -> Void) -> HelperLeaseJournal? {
        guard let journal = leaseJournal else {
            reply(false, "No persistent keep-awake lease is active.")
            return nil
        }
        guard journal.leaseID == leaseID else {
            reply(false, "The persistent lease belongs to a different owner.")
            return nil
        }
        if let reason = HelperLeasePolicy.recoveryReason(
            for: journal,
            currentBootID: bootID,
            now: now,
            heartbeatTimeout: watchdogTimeout,
            atStartup: false
        ) {
            let recovered = recoverLease(journal, reason: reason)
            let message = recovered.ok
                ? "The persistent lease expired and was released."
                : recovered.error
            reply(false, message)
            return nil
        }
        return journal
    }

    private func updateExistingLease(_ existing: HelperLeaseJournal,
                                     notAfter: TimeInterval,
                                     now: TimeInterval,
                                     reply: @escaping (Bool, String?) -> Void) {
        var journal = existing
        journal.notAfter = notAfter
        journal.lastHeartbeat = now
        do {
            try persist(journal)
            reply(true, nil)
        } catch {
            reply(false, recordLeaseError("Could not update lease journal", error))
        }
    }

    private typealias LeaseReleaseResult = (
        ok: Bool,
        error: String?,
        hadLease: Bool,
        restoredOwnedTransition: Bool
    )

    /// Shared serial release transaction used by both the legacy release method
    /// and protocol v2. `ok` is true only after the ownership journal has been
    /// removed durably; conditional sleep is evaluated by the caller afterward.
    private func releaseLeaseTransaction(leaseID: String) -> LeaseReleaseResult {
        guard var journal = leaseJournal else {
            // Idempotent release makes shutdown/retry paths simple.
            return (true, nil, false, false)
        }
        guard journal.leaseID == leaseID else {
            return (false, "The persistent lease belongs to a different owner.", true, false)
        }

        let restoredOwnedTransition = HelperLeasePolicy.shouldRestoreSleep(for: journal)
        journal.phase = .releasing
        do {
            try persist(journal)
        } catch {
            return (
                false,
                recordLeaseError("Could not mark lease for release", error),
                true,
                restoredOwnedTransition
            )
        }
        let recovered = recoverLease(journal, reason: .incompleteTransaction)
        return (recovered.ok, recovered.error, true, restoredOwnedTransition)
    }

    private func outcome(
        clamshell: HelperClamshellState,
        sleepAttempted: Bool = false,
        sleepRequestAccepted: Bool = false,
        disposition: HelperReleaseDisposition
    ) -> HelperReleaseOutcome {
        HelperReleaseOutcome(
            leaseReleased: true,
            restoredOwnedTransition: true,
            lidClosed: clamshell.isClosed,
            clamshellCausesSleep: clamshell.causesSleep,
            sleepAttempted: sleepAttempted,
            sleepRequestAccepted: sleepRequestAccepted,
            disposition: disposition
        )
    }

    private func persist(_ journal: HelperLeaseJournal) throws {
        try journalStore.save(journal)
        leaseJournal = journal
        leaseError = nil
        leaseOperationsBlocked = false
    }

    private func removeJournal() throws {
        try journalStore.remove()
        leaseJournal = nil
        leaseError = nil
        leaseOperationsBlocked = false
    }

    @discardableResult
    private func recordLeaseError(_ context: String, _ error: Error) -> String {
        let message = "\(context): \(error.localizedDescription)"
        leaseError = message
        return message
    }

    private func loadAndRecoverLeaseAtStartup() {
        guard !bootID.isEmpty else {
            leaseError = "Could not determine the current boot session ID."
            leaseOperationsBlocked = true
            journalReloadPending = true
            return
        }
        do {
            leaseJournal = try journalStore.load()
            leaseError = nil
            leaseOperationsBlocked = false
            journalReloadPending = false
        } catch {
            // Malformed/unsupported means ownership is unknown. Never guess by
            // issuing `pmset 0`, and never overwrite the evidence with a new
            // lease. `getLeaseState` exposes the repairable error.
            _ = recordLeaseError("Could not load persistent lease journal", error)
            leaseOperationsBlocked = true
            journalReloadPending = !Self.isPermanentJournalFormatError(error)
            return
        }
        guard let loadedJournal = leaseJournal else { return }
        let reason = HelperLeasePolicy.recoveryReason(
            for: loadedJournal,
            currentBootID: bootID,
            now: clock(),
            heartbeatTimeout: watchdogTimeout,
            atStartup: true
        )
        // A fresh same-boot active journal is a helper-only restart. Retain it;
        // the app can resume heartbeats, while a dead app is still bounded by
        // the existing watchdog and absolute deadline.
        guard let reason else { return }

        // Persist `releasing` first so a failed read or pmset call remains
        // retryable by the watchdog instead of looking like a healthy active
        // lease on its next tick.
        var journal = loadedJournal
        journal.phase = .releasing
        do {
            try persist(journal)
        } catch {
            // Keep the retryable phase in memory even if the disk update failed.
            // The original durable ownership evidence remains intact and the
            // next helper launch will attempt startup recovery again.
            leaseJournal = journal
            _ = recordLeaseError("Could not mark startup lease for recovery", error)
        }
        _ = recoverLease(journal, reason: reason)
    }

    /// Restore and remove a journal. Ownership survives a boot change because
    /// `SleepDisabled` can survive one too. The early-start helper reads the
    /// live flag and only writes 0 when the record proves our original 0→1.
    private func recoverLease(_ journal: HelperLeaseJournal,
                              reason _: HelperLeaseRecoveryReason) -> PowerWriteResult {
        if HelperLeasePolicy.shouldRestoreSleep(for: journal) {
            guard let currentlyEnabled = readSleepDisabled() else {
                let message = "Could not verify SleepDisabled while recovering the persistent lease."
                leaseError = message
                return (false, message)
            }
            if HelperLeasePolicy.requiresRestoreWrite(
                for: journal,
                currentlyEnabled: currentlyEnabled
            ) {
                let restored = writeSleepDisabled(false)
                guard restored.ok else {
                    let message = restored.error ?? "pmset could not restore normal sleep."
                    leaseError = message
                    return (false, message)
                }
            }
        }

        do {
            try removeJournal()
            return (true, nil)
        } catch {
            return (false, recordLeaseError("Could not remove recovered lease journal", error))
        }
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 15)
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        timer.resume()
        watchdogTimer = timer
    }

#if DEBUG
    /// Deterministically exercises the production watchdog on its state queue.
    /// Tests compile this source directly but never start the helper executable.
    func runWatchdogTickForTesting() {
        queue.sync { watchdogTick() }
    }
#endif

    private func watchdogTick() {
        if journalReloadPending {
            if bootID.isEmpty {
                bootID = HelperLeaseRuntime.currentBootID() ?? ""
            }
            loadAndRecoverLeaseAtStartup()
            if journalReloadPending || leaseOperationsBlocked { return }
        }

        let now = clock()
        if let journal = leaseJournal,
           let reason = HelperLeasePolicy.recoveryReason(
                for: journal,
                currentBootID: bootID,
                now: now,
                heartbeatTimeout: watchdogTimeout,
                atStartup: false) {
            _ = recoverLease(journal, reason: reason)
        }

    }

    private static func isPermanentJournalFormatError(_ error: Error) -> Bool {
        if error is DecodingError { return true }
        return HelperLeaseJournalStore.isPermanentStorageFailure(error)
    }

    // MARK: - System power adapter

    private static func readSleepDisabledFromSystem() -> Bool? {
        guard let output = capture("/usr/bin/pmset", ["-g"]) else { return nil }
        return PowerParsers.sleepDisabled(pmsetG: output)
    }

    private static func writeSleepDisabledToSystem(_ disabled: Bool) -> PowerWriteResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            return (false, error.localizedDescription)
        }
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (false, detail.isEmpty ? "pmset exited \(process.terminationStatus)" : detail)
        }
        return (true, nil)
    }

    private static func readClamshellStateFromSystem() -> HelperClamshellState {
        let rootDomain = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard rootDomain != IO_OBJECT_NULL else {
            return HelperClamshellState(isClosed: nil, causesSleep: nil)
        }
        defer { IOObjectRelease(rootDomain) }

        func booleanProperty(_ key: String) -> Bool? {
            IORegistryEntryCreateCFProperty(
                rootDomain,
                key as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? Bool
        }

        return HelperClamshellState(
            isClosed: booleanProperty(kAppleClamshellStateKey),
            causesSleep: booleanProperty(kAppleClamshellCausesSleepKey)
        )
    }

    /// Returns whether any online display is not the Mac's built-in panel.
    /// CoreGraphics reports mirrored displays separately; either way the
    /// presence of an external destination is enough to prohibit forced sleep.
    private static func externalDisplayConnectedFromSystem() -> Bool? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        // A Mac always has at least one discoverable display endpoint in the
        // normal WindowServer session. An empty successful list from a root
        // daemon is therefore unknown, not proof that no external display is
        // connected; fail closed rather than risk a forced docked sleep.
        guard count > 0 else { return nil }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var populated: UInt32 = 0
        guard CGGetOnlineDisplayList(count, &displays, &populated) == .success else {
            return nil
        }
        return displays.prefix(Int(populated)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    private static func requestSystemSleepFromSystem() -> PowerWriteResult {
        let powerConnection = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard powerConnection != IO_OBJECT_NULL else {
            return (false, "Could not connect to the IOKit power-management root domain.")
        }
        defer { IOServiceClose(powerConnection) }

        let result = IOPMSleepSystem(powerConnection)
        guard result == kIOReturnSuccess else {
            let hex = String(format: "0x%08x", UInt32(bitPattern: result))
            return (false, "IOPMSleepSystem failed with IOReturn \(hex).")
        }
        return (true, nil)
    }

    private static func capture(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
