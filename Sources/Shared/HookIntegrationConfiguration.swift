import Foundation
import CoreFoundation

struct HookConfigurationEdit {
    let data: Data
    let changed: Bool
}

/// Structural JSON editor used for both Codex `hooks.json` and Claude Code
/// `settings.json`. It never string-splices JSON: unknown objects and handlers
/// survive a round trip, while malformed or ambiguous hook structures fail
/// before any file-system write begins.
enum HookConfigurationEditor {
    private static let bridgeName = HookIntegrationPaths.bridgeExecutableName

    static func installing(
        in originalData: Data?,
        provider: HookProvider,
        appBundleIdentifier: String = HookIntegrationPaths.releaseAppBundleIdentifier
    ) throws -> HookConfigurationEdit {
        var root = try parseRoot(originalData)
        var hooks = try validatedHooks(from: root)
        var changed = false
        let command = HookIntegrationPaths.bridgeCommand(
            provider: provider,
            appBundleIdentifier: appBundleIdentifier
        )

        for event in provider.installedEvents {
            var groups = try validatedGroups(hooks[event], event: event)
            var foundCanonicalHandler = false

            for groupIndex in groups.indices {
                guard var group = groups[groupIndex] as? [String: Any] else {
                    throw HookIntegrationError.conflictingStructure("hooks.\(event)[\(groupIndex)]")
                }
                var handlers = try validatedHandlers(group["hooks"], event: event)
                var keptHandlers: [Any] = []
                let matcherIsCanonical = groupMatcherIsCanonical(
                    group,
                    provider: provider,
                    event: event
                )

                for value in handlers {
                    guard let handler = value as? [String: Any] else {
                        throw HookIntegrationError.conflictingStructure("hooks.\(event)[\(groupIndex)].hooks")
                    }
                    let existingCommand = handler["command"] as? String
                    if let existingCommand, existingCommand.contains(bridgeName) {
                        guard existingCommand == command,
                              (handler["type"] as? String) == "command" else {
                            throw HookIntegrationError.conflictingBridgeCommand(event)
                        }
                        if !matcherIsCanonical || !handlerExecutionIsCanonical(
                            handler,
                            provider: provider,
                            event: event
                        ) {
                            // The command is ours but lives under a matcher that
                            // does not cover the intended lifecycle event. Remove
                            // only that handler and append a canonical group.
                            changed = true
                            continue
                        }
                        if foundCanonicalHandler {
                            changed = true
                            continue
                        }
                        foundCanonicalHandler = true
                    }
                    keptHandlers.append(handler)
                }

                if keptHandlers.count != handlers.count {
                    handlers = keptHandlers
                    group["hooks"] = handlers
                    groups[groupIndex] = group
                }
            }

            if !foundCanonicalHandler {
                groups.append(canonicalGroup(
                    provider: provider,
                    event: event,
                    appBundleIdentifier: appBundleIdentifier
                ))
                changed = true
            }
            hooks[event] = groups
        }

        if changed || root["hooks"] == nil {
            root["hooks"] = hooks
            return HookConfigurationEdit(data: try encoded(root), changed: true)
        }
        let unchangedData = try originalData ?? encoded(root)
        return HookConfigurationEdit(data: unchangedData, changed: false)
    }

