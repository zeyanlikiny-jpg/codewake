import Foundation
import IOKit

/// Pure parsing helpers for `pmset` output, plus live `IOPMrootDomain` fallback.
public enum PowerParsers {

    /// Parse `pmset -g` output for the `SleepDisabled` flag. The relevant line
    /// looks like: ` SleepDisabled        1`
    ///
    /// On a fresh Mac where `pmset -a disablesleep` has never been invoked,
    /// `com.apple.PowerManagement.plist` omits `SleepDisabled` entirely and
    /// `pmset -g` prints an empty `System-wide power settings:` header followed
    /// immediately by `Currently in use:` and the active profile keys. When both
    /// section headers and active settings are present without a `SleepDisabled`
    /// entry, sleep is not disabled (`false`).
    ///
    /// Returns nil when the output is empty, truncated, missing headers, or has
    /// a malformed `SleepDisabled` value.
    public static func sleepDisabled(pmsetG output: String) -> Bool? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var systemHeaderIndex: Int?
        var currentUseHeaderIndex: Int?

        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed == "system-wide power settings:" {
                systemHeaderIndex = index
                continue
            }
            if trimmed == "currently in use:" {
                currentUseHeaderIndex = index
                continue
            }
            guard trimmed.contains("sleepdisabled") else { continue }
            let remainder = trimmed
                .replacingOccurrences(of: "sleepdisabled", with: "")
                .trimmingCharacters(in: .whitespaces)
            switch remainder {
            case "1": return true
            case "0": return false
            default:  return nil
            }
        }

        if let sysIdx = systemHeaderIndex,
           let curIdx = currentUseHeaderIndex,
           curIdx > sysIdx {
            let hasActiveEntries = lines[(curIdx + 1)...].contains {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }
            if hasActiveEntries {
                return false
            }
        }
        return nil
    }

    /// Read the live kernel `SleepDisabled` boolean directly from `IOPMrootDomain`.
    /// Works without privileges even on fresh macOS installations where `pmset -g`
    /// has never materialized `SleepDisabled` in `SystemPowerSettings`.
    public static func sleepDisabledFromIORegistry() -> Bool? {
        let rootDomain = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard rootDomain != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(rootDomain) }
        return IORegistryEntryCreateCFProperty(
            rootDomain,
            "SleepDisabled" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool
    }

    /// Lenient form, kept for callers that have no way to act on "unknown" —
    /// the helper's XPC reply is a plain `Bool`. Prefer `sleepDisabled(pmsetG:)`.
    public static func isSleepDisabled(pmsetG output: String) -> Bool {
        sleepDisabled(pmsetG: output) ?? false
    }
}

public struct BatteryInfo: Equatable {
    public let percent: Int
    public let onAC: Bool

    public init(percent: Int, onAC: Bool) {
        self.percent = percent
        self.onAC = onAC
    }

    public var source: String { onAC ? "AC" : "Battery" }
}

public enum BatteryParsers {
    /// Parse `pmset -g batt` output into a BatteryInfo.
    public static func parse(pmsetBatt output: String) -> BatteryInfo {
        var percent = 0
        if let range = output.range(of: #"\d+%"#, options: .regularExpression) {
            percent = Int(output[range].dropLast()) ?? 0
        }
        let onAC = output.contains("AC Power")
        return BatteryInfo(percent: percent, onAC: onAC)
    }
}
