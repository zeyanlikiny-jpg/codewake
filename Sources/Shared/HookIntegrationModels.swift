import Foundation

/// AI tools whose lifecycle hooks can be installed by CodeWake.
enum HookProvider: String, CaseIterable, Codable {
    case codex
    case claudeCode

    /// Stable value passed to the bridge executable and emitted on the socket.
    var wireName: String {
        switch self {
        case .codex: return "codex"
        case .claudeCode: return "claude"
        }
    }

    var configurationPathComponents: [String] {
        switch self {
        case .codex: return [".codex", "hooks.json"]
        case .claudeCode: return [".claude", "settings.json"]
        }
    }

    /// Events shared by the official Codex and Claude Code command-hook
    /// protocols. Claude Code additionally reports API-level failures.
    var installedEvents: [String] {
        var events = [
            "SessionStart",
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "PermissionRequest",
            "Stop",
            "SubagentStart",
            "SubagentStop",
            "SessionEnd",
        ]
        if self == .claudeCode {
            events.append(contentsOf: ["PostToolUseFailure", "Notification", "StopFailure"])
        }
        return events
    }

    func configurationURL(homeDirectory: URL) -> URL {
        configurationPathComponents.reduce(homeDirectory) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
    }
}

enum HookIntegrationHealthState: Equatable {
    case notInstalled
    case installed
    case needsRepair
    case bridgeMissing
    case invalidConfiguration
    case conflict
}

struct HookIntegrationHealth: Equatable {
    let provider: HookProvider
    let state: HookIntegrationHealthState
    let configurationURL: URL
    let bridgeURL: URL
}

/// A single read of every file-backed input used to judge Codex lifecycle
/// delivery. `integration` remains the strict, user-facing installation state:
/// a non-canonical completion relay still reports `needsRepair`. The component
/// states let runtime presentation distinguish that repair warning from a
/// canonical activity-event path that is already safe to consume.
struct CodexIntegrationHealth: Equatable {
    let integration: HookIntegrationHealth
    let hookConfigurationState: HookIntegrationHealthState
    let completionNotifyConfigurationState: HookIntegrationHealthState
    let installedBridgeMatchesBundledSource: Bool
}

struct HookIntegrationChange: Equatable {
    let provider: HookProvider
    let configurationChanged: Bool
    let bridgeChanged: Bool
    let backupURL: URL?
    /// Codex alone also installs a top-level `notify` relay in config.toml.
    /// Kept separate so callers can surface/restore both private backups.
    let notifyConfigurationChanged: Bool
    let notifyBackupURL: URL?

    init(
        provider: HookProvider,
        configurationChanged: Bool,
        bridgeChanged: Bool,
        backupURL: URL?,
        notifyConfigurationChanged: Bool = false,
        notifyBackupURL: URL? = nil
    ) {
        self.provider = provider
        self.configurationChanged = configurationChanged
        self.bridgeChanged = bridgeChanged
        self.backupURL = backupURL
        self.notifyConfigurationChanged = notifyConfigurationChanged
        self.notifyBackupURL = notifyBackupURL
    }
}

enum HookIntegrationError: LocalizedError, Equatable {
    case invalidJSON
    case invalidTopLevel
    case conflictingStructure(String)
    case conflictingBridgeCommand(String)
    case unsafeConfigurationFile
    case configurationTooLarge
    case configurationReadFailed
    case configurationChangedDuringRead
    case invalidTOML
    case conflictingNotifyRelay
    case bridgeExecutableMissing
    case unsafeBridgeSource

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "The hook configuration is not valid JSON. No changes were made."
        case .invalidTopLevel:
            return "The hook configuration must contain a JSON object. No changes were made."
        case .conflictingStructure(let location):
            return "The hook configuration has an incompatible value at \(location). No changes were made."
        case .conflictingBridgeCommand(let event):
            return "A different CodeWake bridge command already exists for \(event). No changes were made."
        case .unsafeConfigurationFile:
            return "The hook configuration must be a regular file, not a symlink or special file. No changes were made."
        case .configurationTooLarge:
            return "The hook configuration exceeds the 2 MiB safety limit. No changes were made."
        case .configurationReadFailed:
            return "The hook configuration could not be read safely. No changes were made."
        case .configurationChangedDuringRead:
            return "The hook configuration changed while it was being read. No changes were made."
        case .invalidTOML:
            return "The Codex configuration has an unsupported or invalid top-level notify value. No changes were made."
        case .conflictingNotifyRelay:
            return "A different or malformed CodeWake notify relay already exists. No changes were made."
        case .bridgeExecutableMissing:
            return "LidlessAIHookBridge is missing from the application bundle."
        case .unsafeBridgeSource:
            return "The bundled LidlessAIHookBridge is not a regular executable file."
        }
    }
}

enum HookIntegrationPaths {
    static let applicationSupportDirectoryName = "Lidless AI"
    static let bridgeExecutableName = "LidlessAIHookBridge"
    static let releaseAppBundleIdentifier = "com.kenny.lidlessai"
    static let developmentAppBundleIdentifier = "com.kenny.lidlessai.dev"

    /// User-facing path used in documentation and installation status.
    static let displayedBinDirectory = "~/Library/Application Support/Lidless AI/bin"

    static func applicationSupportDirectory(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    static func binDirectory(homeDirectory: URL) -> URL {
        applicationSupportDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("bin", isDirectory: true)
    }

    static func bridgeURL(homeDirectory: URL) -> URL {
        binDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent(bridgeExecutableName, isDirectory: false)
    }

    static func codexConfigurationURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    static func normalizedAppBundleIdentifier(_ value: String?) -> String {
        value == developmentAppBundleIdentifier
            ? developmentAppBundleIdentifier
            : releaseAppBundleIdentifier
    }

    static func socketURL(
        homeDirectory: URL,
        appBundleIdentifier: String = releaseAppBundleIdentifier
    ) -> URL {
        let fileName = normalizedAppBundleIdentifier(appBundleIdentifier)
            == developmentAppBundleIdentifier ? "events.dev.sock" : "events.sock"
        return applicationSupportDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func bridgeCommand(
        provider: HookProvider,
        appBundleIdentifier: String = releaseAppBundleIdentifier
    ) -> String {
        let bundleID = normalizedAppBundleIdentifier(appBundleIdentifier)
        let socketName = bundleID == developmentAppBundleIdentifier
            ? "events.dev.sock" : "events.sock"
        return "LIDLESS_AI_APP_BUNDLE_ID=\(bundleID) "
            + "LIDLESS_AI_SOCKET_PATH=\"$HOME/Library/Application Support/Lidless AI/runtime/\(socketName)\" "
            + "\"$HOME/Library/Application Support/Lidless AI/bin/\(bridgeExecutableName)\" "
            + "--provider \(provider.wireName)"
    }

    /// Direct argv used by Codex's `notify` setting. No shell expansion occurs
    /// in notify commands, so every path is absolute and every existing argv
    /// element is preserved verbatim after the explicit count.
    static func notifyRelayArguments(
        homeDirectory: URL,
        forwardedArguments: [String],
        appBundleIdentifier: String = releaseAppBundleIdentifier
    ) -> [String] {
        let bundleID = normalizedAppBundleIdentifier(appBundleIdentifier)
        return [
            bridgeURL(homeDirectory: homeDirectory).path,
            "--notify-relay",
            "--app-bundle-id", bundleID,
            "--socket-path", socketURL(
                homeDirectory: homeDirectory,
                appBundleIdentifier: bundleID
            ).path,
            "--forward-count", String(forwardedArguments.count),
        ] + forwardedArguments
    }
}