    static func uninstalling(
        from originalData: Data?,
        provider: HookProvider,
        appBundleIdentifier: String = HookIntegrationPaths.releaseAppBundleIdentifier
    ) throws -> HookConfigurationEdit {
        guard let originalData else {
            return HookConfigurationEdit(data: Data(), changed: false)
        }
        var root = try parseRoot(originalData)
        guard root["hooks"] != nil else {
            return HookConfigurationEdit(data: originalData, changed: false)
        }
        var hooks = try validatedHooks(from: root)
        let command = HookIntegrationPaths.bridgeCommand(
            provider: provider,
            appBundleIdentifier: appBundleIdentifier
        )
        var changed = false

        for event in Array(hooks.keys) {
            var groups = try validatedGroups(hooks[event], event: event)
            var keptGroups: [Any] = []

            for (groupIndex, value) in groups.enumerated() {
                guard var group = value as? [String: Any] else {
                    throw HookIntegrationError.conflictingStructure("hooks.\(event)[\(groupIndex)]")
                }
                let handlers = try validatedHandlers(group["hooks"], event: event)
                let keptHandlers = try handlers.filter { value in
                    guard let handler = value as? [String: Any] else {
                        throw HookIntegrationError.conflictingStructure("hooks.\(event)[\(groupIndex)].hooks")
                    }
                    let remove = (handler["type"] as? String) == "command"
                        && (handler["command"] as? String) == command
                    if remove { changed = true }
                    return !remove
                }

                if keptHandlers.isEmpty, Set(group.keys) == Set(["hooks"]) {
                    continue
                }
                group["hooks"] = keptHandlers
                keptGroups.append(group)
            }

            groups = keptGroups
            if groups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = groups
            }
        }

        guard changed else {
            return HookConfigurationEdit(data: originalData, changed: false)
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return HookConfigurationEdit(data: try encoded(root), changed: true)
    }

    static func health(
        of originalData: Data?,
        provider: HookProvider,
        appBundleIdentifier: String = HookIntegrationPaths.releaseAppBundleIdentifier
    ) -> HookIntegrationHealthState {
        guard let originalData else { return .notInstalled }
        do {
            let root = try parseRoot(originalData)
            guard root["hooks"] != nil else { return .notInstalled }
            let hooks = try validatedHooks(from: root)
            let command = HookIntegrationPaths.bridgeCommand(
                provider: provider,
                appBundleIdentifier: appBundleIdentifier
            )
            var installedEvents = 0

            for event in provider.installedEvents {
                let groups = try validatedGroups(hooks[event], event: event)
                var matches = 0
                for (groupIndex, value) in groups.enumerated() {
                    guard let group = value as? [String: Any] else {
                        throw HookIntegrationError.conflictingStructure("hooks.\(event)[\(groupIndex)]")
                    }
                    let matcherIsCanonical = groupMatcherIsCanonical(
                        group,
                        provider: provider,
                        event: event
                    )
                    for handlerValue in try validatedHandlers(group["hooks"], event: event) {
                        guard let handler = handlerValue as? [String: Any] else {
                            throw HookIntegrationError.conflictingStructure("hooks.\(event)[\(groupIndex)].hooks")
                        }
                        if let existingCommand = handler["command"] as? String,
                           existingCommand.contains(bridgeName) {
                            guard existingCommand == command,
                                  (handler["type"] as? String) == "command" else {
                                return .conflict
                            }
                            guard matcherIsCanonical,
                                  handlerExecutionIsCanonical(
                                    handler,
                                    provider: provider,
                                    event: event
                                  ) else { return .needsRepair }
                            matches += 1
                        }
                    }
                }
                if matches == 1 { installedEvents += 1 }
                if matches > 1 { return .needsRepair }
            }

            if installedEvents == 0 { return .notInstalled }
            if installedEvents == provider.installedEvents.count { return .installed }
            return .needsRepair
        } catch HookIntegrationError.invalidJSON, HookIntegrationError.invalidTopLevel {
            return .invalidConfiguration
        } catch {
            return .conflict
        }
    }

    private static func canonicalHandler(
        provider: HookProvider,
        event: String,
        appBundleIdentifier: String
    ) -> [String: Any] {
        var handler: [String: Any] = [
            "type": "command",
            "command": HookIntegrationPaths.bridgeCommand(
                provider: provider,
                appBundleIdentifier: appBundleIdentifier
            ),
            // The bridge enforces its own one-second total deadline. Give the
            // hook runner one extra second to schedule/tear down the process so
            // it cannot kill the final launch-and-send retry at the boundary.
            "timeout": 2,
        ]
        // Completion, continuation, waiting, and background-work boundaries are
        // ordered for both providers. All matching Codex hooks may still launch
        // concurrently, so the later five-second completion confirmation remains
        // best-effort. PostToolUse is observational and stays asynchronous.
        // The bridge is hard-bounded to one second and always exits success.
        if canonicalAsync(provider: provider, event: event) == true {
            handler["async"] = true
        }
        return handler
    }

