import Foundation

/// Exact identity accepted by the privileged helper's XPC listener.
public struct LidlessHelperPeerIdentity: Equatable {
    public let appBundleID: String
    public let teamID: String?

    public init(appBundleID: String, teamID: String?) {
        self.appBundleID = appBundleID
        self.teamID = teamID
    }
}

/// Identity of the privileged helper, derived from the owning app's bundle id so
/// that Debug (`.dev`) and Release builds get fully isolated daemons/services and
/// never collide. For app bundle id `com.kenny.lidlessai` the helper id —
/// which doubles as its LaunchDaemon label, Mach service name, and the `.plist`
/// basename — is `com.kenny.lidlessai.helper`.
public enum LidlessHelper {
    public static let defaultAppBundleID = "com.kenny.lidlessai"

    /// XPC surface capability advertised through the pre-existing `version`
    /// selector. Older helpers return a plain app version (for example
    /// `0.2.0`), so the app can prove support before it ever sends a new
    /// selector to an old daemon.
    public static let currentProtocolVersion = 2
    /// Include the app build as well as the marketing version. launchd can keep
    /// a daemon from the previous app build alive, even when the XPC protocol
    /// itself has not changed, so a protocol-only match is not proof that the
    /// embedded helper was upgraded.
    public static let currentVersionAdvertisement = "0.2.17+22;protocol=2"

    /// A build may be recorded as having the current embedded helper only after
    /// the running daemon returns this exact advertisement. Reachability or a
    /// compatible protocol alone is insufficient: launchd can keep an older,
    /// still-responsive binary alive across an app upgrade.
    public static func isCurrentVersionAdvertisement(_ advertisement: String?) -> Bool {
        advertisement == currentVersionAdvertisement
    }

    public static func protocolVersion(from advertisement: String) -> Int? {
        let marker = ";protocol="
        guard let range = advertisement.range(of: marker, options: .backwards),
              range.upperBound < advertisement.endIndex else { return nil }
        let value = advertisement[range.upperBound...]
        guard !value.isEmpty, value.allSatisfy(\.isNumber) else { return nil }
        return Int(value)
    }

    /// Pure compatibility decision used by `HelperManager` before selecting an
    /// XPC method. Keeping this decision shared and testable proves that a plain
    /// legacy advertisement can only reach the legacy selector.
    public static func releaseTransportRoute(
        for advertisement: String?
    ) -> HelperReleaseTransportRoute {
        guard let advertisement,
              protocolVersion(from: advertisement) == currentProtocolVersion else {
            return .legacyRelease
        }
        return .conditionalSleepV2
    }

    /// Label / Mach service name for a given app bundle id.
    public static func label(appBundleID: String) -> String { "\(appBundleID).helper" }

    /// Env var the generated LaunchDaemon plist passes to the (bundle-less) helper
    /// executable so it knows which Mach service to listen on without relying on
    /// an embedded bundle id.
    public static let machLabelEnvKey = "LIDLESS_MACH_LABEL"

    /// Explicit values injected by the generated LaunchDaemon plist. The team
    /// has no compiled fallback: accepting a made-up or former upstream team is
    /// worse than failing closed until packaging supplies the correct identity.
    public static let allowedAppBundleIDEnvKey = "LIDLESS_ALLOWED_APP_BUNDLE_ID"
    public static let allowedTeamIDEnvKey = "LIDLESS_ALLOWED_TEAM_ID"
    public static let allowedAppBundleIDInfoKey = "LidlessAllowedAppBundleID"
    public static let allowedTeamIDInfoKey = "LidlessAllowedTeamID"

    /// Runtime fallback for a freshly-branded build with no launchd environment.
    public static let runtimeFallbackLabel = label(appBundleID: defaultAppBundleID)

    /// Compatibility spelling retained for callers on the old API surface, but
    /// it now resolves to the branded Kenny runtime identity.
    public static let fallbackLabel = runtimeFallbackLabel

    /// The app bundle id a helper label was derived from — the inverse of
    /// `label(appBundleID:)`.
    public static func appBundleID(fromLabel label: String) -> String {
        let suffix = ".helper"
        guard label.hasSuffix(suffix) else { return label }
        return String(label.dropLast(suffix.count))
    }

    /// Source-compatible view of the configured team. `TEAM_ID_NOT_CONFIGURED`
    /// intentionally matches no real signed app, so old callers also fail closed
    /// rather than silently trusting the former upstream developer identity.
    public static var teamID: String {
        configuredPeerIdentity().teamID ?? "TEAM_ID_NOT_CONFIGURED"
    }

