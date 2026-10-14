import Foundation

/// Stable, user-actionable categories for failures whose underlying
/// Foundation, ServiceManagement, POSIX, or XPC description is not suitable for
/// display. AppState retains that raw description separately for diagnosis.
enum AppPresentationError {
    case loginItemUpdateFailed
    case integrationInstallFailed
    case integrationRemoveFailed
    case eventBridgeStartFailed
    case helperInstallFailed
    case helperRepairFailed
    case helperVersionCheckFailed
    case helperWakeUpdateFailed
    case helperLeaseMaintenanceFailed
    case systemSleepRequestFailed

    var canonicalMessage: String {
        switch self {
        case .loginItemUpdateFailed:
            return "Couldn’t update the launch-at-login setting."
        case .integrationInstallFailed:
            return "AI integrations could not be installed completely. Review the configuration and try again."
        case .integrationRemoveFailed:
            return "AI integrations could not be removed completely. Review the configuration and try again."
        case .eventBridgeStartFailed:
            return "The AI event bridge could not start."
        case .helperInstallFailed:
            return "The background helper could not be installed."
        case .helperRepairFailed:
            return "The background helper could not be repaired."
        case .helperVersionCheckFailed:
            return "The background helper version could not be verified."
        case .helperWakeUpdateFailed:
            return "The background helper could not update keep-awake."
        case .helperLeaseMaintenanceFailed:
            return "The background helper lost its keep-awake lease."
        case .systemSleepRequestFailed:
            return "Couldn’t request system sleep; normal sleep policy was restored."
        }
    }
}

/// Localizes presentation strings that are intentionally kept as canonical
/// English inside the state machine. Keeping the state canonical means a live
/// language change can re-render an existing notice without mutating any wake,
/// helper, or Agent state.
enum PresentationLocalizer {
    static func string(
        _ canonical: String,
        language: AppLanguage,
        bundle: Bundle = .main
    ) -> String {
        guard !canonical.isEmpty else { return canonical }

        if let value = localizeDynamic(
            canonical,
            language: language,
            bundle: bundle
        ) {
            return value
        }

        if let localized = L10n.stringIfPresent(
            canonical,
            language: language,
            bundle: bundle
        ) {
            return localized
        }
        if language == .english { return canonical }

        // Low-level ServiceManagement/POSIX/XPC details are retained in the
        // canonical backing value for diagnostics, but an untranslated English
        // implementation detail must not leak into the Chinese interface.
        return L10n.string(
            "error.unexpected",
            defaultValue: "An unexpected error occurred.",
            language: language,
            bundle: bundle
        )
    }

    private static func localizeDynamic(
        _ canonical: String,
        language: AppLanguage,
        bundle: Bundle
    ) -> String? {
        if canonical.contains(" · ") {
            return canonical
                .components(separatedBy: " · ")
                .map {
                    localizeSegment($0, language: language, bundle: bundle)
                }
                .joined(separator: " · ")
        }

        if canonical.hasPrefix("Input-wait release in: ") {
            let value = String(canonical.dropFirst("Input-wait release in: ".count))
            return L10n.format(
                "agent.input_wait_release",
                defaultValue: "Input-wait release in: %@",
                language: language,
                bundle: bundle,
                value
            )
        }

        if canonical.hasPrefix("Auto-off: "), canonical.hasSuffix(" elapsed.") {
            let start = canonical.index(canonical.startIndex, offsetBy: "Auto-off: ".count)
            let end = canonical.index(canonical.endIndex, offsetBy: -" elapsed.".count)
            let duration = localizedDuration(
                String(canonical[start..<end]),
                language: language,
                bundle: bundle
            )
            return L10n.format(
                "auto_off.elapsed",
                defaultValue: "Auto-off: %@ elapsed.",
                language: language,
                bundle: bundle,
                duration
            )
        }

        if let percent = integer(
            in: canonical,
            prefix: "Auto-paused: battery ",
            suffix: "% on battery power."
        ) {
            return L10n.format(
                "safety.auto_paused.low_battery",
                defaultValue: "Auto-paused: battery %d%% on battery power.",
                language: language,
                bundle: bundle,
                percent
            )
        }

        if let percent = integer(
            in: canonical,
            prefix: "Battery is at ",
            suffix: "%. Charge above the low-battery cutoff to keep your Mac awake."
        ) {
            return L10n.format(
                "safety.blocked.low_battery",
                defaultValue: "Battery is at %d%%. Charge above the low-battery cutoff to keep your Mac awake.",
                language: language,
                bundle: bundle,
                percent
            )
        }

        if let percent = integer(
            in: canonical,
            prefix: "Battery ",
            suffix: "% is at or below the cutoff"
        ) {
            return L10n.format(
                "safety.check.low_battery",
                defaultValue: "Battery %d%% is at or below the cutoff",
                language: language,
                bundle: bundle,
                percent
            )
        }

        if canonical.hasPrefix("Background helper recovery needs attention:") {
            return language == .english ? canonical : L10n.string(
                "helper.recovery.needs_attention",
                defaultValue: "Background helper recovery needs attention.",
                language: language,
                bundle: bundle
            )
        }

        if canonical.hasPrefix("Background helper repair will retry next launch:") {
            return language == .english ? canonical : L10n.string(
                "helper.repair.retry_next_launch",
                defaultValue: "Background helper repair will retry next launch.",
                language: language,
                bundle: bundle
            )
        }

        // Hook configuration conflicts carry a raw JSON location or event name.
        // Keep that diagnostic detail in English, but present a stable,
        // fully-translated error in Chinese instead of exposing an opaque token.
        if canonical.hasPrefix(
            "The hook configuration has an incompatible value at "
        ), canonical.hasSuffix(". No changes were made.") {
            return language == .english ? canonical : L10n.string(
                "hook.error.incompatible_value",
                defaultValue: "The hook configuration contains an incompatible value. No changes were made.",
                language: language,
                bundle: bundle
            )
        }

        if canonical.hasPrefix(
            "A different CodeWake bridge command already exists for "
        ), canonical.hasSuffix(". No changes were made.") {
            return language == .english ? canonical : L10n.string(
                "hook.error.conflicting_bridge",
                defaultValue: "A different CodeWake bridge command already exists. No changes were made.",
                language: language,
                bundle: bundle
            )
        }

        // POSIX details from the local lifecycle-event socket are useful for
        // internal diagnosis but are not actionable UI. Match only operations
        // emitted by AgentEventSocketServer so unrelated errors cannot be
        // mislabeled as an integration failure.
        let eventSocketOperations = [
            "lstat runtime directory", "chmod directory", "socket", "bind",
            "lstat bound socket", "chmod socket", "listen",
            "unlink stale socket"
        ]
        if eventSocketOperations.contains(where: {
            canonical.hasPrefix("\($0) failed:")
        }) {
            return language == .english ? canonical : L10n.string(
                "agent.event_bridge.start_failed",
                defaultValue: "The AI event bridge could not start.",
                language: language,
                bundle: bundle
            )
        }

        let wakeParts = canonical.components(separatedBy: ", ")
        let knownWakeLabels: Set<String> = [
            "Manual hold", "Manual timer", "Charging hold", "External/system",
            "Codex", "Claude Code", "Cursor"
        ]
        if wakeParts.count > 1, wakeParts.allSatisfy(knownWakeLabels.contains) {
            let separator = language == .simplifiedChinese ? "、" : ", "
            return wakeParts
                .map {
                    localizeSegment($0, language: language, bundle: bundle)
                }
                .joined(separator: separator)
        }

        return nil
    }

