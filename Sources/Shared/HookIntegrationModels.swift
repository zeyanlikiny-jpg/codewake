import Foundation

/// AI tools whose lifecycle hooks can be installed by CodeWake.
enum HookProvider: String, CaseIterable, Codable {
    case codex
    case claudeCode
    case antigravity
    case paseo

    /// Stable value passed to the bridge executable and emitted on the socket.
    var wireName: String {
        switch self {
        case .codex: return "codex"
        case .claudeCode: return "claude"
        case .antigravity: return "antigravity"
        case .paseo: return "paseo"
        }
    }

    var configurationPathComponents: [String] {
        switch self {
        case .codex: return [".codex", "hooks.json"]
        case .claudeCode: return [".claude", "settings.json"]
        case .antigravity: return [".gemini", "config", "hooks.json"]
        case .paseo: return [".paseo", "config.json"]
        }
    }

    /// Lifecycle events installed or emitted for each supported provider.
    var installedEvents: [String] {
        switch self {
        case .codex:
            return [
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
        case .claudeCode:
            return [
                "SessionStart",
                "UserPromptSubmit",
                "PreToolUse",
                "PostToolUse",
                "PermissionRequest",
                "Stop",
                "SubagentStart",
                "SubagentStop",
                "SessionEnd",
                "PostToolUseFailure",
                "Notification",
                "StopFailure",
            ]
        case .antigravity:
            // `PreToolUse` is deliberately NOT installed. Antigravity treats it
            // as a permission gate whose `decision` field is required: a
            // passive observer that prints `{}` is parsed as an empty decision
            // and hard-denies every tool call. CodeWake must never gate tools,
            // so tool activity is observed through `PostToolUse` and the
            // invocation/stop lifecycle instead.
            return [
                "SessionStart",
                "PreInvocation",
                "PostInvocation",
                "PostToolUse",
                "Stop",
            ]
        case .paseo:
            return [
                "agent.create.after",
                "agent.turn.before",
                "agent.turn.after",
                "agent.permission.before",
                "agent.permission.after",
                "agent.close.after",
                "agent.archive.after",
            ]
        }
    }

    /// Events the bridge still understands. This is a superset of
    /// `installedEvents` so an older Antigravity configuration that still
    /// carries CodeWake's `PreToolUse` handler keeps reporting work (and gets a
    /// non-blocking response) until the app repairs it.
    var acceptedEvents: [String] {
        switch self {
        case .antigravity: return installedEvents + ["PreToolUse"]
        case .codex, .claudeCode, .paseo: return installedEvents
        }
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
    static let antigravityHookEntryName = "codewake"
    static let paseoPluginIdentifier = "codewake"
    static let paseoPluginDirectoryName = "paseo-plugin"
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

    static func paseoPluginDirectory(homeDirectory: URL) -> URL {
        applicationSupportDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent(paseoPluginDirectoryName, isDirectory: true)
    }

    static func paseoPluginManifestURL(homeDirectory: URL) -> URL {
        paseoPluginDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("paseo-plugin.json", isDirectory: false)
    }

    static func paseoPluginServerEntryURL(homeDirectory: URL) -> URL {
        paseoPluginDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("index.server.ts", isDirectory: false)
    }

    static func paseoPluginManifestData() -> Data {
        Data(
            """
            {
              "description": "Privacy-minimized lifecycle wake bridge for CodeWake",
              "id": "\(paseoPluginIdentifier)",
              "name": "CodeWake",
              "requirements": {
                "paseo": ">=0.9.0"
              }
            }

            """.utf8
        )
    }

    static func paseoPluginServerEntryData(
        homeDirectory: URL,
        appBundleIdentifier: String = releaseAppBundleIdentifier
    ) -> Data {
        let bundleID = normalizedAppBundleIdentifier(appBundleIdentifier)
        let bridgePath = jsonStringLiteral(bridgeURL(homeDirectory: homeDirectory).path)
        let socketPath = jsonStringLiteral(
            socketURL(homeDirectory: homeDirectory, appBundleIdentifier: bundleID).path
        )
        let bundleLiteral = jsonStringLiteral(bundleID)
        let script = """
        import { spawn } from "node:child_process";

        const BRIDGE_PATH = \(bridgePath);
        const APP_BUNDLE_ID = \(bundleLiteral);
        const SOCKET_PATH = \(socketPath);

        // Every hook spawns its own bridge process, so delivery order is not
        // emission order (Paseo emits turn.before/turn.after back to back for
        // instant turns). Stamp here, strictly increasing, so the app can order
        // the lifecycle correctly.
        let lastEmittedAt = 0;

        function emitLifecycleEvent(payload: Record<string, unknown>): void {
          try {
            const emittedAt = Math.max(Date.now() / 1000, lastEmittedAt + 0.000001);
            lastEmittedAt = emittedAt;
            const child = spawn(BRIDGE_PATH, ["--provider", "paseo"], {
              env: {
                ...process.env,
                LIDLESS_AI_APP_BUNDLE_ID: APP_BUNDLE_ID,
                LIDLESS_AI_SOCKET_PATH: SOCKET_PATH,
              },
              stdio: ["pipe", "ignore", "ignore"],
            });
            child.on("error", () => {});
            child.stdin.on("error", () => {});
            child.stdin.end(JSON.stringify({ ...payload, emitted_at: emittedAt }));
            child.unref();
          } catch {
            // Hook delivery is best-effort and must never disrupt Paseo turns.
          }
        }

        export default function contribute(server: any): () => void {
          if (!server || typeof server.addHook !== "function") {
            return () => {};
          }
          const disposers = [
            server.addHook("agent.create.after", (event: any) => {
              if (typeof event?.agent?.id === "string") {
                emitLifecycleEvent({
                  session_id: event.agent.id,
                  hook_event_name: "agent.create.after",
                });
              }
            }),
            server.addHook("agent.turn.before", (event: any) => {
              if (typeof event?.agent?.id === "string") {
                emitLifecycleEvent({
                  session_id: event.agent.id,
                  turn_id: typeof event.turnId === "string" ? event.turnId : undefined,
                  hook_event_name: "agent.turn.before",
                });
              }
            }),
            server.addHook("agent.turn.after", (event: any) => {
              if (typeof event?.agent?.id === "string") {
                const outcomeKind = typeof event?.outcome === "string"
                  ? event.outcome
                  : (typeof event?.outcome?.kind === "string" ? event.outcome.kind : "completed");
                emitLifecycleEvent({
                  session_id: event.agent.id,
                  turn_id: typeof event.turnId === "string" ? event.turnId : undefined,
                  hook_event_name: "agent.turn.after",
                  outcome_kind: outcomeKind,
                });
              }
            }),
            server.addHook("agent.permission.before", (event: any) => {
              if (typeof event?.agent?.id === "string") {
                emitLifecycleEvent({
                  session_id: event.agent.id,
                  turn_id: typeof event.turnId === "string" ? event.turnId : undefined,
                  hook_event_name: "agent.permission.before",
                });
              }
            }),
            server.addHook("agent.permission.after", (event: any) => {
              if (typeof event?.agent?.id === "string") {
                emitLifecycleEvent({
                  session_id: event.agent.id,
                  turn_id: typeof event.turnId === "string" ? event.turnId : undefined,
                  hook_event_name: "agent.permission.after",
                });
              }
            }),
            server.addHook("agent.close.after", (event: any) => {
              if (typeof event?.agent?.id === "string") {
                emitLifecycleEvent({
                  session_id: event.agent.id,
                  hook_event_name: "agent.close.after",
                });
              }
            }),
            server.addHook("agent.archive.after", (event: any) => {
              if (typeof event?.agent?.id === "string") {
                emitLifecycleEvent({
                  session_id: event.agent.id,
                  hook_event_name: "agent.archive.after",
                });
              }
            }),
          ];
          return () => {
            for (const dispose of disposers) {
              if (typeof dispose === "function") {
                dispose();
              }
            }
          };
        }

        """
        return Data(script.utf8)
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        guard let encoded = try? JSONSerialization.data(
            withJSONObject: [value],
            options: [.withoutEscapingSlashes]
        ),
              let arrayText = String(data: encoded, encoding: .utf8),
              arrayText.count >= 2 else {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return String(arrayText.dropFirst().dropLast())
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
