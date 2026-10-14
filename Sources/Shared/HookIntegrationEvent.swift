import CryptoKit
import Foundation

enum HookBridgeEventKind: String, Codable, Equatable {
    case sessionStarted
    case promptSubmitted
    case toolStarted
    case toolFinished
    case inputReceived
    case turnCompleted
    // Retained for rolling compatibility with an already-installed v2 bridge.
    case activity
    case waitingForInput
    case turnStopped
    case turnFailed
    case backgroundWorkChanged
    case sessionEnded
}

/// Content-free reason shown by the app while a turn is waiting. No prompt,
/// question, permission description, or plan text crosses the socket.
enum HookWaitingReason: String, Codable, Equatable {
    case userInput
    case permission
    case planConfirmation
}

/// Privacy-minimized message accepted by the app's local event socket. The
/// encoder cannot accidentally include prompt text, cwd, transcript paths,
/// model names, tool inputs, tool output, or assistant messages because none of
/// those fields exist in this type.
struct HookBridgePayload: Codable, Equatable {
    /// v3 distinguishes tool start/finish/input/completion and includes only a
    /// content-free waiting reason. Bumping the wire version also prevents old
    /// v2 observation badges from claiming the upgraded relay was verified.
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let provider: String
    let sessionID: String
    let turnID: String?
    let eventKind: HookBridgeEventKind
    let waitingReason: HookWaitingReason?
    let backgroundWork: Bool?
    let backgroundWorkCount: Int?
    let workToken: String?
    let stopHookActive: Bool?
    let timestamp: TimeInterval

    init(
        provider: String,
        sessionID: String,
        turnID: String?,
        eventKind: HookBridgeEventKind,
        waitingReason: HookWaitingReason? = nil,
        backgroundWork: Bool?,
        backgroundWorkCount: Int? = nil,
        workToken: String? = nil,
        stopHookActive: Bool? = nil,
        timestamp: TimeInterval
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.provider = provider
        self.sessionID = sessionID
        self.turnID = turnID
        self.eventKind = eventKind
        self.waitingReason = waitingReason
        self.backgroundWork = backgroundWork
        self.backgroundWorkCount = backgroundWorkCount
        self.workToken = workToken
        self.stopHookActive = stopHookActive
        self.timestamp = timestamp
    }

    /// Strict decoder used when current-version proof is required (for example,
    /// runtime-observation badges). The app's lifecycle socket uses the separate
    /// supported decoder below so an old bridge can keep work awake during a
    /// rolling repair without ever becoming sleep-eligible or "observed".
    static func decodeCurrent(from data: Data) -> HookBridgePayload? {
        guard let payload = try? JSONDecoder().decode(HookBridgePayload.self, from: data),
              payload.schemaVersion == currentSchemaVersion else { return nil }
        return payload
    }

    /// Rolling-update socket decoder. v1/v2 remain supported long enough to
    /// keep an already-running old bridge's work awake, while the state machine
    /// maps their completion to a non-sleep-eligible legacy release.
    /// Unknown/future schemas are rejected rather than guessed.
    static func decodeSupported(from data: Data) -> HookBridgePayload? {
        guard let payload = try? JSONDecoder().decode(HookBridgePayload.self, from: data),
              payload.schemaVersion == 1
                || payload.schemaVersion == 2
                || payload.schemaVersion == currentSchemaVersion else { return nil }
        return payload
    }
}

enum HookEventSanitizer {
    // Official hook input includes private prompt/tool fields that are discarded
    // after parsing and can legitimately exceed 64 KiB. Keep a finite 4 MiB
    // abuse bound without dropping ordinary large coding prompts.
    static let maximumInputBytes = 4 * 1024 * 1024
    private static let maximumIdentifierLength = 512
    private static let waitingNotificationTypes: Set<String> = [
        "permission_prompt",
        "idle_prompt",
        "elicitation_dialog",
        "elicitation_url_dialog",
        "agent_needs_input",
    ]