    /// Resolve the peer identity from launchd/build configuration. Explicit
    /// values win; the Mach label remains a safe bundle-id source for existing
    /// generated plists. Tests can inject both dictionaries.
    public static func configuredPeerIdentity(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        machLabel: String? = nil
    ) -> LidlessHelperPeerIdentity {
        let configuredLabel = machLabel ?? environment[machLabelEnvKey]
        let appBundleID = usable(environment[allowedAppBundleIDEnvKey])
            ?? usable(infoDictionary[allowedAppBundleIDInfoKey] as? String)
            ?? configuredLabel.flatMap { usable(Self.appBundleID(fromLabel: $0)) }
            ?? defaultAppBundleID
        let configuredTeam = usable(environment[allowedTeamIDEnvKey])
            ?? usable(infoDictionary[allowedTeamIDInfoKey] as? String)
        return LidlessHelperPeerIdentity(appBundleID: appBundleID, teamID: configuredTeam)
    }

    private static func usable(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.contains("$(") else { return nil }
        return value
    }

    /// Code signing requirement the helper demands of anything connecting to it.
    ///
    /// The Mach service an `SMAppService` daemon registers is reachable by every
    /// process on the machine, and the listener used to accept all of them. So
    /// any program a user ran could ask a root daemon to hold their Mac awake
    /// indefinitely — on a laptop, in a bag, that is a heat and battery problem
    /// they'd have no way to attribute.
    ///
    /// The three clauses cover each other. `identifier` alone would admit any
    /// binary claiming the name; `anchor apple generic` alone would admit every
    /// Apple-signed app on the Mac; the team check alone would admit anything
    /// else we ever ship. Together they mean this app, signed by us.
    ///
    /// `anchor apple generic` is satisfied by Developer ID and Apple Development
    /// certificates alike, so a locally-built `.dev` app passes exactly as a
    /// released one does.
    public static func codeSigningRequirement(appBundleID: String, teamID: String) -> String {
        """
        identifier "\(appBundleID)" \
        and anchor apple generic \
        and certificate leaf[subject.OU] = "\(teamID)"
        """
    }

    /// Compatibility overload. Runtime listener code uses the explicit-team
    /// overload and rejects a missing team before accepting a connection.
    public static func codeSigningRequirement(appBundleID: String) -> String {
        codeSigningRequirement(appBundleID: appBundleID, teamID: teamID)
    }
}

public enum HelperReleaseTransportRoute: Equatable {
    case legacyRelease
    case conditionalSleepV2
}

/// Whether the helper may request system sleep after it has safely released its
/// durable wake lease. Raw strings keep the XPC request Foundation-only.
public enum HelperSleepMode: String, Equatable {
    /// Restore normal sleep policy, but never ask macOS to sleep immediately.
    case never
    /// Sleep only when the lid is physically closed and clamshell close is
    /// currently configured to cause sleep (the safe default).
    case closedLid
    /// Sleep whenever the lid is physically closed, including external-display
    /// clamshell mode where close does not ordinarily cause sleep.
    case closedLidIncludingDocked
}

/// Stable reason codes returned by the v2 release transaction. User-facing text
/// belongs in the app; the privileged helper returns only small audited facts.
public enum HelperReleaseDisposition: String, Equatable {
    case releasedWithoutSleep
    case noLease
    case preexistingWakeSetting
    case lidOpen
    case lidStateUnknown
    case dockedMode
    case externalDisplayStateUnknown
    case clamshellBehaviorUnknown
    case sleepRequested
    case sleepRequestFailed
    case legacyHelper
}

/// Parsed representation of the Foundation-only v2 XPC reply.
public struct HelperReleaseOutcome: Equatable {
    public static let currentSchemaVersion = 1

    public let leaseReleased: Bool
    public let restoredOwnedTransition: Bool
    public let lidClosed: Bool?
    public let clamshellCausesSleep: Bool?
    public let sleepAttempted: Bool
    public let sleepRequestAccepted: Bool
    public let disposition: HelperReleaseDisposition

    public init(leaseReleased: Bool,
                restoredOwnedTransition: Bool,
                lidClosed: Bool?,
                clamshellCausesSleep: Bool?,
                sleepAttempted: Bool,
                sleepRequestAccepted: Bool,
                disposition: HelperReleaseDisposition) {
        self.leaseReleased = leaseReleased
        self.restoredOwnedTransition = restoredOwnedTransition
        self.lidClosed = lidClosed
        self.clamshellCausesSleep = clamshellCausesSleep
        self.sleepAttempted = sleepAttempted
        self.sleepRequestAccepted = sleepRequestAccepted
        self.disposition = disposition
    }