    private static func canonicalGroup(
        provider: HookProvider,
        event: String,
        appBundleIdentifier: String
    ) -> [String: Any] {
        var group: [String: Any] = ["hooks": [canonicalHandler(
            provider: provider,
            event: event,
            appBundleIdentifier: appBundleIdentifier
        )]]
        if provider == .claudeCode, event == "Notification" {
            group["matcher"] = "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input"
        }
        return group
    }

    private static func groupMatcherIsCanonical(
        _ group: [String: Any],
        provider: HookProvider,
        event: String
    ) -> Bool {
        let expected = provider == .claudeCode && event == "Notification"
            ? "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input"
            : nil
        return group["matcher"] as? String == expected
            && (expected != nil || group["matcher"] == nil)
    }

    private static func canonicalAsync(provider: HookProvider, event: String) -> Bool? {
        _ = provider
        return ["PostToolUse", "PostToolUseFailure"].contains(event) ? true : nil
    }

    private static func handlerExecutionIsCanonical(
        _ handler: [String: Any],
        provider: HookProvider,
        event: String
    ) -> Bool {
        var expectedKeys: Set<String> = ["type", "command", "timeout"]
        if canonicalAsync(provider: provider, event: event) == true {
            expectedKeys.insert("async")
        }
        // Reject execution modifiers (`if`, `once`, alternate shells, etc.) on
        // our own command. They can make a syntactically installed lifecycle
        // hook run only for some tools—or never run at all.
        guard Set(handler.keys) == expectedKeys else { return false }
        guard let rawTimeout = handler["timeout"],
              CFGetTypeID(rawTimeout as CFTypeRef) != CFBooleanGetTypeID(),
              let timeout = rawTimeout as? NSNumber,
              !CFNumberIsFloatType(timeout),
              timeout.doubleValue == 2 else { return false }
        if canonicalAsync(provider: provider, event: event) == true {
            return strictJSONBoolean(handler["async"]) == true
        }
        return handler["async"] == nil || strictJSONBoolean(handler["async"]) == false
    }

    private static func strictJSONBoolean(_ value: Any?) -> Bool? {
        guard let value,
              CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(),
              let number = value as? NSNumber else { return nil }
        return number.boolValue
    }

    private static func parseRoot(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HookIntegrationError.invalidJSON
        }
        guard let root = object as? [String: Any] else {
            throw HookIntegrationError.invalidTopLevel
        }
        return root
    }

    private static func validatedHooks(from root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else {
            throw HookIntegrationError.conflictingStructure("hooks")
        }
        // Validate every existing event, not only the events we install. This
        // prevents serializing a known-broken document while claiming success.
        for (event, value) in hooks {
            _ = try validatedGroups(value, event: event)
        }
        return hooks
    }

    private static func validatedGroups(_ value: Any?, event: String) throws -> [Any] {
        guard let value else { return [] }
        guard let groups = value as? [Any] else {
            throw HookIntegrationError.conflictingStructure("hooks.\(event)")
        }
        for (index, value) in groups.enumerated() {
            guard let group = value as? [String: Any] else {
                throw HookIntegrationError.conflictingStructure("hooks.\(event)[\(index)]")
            }
            _ = try validatedHandlers(group["hooks"], event: event)
        }
        return groups
    }

    private static func validatedHandlers(_ value: Any?, event: String) throws -> [Any] {
        guard let handlers = value as? [Any] else {
            throw HookIntegrationError.conflictingStructure("hooks.\(event)[].hooks")
        }
        guard handlers.allSatisfy({ $0 is [String: Any] }) else {
            throw HookIntegrationError.conflictingStructure("hooks.\(event)[].hooks[]")
        }
        return handlers
    }

    private static func encoded(_ root: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }
}

private struct CodexNotifyAssignment {
    let range: Range<String.Index>
    let arguments: [String]
}

