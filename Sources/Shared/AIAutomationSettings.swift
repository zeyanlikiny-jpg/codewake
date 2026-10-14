import Foundation

/// User-facing policy for lifecycle-hook driven AI wake leases.
public struct AIAutomationSettings: Equatable, Codable {
    public static let allowedMaximumHours = [1, 2, 4, 8]
    public static let allowedWaitingReleaseDelaySeconds = [0, 60, 300, 600, 900, 1_800]
    public static let defaultWaitingReleaseDelaySeconds = 300
    /// A short, best-effort confirmation window after a normal Stop hook. Any
    /// continuation signal cancels it before the app restores normal sleep.
    public static let completionConfirmation: TimeInterval = 5
    /// Source-compatibility default for callers that have not yet adopted the
    /// per-user waiting release delay.
    public static let waitingGrace: TimeInterval = TimeInterval(defaultWaitingReleaseDelaySeconds)
    /// Source-compatibility alias for v0.1 callers. New code must choose the
    /// completion or waiting policy explicitly.
    public static let releaseGrace: TimeInterval = waitingGrace

    public var isEnabled: Bool
    public var allowOnBattery: Bool
    public var maximumHours: Int
    public var waitingReleaseDelaySeconds: Int {
        didSet {
            if !Self.allowedWaitingReleaseDelaySeconds.contains(waitingReleaseDelaySeconds) {
                waitingReleaseDelaySeconds = Self.defaultWaitingReleaseDelaySeconds
            }
        }
    }

    /// Source compatibility for v0.2 callers. External-display completion now
    /// always restores normal macOS policy, so legacy writes are intentionally
    /// ignored and legacy reads are always false.
    public var sleepWhileDocked: Bool {
        get { false }
        set { }
    }

    public static let `default` = AIAutomationSettings(
        isEnabled: true,
        allowOnBattery: false,
        maximumHours: 4,
        waitingReleaseDelaySeconds: defaultWaitingReleaseDelaySeconds
    )

    public init(isEnabled: Bool,
                allowOnBattery: Bool,
                maximumHours: Int,
                waitingReleaseDelaySeconds: Int = defaultWaitingReleaseDelaySeconds,
                sleepWhileDocked: Bool = false) {
        self.isEnabled = isEnabled
        self.allowOnBattery = allowOnBattery
        self.maximumHours = Self.allowedMaximumHours.contains(maximumHours) ? maximumHours : 4
        self.waitingReleaseDelaySeconds = Self.allowedWaitingReleaseDelaySeconds.contains(
            waitingReleaseDelaySeconds
        ) ? waitingReleaseDelaySeconds : Self.defaultWaitingReleaseDelaySeconds
        _ = sleepWhileDocked
    }

    public var maximumDuration: TimeInterval {
        TimeInterval(maximumHours * 60 * 60)
    }

    public var waitingReleaseDelay: TimeInterval {
        TimeInterval(waitingReleaseDelaySeconds)
    }

    public static func waitingReleaseDelayLabel(seconds: Int) -> String {
        switch seconds {
        case 0:
            return "Immediate"
        case 60:
            return "1 minute"
        case 300:
            return "5 minutes"
        case 600:
            return "10 minutes"
        case 900:
            return "15 minutes"
        case 1_800:
            return "30 minutes"
        default:
            return "5 minutes"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, allowOnBattery, maximumHours
        case waitingReleaseDelaySeconds
        case sleepWhileDocked
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try values.decode(Bool.self, forKey: .isEnabled),
            allowOnBattery: try values.decode(Bool.self, forKey: .allowOnBattery),
            maximumHours: try values.decode(Int.self, forKey: .maximumHours),
            waitingReleaseDelaySeconds: try values.decodeIfPresent(
                Int.self,
                forKey: .waitingReleaseDelaySeconds
            ) ?? Self.defaultWaitingReleaseDelaySeconds,
            // Decode the retired key so older payloads remain accepted, but
            // the initializer deliberately migrates either value to false.
            sleepWhileDocked: try values.decodeIfPresent(Bool.self, forKey: .sleepWhileDocked)
                ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(isEnabled, forKey: .isEnabled)
        try values.encode(allowOnBattery, forKey: .allowOnBattery)
        try values.encode(maximumHours, forKey: .maximumHours)
        try values.encode(waitingReleaseDelaySeconds, forKey: .waitingReleaseDelaySeconds)
        // Do not persist the retired external-display force-sleep preference.
    }
}