    private static func localizeSegment(
        _ canonical: String,
        language: AppLanguage,
        bundle: Bundle
    ) -> String {
        for (suffix, key, defaultValue) in [
            (" working", "agent.count.working", "%d working"),
            (" waiting", "agent.count.waiting", "%d waiting"),
            (" finishing", "agent.count.finishing", "%d finishing")
        ] {
            if canonical.hasSuffix(suffix),
               let count = Int(canonical.dropLast(suffix.count)) {
                return L10n.format(
                    key,
                    defaultValue: defaultValue,
                    language: language,
                    bundle: bundle,
                    count
                )
            }
        }

        if canonical.hasSuffix(" remains") {
            let labels = canonical
                .dropLast(" remains".count)
                .components(separatedBy: ", ")
                .map { exact($0, language: language, bundle: bundle) }
                .joined(separator: language == .simplifiedChinese ? "、" : ", ")
            return L10n.format(
                "agent.blockers.remain",
                defaultValue: "%@ remains",
                language: language,
                bundle: bundle,
                labels
            )
        }

        return exact(canonical, language: language, bundle: bundle)
    }

    private static func exact(
        _ canonical: String,
        language: AppLanguage,
        bundle: Bundle
    ) -> String {
        L10n.string(
            canonical,
            defaultValue: canonical,
            language: language,
            bundle: bundle
        )
    }

    private static func localizedDuration(
        _ canonical: String,
        language: AppLanguage,
        bundle: Bundle
    ) -> String {
        if canonical == "No limit" {
            return L10n.string(
                "duration.no_limit",
                defaultValue: "No limit",
                language: language,
                bundle: bundle
            )
        }
        if canonical.hasSuffix(" min"), let value = Int(canonical.dropLast(4)) {
            return L10n.format(
                "duration.minutes",
                defaultValue: "%d min",
                language: language,
                bundle: bundle,
                value
            )
        }
        if canonical == "1 hour" {
            return L10n.format(
                "duration.hours",
                defaultValue: "%d hours",
                language: language,
                bundle: bundle,
                1
            )
        }
        if canonical.hasSuffix(" hours"), let value = Int(canonical.dropLast(6)) {
            return L10n.format(
                "duration.hours",
                defaultValue: "%d hours",
                language: language,
                bundle: bundle,
                value
            )
        }
        return exact(canonical, language: language, bundle: bundle)
    }

    private static func integer(
        in value: String,
        prefix: String,
        suffix: String
    ) -> Int? {
        guard value.hasPrefix(prefix), value.hasSuffix(suffix) else { return nil }
        let start = value.index(value.startIndex, offsetBy: prefix.count)
        let end = value.index(value.endIndex, offsetBy: -suffix.count)
        return Int(value[start..<end])
    }
}