private struct CodexNotifyDocument {
    let text: String
    let assignment: CodexNotifyAssignment?
    let topLevelInsertionIndex: String.Index
}

private struct ParsedOwnedNotifyRelay {
    let bridgePath: String
    let appBundleIdentifier: String
    let socketPath: String
    let forwardedArguments: [String]
}

private struct ParsedPreviousNotifyRelay {
    let baseArguments: [String]
    let insertionIndex: Int
    let nestedArguments: [String]
}

private struct NormalizedNotifyArguments {
    let arguments: [String]
    let removedOwnedRelay: Bool
}

/// Conservative structural editor for Codex's top-level `notify = [...]`
/// setting. It preserves the rest of config.toml byte-for-byte and refuses
/// ambiguous or unsupported notify syntax instead of string-splicing it.
enum CodexNotifyConfigurationEditor {
    static func installing(
        in originalData: Data?,
        homeDirectory: URL,
        appBundleIdentifier: String = HookIntegrationPaths.releaseAppBundleIdentifier
    ) throws -> HookConfigurationEdit {
        let document = try parseDocument(originalData)
        let existingArguments = document.assignment?.arguments ?? []
        let forwardedArguments = try normalizedForwardedArguments(existingArguments).arguments
        let canonical = HookIntegrationPaths.notifyRelayArguments(
            homeDirectory: homeDirectory,
            forwardedArguments: forwardedArguments,
            appBundleIdentifier: appBundleIdentifier
        )
        if document.assignment?.arguments == canonical {
            return HookConfigurationEdit(data: originalData ?? Data(), changed: false)
        }

        let line = try encodedNotifyLine(canonical)
        let updated: String
        if let assignment = document.assignment {
            updated = document.text.replacingCharacters(in: assignment.range, with: line)
        } else {
            var insertion = line
            if document.topLevelInsertionIndex > document.text.startIndex,
               document.text[document.text.index(before: document.topLevelInsertionIndex)] != "\n" {
                insertion = "\n" + insertion
            }
            updated = document.text.replacingCharacters(
                in: document.topLevelInsertionIndex..<document.topLevelInsertionIndex,
                with: insertion
            )
        }
        return HookConfigurationEdit(data: Data(updated.utf8), changed: true)
    }

    /// Restore the forwarded argv only while config.toml still points to this
    /// exact Lidless relay. A custom notify value or a relay owned by a different
    /// app build is user state and remains untouched.
    static func uninstalling(
        from originalData: Data?,
        homeDirectory: URL,
        appBundleIdentifier: String = HookIntegrationPaths.releaseAppBundleIdentifier
    ) throws -> HookConfigurationEdit {
        guard let originalData else {
            return HookConfigurationEdit(data: Data(), changed: false)
        }
        let document = try parseDocument(originalData)
        guard let assignment = document.assignment,
              let owned = try? parsedOwnedRelay(assignment.arguments),
              isRelayForCurrentBuild(
                owned,
                homeDirectory: homeDirectory,
                appBundleIdentifier: appBundleIdentifier
              ) else {
            return HookConfigurationEdit(data: originalData, changed: false)
        }

        let replacement = owned.forwardedArguments.isEmpty
            ? ""
            : try encodedNotifyLine(owned.forwardedArguments)
        let updated = document.text.replacingCharacters(in: assignment.range, with: replacement)
        return HookConfigurationEdit(data: Data(updated.utf8), changed: true)
    }

    static func health(
        of originalData: Data?,
        homeDirectory: URL,
        appBundleIdentifier: String = HookIntegrationPaths.releaseAppBundleIdentifier
    ) -> HookIntegrationHealthState {
        guard originalData != nil else { return .notInstalled }
        do {
            let document = try parseDocument(originalData)
            guard let arguments = document.assignment?.arguments else { return .notInstalled }
            guard let owned = try parsedOwnedRelay(arguments) else {
                return try containsOwnedRelay(in: arguments) ? .needsRepair : .notInstalled
            }
            let canonical = HookIntegrationPaths.notifyRelayArguments(
                homeDirectory: homeDirectory,
                forwardedArguments: owned.forwardedArguments,
                appBundleIdentifier: appBundleIdentifier
            )
            let hasNestedOwnedRelay = try containsOwnedRelay(in: owned.forwardedArguments)
            return arguments == canonical && !hasNestedOwnedRelay ? .installed : .needsRepair
        } catch HookIntegrationError.invalidTOML {
            return .invalidConfiguration
        } catch {
            return .conflict
        }
    }