    /// Only property-list values cross XPC. Unknown clamshell facts are omitted
    /// instead of being collapsed into `false`.
    public var dictionary: NSDictionary {
        var values: [String: Any] = [
            "schemaVersion": Self.currentSchemaVersion,
            "leaseReleased": leaseReleased,
            "restoredOwnedTransition": restoredOwnedTransition,
            "sleepAttempted": sleepAttempted,
            "sleepRequestAccepted": sleepRequestAccepted,
            "disposition": disposition.rawValue
        ]
        if let lidClosed { values["lidClosed"] = lidClosed }
        if let clamshellCausesSleep { values["clamshellCausesSleep"] = clamshellCausesSleep }
        return values as NSDictionary
    }

    public init?(dictionary: NSDictionary) {
        guard (dictionary["schemaVersion"] as? NSNumber)?.intValue == Self.currentSchemaVersion,
              let leaseReleased = (dictionary["leaseReleased"] as? NSNumber)?.boolValue,
              let restoredOwnedTransition =
                (dictionary["restoredOwnedTransition"] as? NSNumber)?.boolValue,
              let sleepAttempted = (dictionary["sleepAttempted"] as? NSNumber)?.boolValue,
              let sleepRequestAccepted =
                (dictionary["sleepRequestAccepted"] as? NSNumber)?.boolValue,
              let rawDisposition = dictionary["disposition"] as? String,
              let disposition = HelperReleaseDisposition(rawValue: rawDisposition) else {
            return nil
        }
        self.init(
            leaseReleased: leaseReleased,
            restoredOwnedTransition: restoredOwnedTransition,
            lidClosed: (dictionary["lidClosed"] as? NSNumber)?.boolValue,
            clamshellCausesSleep:
                (dictionary["clamshellCausesSleep"] as? NSNumber)?.boolValue,
            sleepAttempted: sleepAttempted,
            sleepRequestAccepted: sleepRequestAccepted,
            disposition: disposition
        )
    }

    public static let legacyRelease = HelperReleaseOutcome(
        leaseReleased: true,
        restoredOwnedTransition: false,
        lidClosed: nil,
        clamshellCausesSleep: nil,
        sleepAttempted: false,
        sleepRequestAccepted: false,
        disposition: .legacyHelper
    )
}

/// XPC interface implemented by the root helper and called by the app.
///
/// The helper runs as root (installed via `SMAppService`), so it can flip the
/// `SleepDisabled` flag without an admin prompt. Every mutation goes through the
/// durable lease API; there is deliberately no legacy raw boolean setter that
/// could bypass ownership and crash recovery.
@objc public protocol LidlessHelperProtocol {
    /// Acquire the helper's one aggregate persistent lease. `notAfter` is Unix
    /// epoch seconds. Re-acquiring the same ID is idempotent and refreshes it.
    func acquireLease(_ leaseID: String,
                      notAfter: Double,
                      withReply reply: @escaping (Bool, String?) -> Void)

    /// Change the absolute expiry and refresh activity for an active lease.
    func updateLease(_ leaseID: String,
                     notAfter: Double,
                     withReply reply: @escaping (Bool, String?) -> Void)

    /// Refresh only the 90-second liveness deadline.
    func heartbeatLease(_ leaseID: String,
                        withReply reply: @escaping (Bool, String?) -> Void)

    /// Release the lease and restore sleep only when this helper owned the 0→1.
    func releaseLease(_ leaseID: String,
                      withReply reply: @escaping (Bool, String?) -> Void)

    /// Protocol v2: release the durable lease, then conditionally request system
    /// sleep in the same serialized helper transaction. The app must first prove
    /// v2 support through the existing `version` selector; sending this selector
    /// to a legacy helper is intentionally forbidden.
    func releaseLeaseAndSleepIfEligible(
        _ leaseID: String,
        sleepMode: String,
        withReply reply: @escaping (NSDictionary?, String?) -> Void
    )

    /// Current journal as a Foundation-only dictionary, or nil when no lease is
    /// held. The second reply value reports journal/configuration failures.
    func getLeaseState(withReply reply: @escaping (NSDictionary?, String?) -> Void)

    /// Helper version string, for a connection sanity check.
    func version(withReply reply: @escaping (String) -> Void)
}
