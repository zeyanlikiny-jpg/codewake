import Foundation

/// Controls the macOS `SleepDisabled` flag (IOPMrootDomain).
///
/// This unprivileged adapter is intentionally read-only. Every write is owned by
/// the durable lease in `LidlessHelper`; a raw administrator fallback would have
/// no crash-recovery record and could strand the Mac in a system-wide awake
/// state.
struct PowerManager {

    /// Read the current `SleepDisabled` flag from `pmset -g`.
    ///
    /// Returns nil whenever the flag wasn't actually observed — `pmset` failed to
    /// launch, exited non-zero, or printed something that doesn't state the flag.
    /// A failed read must never collapse into "off".
    ///
    /// Reading needs no privileges, so this is the app's read path whether or not
    /// the helper is installed.
    func isSleepDisabled() -> Bool? {
        guard let out = Shell.capture("/usr/bin/pmset", ["-g"]) else { return nil }
        return PowerParsers.sleepDisabled(pmsetG: out)
    }
}