    private static func isRelayForCurrentBuild(
        _ relay: ParsedOwnedNotifyRelay,
        homeDirectory: URL,
        appBundleIdentifier: String
    ) -> Bool {
        let bundleID = HookIntegrationPaths.normalizedAppBundleIdentifier(appBundleIdentifier)
        return relay.bridgePath == HookIntegrationPaths.bridgeURL(homeDirectory: homeDirectory).path
            && relay.appBundleIdentifier == bundleID
            && relay.socketPath == HookIntegrationPaths.socketURL(
                homeDirectory: homeDirectory,
                appBundleIdentifier: bundleID
            ).path
    }

    private static func parsedOwnedRelay(_ arguments: [String]) throws -> ParsedOwnedNotifyRelay? {
        guard !arguments.isEmpty else { return nil }
        let namesBridge = URL(fileURLWithPath: arguments[0]).lastPathComponent
            == HookIntegrationPaths.bridgeExecutableName
        guard namesBridge || (arguments.indices.contains(1) && arguments[1] == "--notify-relay") else {
            return nil
        }
        guard arguments.count >= 7,
              arguments[1] == "--notify-relay",
              arguments[2] == "--app-bundle-id",
              arguments[4] == "--socket-path",
              arguments[6] == "--forward-count",
              arguments.indices.contains(7),
              let count = Int(arguments[7]),
              count >= 0,
              arguments.count == 8 + count else {
            throw HookIntegrationError.conflictingNotifyRelay
        }
        return ParsedOwnedNotifyRelay(
            bridgePath: arguments[0],
            appBundleIdentifier: arguments[3],
            socketPath: arguments[5],
            forwardedArguments: Array(arguments.dropFirst(8))
        )
    }

    /// Removes Lidless relays from a supported `--previous-notify` chain before
    /// the caller adds one canonical outer relay. Computer Use stores its prior
    /// notify argv as a JSON string array; only that unambiguous shape is
    /// traversed. Opaque external commands are left byte-for-byte equivalent at
    /// the argv level.
    private static func normalizedForwardedArguments(
        _ arguments: [String],
        depth: Int = 0
    ) throws -> NormalizedNotifyArguments {
        guard depth < 64 else { throw HookIntegrationError.conflictingNotifyRelay }

        if let owned = try parsedOwnedRelay(arguments) {
            let nested = try normalizedForwardedArguments(
                owned.forwardedArguments,
                depth: depth + 1
            )
            return NormalizedNotifyArguments(
                arguments: nested.arguments,
                removedOwnedRelay: true
            )
        }

        guard let previous = parsedPreviousNotifyRelay(arguments) else {
            return NormalizedNotifyArguments(
                arguments: arguments,
                removedOwnedRelay: false
            )
        }
        let nested = try normalizedForwardedArguments(
            previous.nestedArguments,
            depth: depth + 1
        )
        guard nested.removedOwnedRelay else {
            // No Lidless layer exists below this external command. Preserve its
            // original previous-notify string instead of decoding/re-encoding it.
            return NormalizedNotifyArguments(
                arguments: arguments,
                removedOwnedRelay: false
            )
        }

        // Alternating installers can produce A(previous=Lidless(A(...))). Once
        // the owned layer is removed, keep the innermost A and discard only the
        // duplicate outer A. Distinct external relays remain chained.
        if previous.baseArguments == leadingExternalCommand(in: nested.arguments) {
            return NormalizedNotifyArguments(
                arguments: nested.arguments,
                removedOwnedRelay: true
            )
        }
        return NormalizedNotifyArguments(
            arguments: try rebuildingPreviousNotifyRelay(
                previous,
                nestedArguments: nested.arguments
            ),
            removedOwnedRelay: true
        )
    }