    static func payload(
        from data: Data,
        provider: HookProvider,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> HookBridgePayload? {
        guard !data.isEmpty, data.count <= maximumInputBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let input = object as? [String: Any],
              let sessionID = validIdentifier(input["session_id"] as? String),
              let hookName = input["hook_event_name"] as? String,
              provider.installedEvents.contains(hookName),
              let mapping = mapping(hookName: hookName, input: input, provider: provider) else {
            return nil
        }

        let rawTurnID = (input["turn_id"] as? String) ?? (input["prompt_id"] as? String)
        return HookBridgePayload(
            provider: provider.wireName,
            sessionID: sessionID,
            turnID: validIdentifier(rawTurnID),
            eventKind: mapping.kind,
            waitingReason: waitingReason(hookName: hookName, input: input),
            backgroundWork: mapping.backgroundWork,
            backgroundWorkCount: mapping.backgroundWorkCount,
            workToken: mapping.workToken,
            stopHookActive: mapping.stopHookActive,
            timestamp: timestamp
        )
    }

    private static func waitingReason(
        hookName: String,
        input: [String: Any]
    ) -> HookWaitingReason? {
        switch hookName {
        case "PreToolUse":
            guard let toolName = input["tool_name"] as? String,
                  isInputRequestTool(toolName) else { return nil }
            return .userInput
        case "PermissionRequest", "Notification":
            return .permission
        case "Stop":
            return (input["permission_mode"] as? String) == "plan"
                || ProposedPlanEnvelope.matches(input["last_assistant_message"] as? String)
                ? .planConfirmation
                : nil
        default:
            return nil
        }
    }

    static func encodedPayload(
        from data: Data,
        provider: HookProvider,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Data? {
        guard let payload = payload(from: data, provider: provider, timestamp: timestamp) else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(payload)
    }

    private static func mapping(
        hookName: String,
        input: [String: Any],
        provider: HookProvider
    ) -> (kind: HookBridgeEventKind,
          backgroundWork: Bool?,
          backgroundWorkCount: Int?,
          workToken: String?,
          stopHookActive: Bool?)? {
        switch hookName {
        case "SessionStart":
            return (.sessionStarted, nil, nil, nil, nil)
        case "UserPromptSubmit":
            return (.promptSubmitted, nil, nil, nil, nil)
        case "PreToolUse":
            if let toolName = input["tool_name"] as? String,
               isInputRequestTool(toolName) {
                return (.waitingForInput, nil, nil, nil, nil)
            }
            return (.toolStarted, nil, nil, nil, nil)
        case "PostToolUse":
            if let toolName = input["tool_name"] as? String,
               isInputRequestTool(toolName) {
                return (.inputReceived, nil, nil, nil, nil)
            }
            return (.toolFinished, nil, nil, nil, nil)
        case "PostToolUseFailure":
            return (.toolFinished, nil, nil, nil, nil)
        case "PermissionRequest":
            return (.waitingForInput, nil, nil, nil, nil)
        case "Notification":
            guard let type = input["notification_type"] as? String,
                  waitingNotificationTypes.contains(type) else { return nil }
            return (.waitingForInput, nil, nil, nil, nil)
        case "Stop":
            // Codex emits Stop before presenting the native plan-approval card.
            // Treat only the official plan permission mode or an exact protocol
            // envelope as waiting. The assistant message is inspected in memory
            // and is never copied into HookBridgePayload or written to disk.
            if (input["permission_mode"] as? String) == "plan"
                || ProposedPlanEnvelope.matches(input["last_assistant_message"] as? String) {
                return (.waitingForInput, nil, nil, nil, nil)
            }
            // Recent Claude Code versions explicitly list background tasks and
            // session crons at Stop. Retain only their absolute count; private
            // task objects, commands, schedules, and output are discarded.
            let backgroundTasks = input["background_tasks"] as? [Any]
            let sessionCrons = input["session_crons"] as? [Any]
            let backgroundWorkCount: Int?
            if backgroundTasks != nil || sessionCrons != nil {
                backgroundWorkCount = min(
                    1_024,
                    (backgroundTasks?.count ?? 0) + (sessionCrons?.count ?? 0)
                )
            } else {
                backgroundWorkCount = nil
            }
            return (
                .turnCompleted,
                backgroundWorkCount.map { $0 > 0 },
                backgroundWorkCount,
                nil,
                input["stop_hook_active"] as? Bool
            )
        case "StopFailure":
            return (.turnFailed, nil, nil, nil, input["stop_hook_active"] as? Bool)
        case "SubagentStart":
            return (
                .backgroundWorkChanged,
                true,
                nil,
                workToken(provider: provider, rawID: input["agent_id"] as? String),
                nil
            )
        case "SubagentStop":
            return (
                .backgroundWorkChanged,
                false,
                nil,
                workToken(provider: provider, rawID: input["agent_id"] as? String),
                nil
            )
        case "SessionEnd":
            return (.sessionEnded, nil, nil, nil, nil)
        default:
            return nil
        }
    }

    /// Tool identifiers can arrive as `functions.request_user_input`, as an
    /// MCP-qualified identifier such as `mcp__server__request_user_input`, or
    /// as the unqualified official name. Only the final namespace component is
    /// semantically relevant.
    static func normalizedToolName(_ rawName: String) -> String {
        rawName
            .split(whereSeparator: { ".:/".contains($0) })
            .last
            .map(String.init)?
            .components(separatedBy: "__")
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }

    static func isInputRequestTool(_ rawName: String) -> Bool {
        switch normalizedToolName(rawName).lowercased() {
        case "askuser", "askuserquestion", "request_user_input":
            return true
        default:
            return false
        }
    }

    /// Namespace the digest by provider. The returned token is stable and
    /// content-free; the raw ID is never encoded or written to disk.
    private static func workToken(provider: HookProvider, rawID: String?) -> String? {
        guard let rawID = validIdentifier(rawID) else { return nil }
        let digest = SHA256.hash(data: Data("\(provider.wireName)\0\(rawID)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func validIdentifier(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= maximumIdentifierLength else {
            return nil
        }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return value
    }
}

/// Strict recognition for the Codex plan protocol. Incidental prose containing
/// either tag is not a plan: both tags must be their own first/last non-empty
/// lines, with no content outside the envelope.
enum ProposedPlanEnvelope {
    static func matches(_ message: String?) -> Bool {
        guard let message else { return false }
        let normalized = message.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return false
        }
        return lines[first] == "<proposed_plan>"
            && lines[last] == "</proposed_plan>"
            && lines[..<first].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            && lines[lines.index(after: last)...].allSatisfy {
                $0.trimmingCharacters(in: .whitespaces).isEmpty
            }
    }
}

/// Privacy-minimizing parser for Codex's official `agent-turn-complete` notify
/// argument. Only stable identifiers and the derived plan/non-plan state leave
/// this function; input messages and assistant content are discarded.
enum CodexNotifyEventSanitizer {
    static func payload(
        from rawArgument: String,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> HookBridgePayload? {
        guard let data = rawArgument.data(using: .utf8),
              !data.isEmpty,
              data.count <= HookEventSanitizer.maximumInputBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let input = object as? [String: Any],
              (input["type"] as? String) == "agent-turn-complete",
              let threadID = HookEventSanitizer.validIdentifier(input["thread-id"] as? String),
              let turnID = HookEventSanitizer.validIdentifier(input["turn-id"] as? String) else {
            return nil
        }

        let isPlan = ProposedPlanEnvelope.matches(input["last-assistant-message"] as? String)
        return HookBridgePayload(
            provider: HookProvider.codex.wireName,
            sessionID: threadID,
            turnID: turnID,
            eventKind: isPlan ? .waitingForInput : .turnCompleted,
            waitingReason: isPlan ? .planConfirmation : nil,
            // `agent-turn-complete` does not carry an authoritative snapshot
            // of Codex subagent work. Omitting both fields prevents a relay
            // delivered after SubagentStart/Stop hooks from erasing the
            // state machine's independently tracked background count.
            backgroundWork: nil,
            backgroundWorkCount: nil,
            timestamp: timestamp
        )
    }

    static func encodedPayload(
        from rawArgument: String,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Data? {
        guard let payload = payload(from: rawArgument, timestamp: timestamp) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(payload)
    }
}

/// Exact runtime argv parser shared by the bridge executable and tests. The
/// configured forwarding count prevents existing notify arguments named
/// `--forward` (or arbitrary JSON-looking strings) from becoming delimiters.
struct CodexNotifyRelayInvocation: Equatable {
    let appBundleIdentifier: String
    let socketPath: String
    let forwardedArguments: [String]
    let rawPayloadArgument: String

    static func parse(runtimeArguments: [String]) -> CodexNotifyRelayInvocation? {
        guard runtimeArguments.first == "--notify-relay",
              runtimeArguments.count >= 8,
              runtimeArguments[1] == "--app-bundle-id",
              runtimeArguments[3] == "--socket-path",
              runtimeArguments[5] == "--forward-count",
              let count = Int(runtimeArguments[6]),
              count >= 0 else { return nil }
        let forwardedStart = 7
        let payloadIndex = forwardedStart + count
        guard payloadIndex >= forwardedStart,
              runtimeArguments.indices.contains(payloadIndex),
              payloadIndex == runtimeArguments.count - 1 else { return nil }
        let appBundleIdentifier = runtimeArguments[2]
        let socketPath = runtimeArguments[4]
        guard HookIntegrationPaths.normalizedAppBundleIdentifier(appBundleIdentifier)
                == appBundleIdentifier,
              socketPath.hasPrefix("/") else { return nil }
        return CodexNotifyRelayInvocation(
            appBundleIdentifier: appBundleIdentifier,
            socketPath: socketPath,
            forwardedArguments: Array(runtimeArguments[forwardedStart..<payloadIndex]),
            rawPayloadArgument: runtimeArguments[payloadIndex]
        )
    }
}