    private static func containsOwnedRelay(
        in arguments: [String],
        depth: Int = 0
    ) throws -> Bool {
        guard depth < 64 else { throw HookIntegrationError.conflictingNotifyRelay }
        if try parsedOwnedRelay(arguments) != nil { return true }
        guard let previous = parsedPreviousNotifyRelay(arguments) else { return false }
        return try containsOwnedRelay(
            in: previous.nestedArguments,
            depth: depth + 1
        )
    }

    private static func parsedPreviousNotifyRelay(
        _ arguments: [String]
    ) -> ParsedPreviousNotifyRelay? {
        let matches = arguments.indices.filter { arguments[$0] == "--previous-notify" }
        guard matches.count == 1,
              let index = matches.first,
              arguments.indices.contains(index + 1),
              let data = arguments[index + 1].data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let nestedArguments = object as? [String]
        else { return nil }

        var baseArguments = arguments
        baseArguments.removeSubrange(index...(index + 1))
        return ParsedPreviousNotifyRelay(
            baseArguments: baseArguments,
            insertionIndex: index,
            nestedArguments: nestedArguments
        )
    }

    private static func leadingExternalCommand(in arguments: [String]) -> [String] {
        parsedPreviousNotifyRelay(arguments)?.baseArguments ?? arguments
    }

    private static func rebuildingPreviousNotifyRelay(
        _ relay: ParsedPreviousNotifyRelay,
        nestedArguments: [String]
    ) throws -> [String] {
        var arguments = relay.baseArguments
        let nestedJSON = try encodedArgumentArray(nestedArguments)
        arguments.insert("--previous-notify", at: relay.insertionIndex)
        arguments.insert(nestedJSON, at: relay.insertionIndex + 1)
        return arguments
    }

    private static func encodedArgumentArray(_ arguments: [String]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: arguments,
            options: [.withoutEscapingSlashes]
        )
        guard let array = String(data: data, encoding: .utf8) else {
            throw HookIntegrationError.invalidTOML
        }
        return array
    }

    private static func encodedNotifyLine(_ arguments: [String]) throws -> String {
        "notify = \(try encodedArgumentArray(arguments))\n"
    }

    private static func parseDocument(_ data: Data?) throws -> CodexNotifyDocument {
        guard let data else {
            return CodexNotifyDocument(text: "", assignment: nil, topLevelInsertionIndex: "".endIndex)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw HookIntegrationError.invalidTOML
        }
        var index = text.startIndex
        var assignment: CodexNotifyAssignment?
        var firstTableIndex: String.Index?

        while index < text.endIndex {
            let lineStart = index
            let lineEnd = text[index...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" || $0 == "\r" })
            if trimmed.first == "[" {
                firstTableIndex = lineStart
                break
            }
            if let valueStart = notifyValueStart(in: text, lineStart: lineStart, lineEnd: lineEnd) {
                guard assignment == nil else { throw HookIntegrationError.invalidTOML }
                let parsed = try parseStringArray(in: text, startingAt: valueStart)
                let assignmentEnd = try endOfAssignment(
                    in: text,
                    afterArray: parsed.endIndex
                )
                assignment = CodexNotifyAssignment(
                    range: lineStart..<assignmentEnd,
                    arguments: parsed.arguments
                )
                index = assignmentEnd
                continue
            }
            index = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }

        return CodexNotifyDocument(
            text: text,
            assignment: assignment,
            topLevelInsertionIndex: firstTableIndex ?? text.endIndex
        )
    }

    private static func notifyValueStart(
        in text: String,
        lineStart: String.Index,
        lineEnd: String.Index
    ) -> String.Index? {
        var cursor = lineStart
        while cursor < lineEnd, text[cursor] == " " || text[cursor] == "\t" {
            cursor = text.index(after: cursor)
        }
        guard text[cursor..<lineEnd].hasPrefix("notify") else { return nil }
        cursor = text.index(cursor, offsetBy: "notify".count)
        guard cursor == lineEnd || text[cursor] == " " || text[cursor] == "\t" || text[cursor] == "=" else {
            return nil
        }
        while cursor < lineEnd, text[cursor] == " " || text[cursor] == "\t" {
            cursor = text.index(after: cursor)
        }
        guard cursor < lineEnd, text[cursor] == "=" else { return nil }
        return text.index(after: cursor)
    }

    private static func parseStringArray(
        in text: String,
        startingAt start: String.Index
    ) throws -> (arguments: [String], endIndex: String.Index) {
        var cursor = try skipWhitespaceAndComments(in: text, from: start)
        guard cursor < text.endIndex, text[cursor] == "[" else {
            throw HookIntegrationError.invalidTOML
        }
        cursor = text.index(after: cursor)
        var arguments: [String] = []
        var expectValue = true

        while true {
            cursor = try skipWhitespaceAndComments(in: text, from: cursor)
            guard cursor < text.endIndex else { throw HookIntegrationError.invalidTOML }
            if text[cursor] == "]" {
                return (arguments, text.index(after: cursor))
            }
            guard expectValue else { throw HookIntegrationError.invalidTOML }
            let parsed = try parseTOMLString(in: text, startingAt: cursor)
            arguments.append(parsed.value)
            cursor = try skipWhitespaceAndComments(in: text, from: parsed.endIndex)
            guard cursor < text.endIndex else { throw HookIntegrationError.invalidTOML }
            if text[cursor] == "," {
                cursor = text.index(after: cursor)
                expectValue = true
                continue
            }
            if text[cursor] == "]" {
                return (arguments, text.index(after: cursor))
            }
            expectValue = false
        }
    }

    private static func parseTOMLString(
        in text: String,
        startingAt start: String.Index
    ) throws -> (value: String, endIndex: String.Index) {
        guard start < text.endIndex else { throw HookIntegrationError.invalidTOML }
        if text[start] == "'" {
            let contentStart = text.index(after: start)
            guard let end = text[contentStart...].firstIndex(of: "'") else {
                throw HookIntegrationError.invalidTOML
            }
            return (String(text[contentStart..<end]), text.index(after: end))
        }
        guard text[start] == "\"" else { throw HookIntegrationError.invalidTOML }
        var cursor = text.index(after: start)
        var escaped = false
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "\n" || character == "\r" {
                throw HookIntegrationError.invalidTOML
            }
            if !escaped, character == "\"" {
                let token = String(text[start...cursor])
                guard let tokenData = "[\(token)]".data(using: .utf8),
                      let decoded = try? JSONSerialization.jsonObject(with: tokenData) as? [String],
                      let value = decoded.first else {
                    throw HookIntegrationError.invalidTOML
                }
                return (value, text.index(after: cursor))
            }
            if character == "\\", !escaped {
                escaped = true
            } else {
                escaped = false
            }
            cursor = text.index(after: cursor)
        }
        throw HookIntegrationError.invalidTOML
    }

    private static func skipWhitespaceAndComments(
        in text: String,
        from start: String.Index
    ) throws -> String.Index {
        var cursor = start
        while cursor < text.endIndex {
            switch text[cursor] {
            case " ", "\t", "\r", "\n":
                cursor = text.index(after: cursor)
            case "#":
                cursor = text[cursor...].firstIndex(of: "\n").map { text.index(after: $0) }
                    ?? text.endIndex
            default:
                return cursor
            }
        }
        return cursor
    }

    private static func endOfAssignment(
        in text: String,
        afterArray start: String.Index
    ) throws -> String.Index {
        var cursor = start
        while cursor < text.endIndex, text[cursor] == " " || text[cursor] == "\t" || text[cursor] == "\r" {
            cursor = text.index(after: cursor)
        }
        if cursor < text.endIndex, text[cursor] == "#" {
            cursor = text[cursor...].firstIndex(of: "\n") ?? text.endIndex
        }
        guard cursor == text.endIndex || text[cursor] == "\n" else {
            throw HookIntegrationError.invalidTOML
        }
        return cursor < text.endIndex ? text.index(after: cursor) : cursor
    }
}
