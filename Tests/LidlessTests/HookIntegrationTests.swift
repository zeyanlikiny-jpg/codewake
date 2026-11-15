import Darwin
import XCTest

final class HookIntegrationTests: XCTestCase {
    func testCodexPayloadWhitelistsFieldsAndMapsPrompt() throws {
        let input: [String: Any] = [
            "session_id": "session-1",
            "turn_id": "turn-1",
            "hook_event_name": "UserPromptSubmit",
            "cwd": "/private/project",
            "transcript_path": "/private/transcript.jsonl",
            "prompt": "private user prompt",
            "model": "private-model-name",
        ]
        let data = try JSONSerialization.data(withJSONObject: input)
        let encoded = try XCTUnwrap(
            HookEventSanitizer.encodedPayload(from: data, provider: .codex, timestamp: 1234.5)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            Set(["schemaVersion", "provider", "sessionID", "turnID", "eventKind", "timestamp"])
        )
        XCTAssertEqual(
            object["schemaVersion"] as? Int,
            HookBridgePayload.currentSchemaVersion
        )
        XCTAssertEqual(object["provider"] as? String, "codex")
        XCTAssertEqual(object["sessionID"] as? String, "session-1")
        XCTAssertEqual(object["turnID"] as? String, "turn-1")
        XCTAssertEqual(object["eventKind"] as? String, "promptSubmitted")
        XCTAssertEqual(object["timestamp"] as? Double, 1234.5)
        XCTAssertNil(object["cwd"])
        XCTAssertNil(object["prompt"])
        XCTAssertNil(object["transcript_path"])
    }

    func testSocketDecodersSeparateCurrentFromSupportedBridgeSchemas() throws {
        let current = HookBridgePayload(
            provider: "codex",
            sessionID: "session",
            turnID: "turn",
            eventKind: .turnCompleted,
            backgroundWork: false,
            backgroundWorkCount: 0,
            timestamp: 1
        )
        let currentData = try JSONEncoder().encode(current)
        XCTAssertEqual(HookBridgePayload.decodeCurrent(from: currentData), current)
        XCTAssertEqual(HookBridgePayload.decodeSupported(from: currentData), current)

        let base: TimeInterval = 1_700_000_000
        let legacyPromptData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "provider": "codex",
            "sessionID": "legacy-session",
            "turnID": "legacy-turn",
            "eventKind": "promptSubmitted",
            "timestamp": base,
        ])
        let legacyPrompt = try XCTUnwrap(
            HookBridgePayload.decodeSupported(from: legacyPromptData)
        )
        XCTAssertEqual(legacyPrompt.schemaVersion, 1)
        XCTAssertNil(legacyPrompt.backgroundWorkCount)
        XCTAssertNil(legacyPrompt.workToken)
        XCTAssertNil(legacyPrompt.stopHookActive)
        XCTAssertNil(HookBridgePayload.decodeCurrent(from: legacyPromptData))

        let v2PromptData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "provider": "codex",
            "sessionID": "v2-session",
            "turnID": "v2-turn",
            "eventKind": "promptSubmitted",
            "timestamp": base,
        ])
        XCTAssertEqual(
            HookBridgePayload.decodeSupported(from: v2PromptData)?.schemaVersion,
            2
        )
        XCTAssertNil(HookBridgePayload.decodeCurrent(from: v2PromptData))

        let legacyStopData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "provider": "codex",
            "sessionID": "legacy-session",
            "turnID": "legacy-turn",
            "eventKind": "turnStopped",
            "backgroundWork": false,
            "timestamp": base + 1,
        ])
        let legacyStop = try XCTUnwrap(
            HookBridgePayload.decodeSupported(from: legacyStopData)
        )

        func event(from payload: HookBridgePayload) throws -> AgentEvent {
            AgentEvent(
                schemaVersion: payload.schemaVersion,
                provider: try XCTUnwrap(AgentProvider(rawValue: payload.provider)),
                sessionID: payload.sessionID,
                turnID: payload.turnID,
                eventKind: try XCTUnwrap(AgentEventKind(rawValue: payload.eventKind.rawValue)),
                waitingReason: payload.waitingReason.flatMap {
                    AgentWaitingReason(rawValue: $0.rawValue)
                },
                backgroundWork: payload.backgroundWork,
                backgroundWorkCount: payload.backgroundWorkCount,
                workToken: payload.workToken,
                stopHookActive: payload.stopHookActive,
                timestamp: Date(timeIntervalSince1970: payload.timestamp)
            )
        }
        var machine = AgentStateMachine(
            maximumTurnDuration: 1_000,
            completionConfirmation: 5,
            waitingGrace: 300
        )
        machine.ingest(try event(from: legacyPrompt))
        machine.ingest(try event(from: legacyStop))
        let legacyState = machine.allSessions(
            at: Date(timeIntervalSince1970: base + 301)
        ).first
        XCTAssertEqual(legacyState?.phase, .finished)
        XCTAssertEqual(legacyState?.terminalDisposition, .legacyRelease)
        XCTAssertFalse(
            legacyState?.isSleepEligibleCompletion(
                at: Date(timeIntervalSince1970: base + 301)
            ) == true
        )

        var unknown = try XCTUnwrap(
            JSONSerialization.jsonObject(with: currentData) as? [String: Any]
        )
        unknown["schemaVersion"] = 99
        let unknownData = try JSONSerialization.data(withJSONObject: unknown)
        XCTAssertNil(HookBridgePayload.decodeSupported(from: unknownData))
        XCTAssertNil(HookBridgePayload.decodeCurrent(from: unknownData))
    }

    func testClaudeUsesPromptIDAsTurnID() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "session_id": "claude-session",
            "prompt_id": "prompt-uuid",
            "hook_event_name": "UserPromptSubmit",
            "prompt": "do not forward",
        ])
        let payload = try XCTUnwrap(
            HookEventSanitizer.payload(from: data, provider: .claudeCode, timestamp: 9)
        )
        XCTAssertEqual(payload.provider, "claude")
        XCTAssertEqual(payload.turnID, "prompt-uuid")
        XCTAssertEqual(payload.eventKind, .promptSubmitted)
    }

    func testOlderClaudePromptWithoutPromptIDRemainsUsable() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "session_id": "claude-session",
            "hook_event_name": "UserPromptSubmit",
            "prompt": "do not forward",
        ])
        let payload = try XCTUnwrap(
            HookEventSanitizer.payload(from: data, provider: .claudeCode, timestamp: 9)
        )
        XCTAssertNil(payload.turnID)
        XCTAssertEqual(payload.eventKind, .promptSubmitted)
    }

    func testAskUserToolMapsToWaitingWithoutForwardingQuestion() throws {
        for toolName in [
            "AskUserQuestion",
            "request_user_input",
            "functions.request_user_input",
            "mcp__codex__request_user_input",
            "tools/functions.request_user_input",
        ] {
            let data = try JSONSerialization.data(withJSONObject: [
                "session_id": "session",
                "prompt_id": "prompt",
                "hook_event_name": "PreToolUse",
                "tool_name": toolName,
                "tool_input": ["question": "private question"],
            ])
            let payload = try XCTUnwrap(
                HookEventSanitizer.payload(from: data, provider: .claudeCode, timestamp: 9)
            )
            XCTAssertEqual(payload.eventKind, .waitingForInput)
            XCTAssertEqual(payload.waitingReason, .userInput)
            let encoded = try JSONEncoder().encode(payload)
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("private question"))
        }
    }

    func testPreAndPostToolEventsHaveDirectionalSemantics() throws {
        func payload(_ event: String, tool: String) throws -> HookBridgePayload {
            let data = try JSONSerialization.data(withJSONObject: [
                "session_id": "session",
                "turn_id": "turn",
                "hook_event_name": event,
                "tool_name": tool,
            ])
            return try XCTUnwrap(
                HookEventSanitizer.payload(from: data, provider: .codex, timestamp: 9)
            )
        }

        XCTAssertEqual(try payload("PreToolUse", tool: "functions.shell").eventKind, .toolStarted)
        XCTAssertEqual(try payload("PostToolUse", tool: "functions.shell").eventKind, .toolFinished)
        XCTAssertEqual(
            try payload("PreToolUse", tool: "functions.request_user_input").eventKind,
            .waitingForInput
        )
        XCTAssertEqual(
            try payload("PostToolUse", tool: "mcp__codex__request_user_input").eventKind,
            .inputReceived
        )

        let permissionData = try JSONSerialization.data(withJSONObject: [
            "session_id": "session",
            "turn_id": "turn",
            "hook_event_name": "PermissionRequest",
            "tool_input": ["private": "discard"],
        ])
        let permission = try XCTUnwrap(
            HookEventSanitizer.payload(from: permissionData, provider: .codex, timestamp: 9)
        )
        XCTAssertEqual(permission.eventKind, .waitingForInput)
        XCTAssertEqual(permission.waitingReason, .permission)
    }

    func testCodexStopRecognizesOnlyPlanModeOrExactPlanEnvelope() throws {
        func payload(
            permissionMode: String? = nil,
            message: String?
        ) throws -> HookBridgePayload {
            var object: [String: Any] = [
                "session_id": "session",
                "turn_id": "turn",
                "hook_event_name": "Stop",
            ]
            object["permission_mode"] = permissionMode
            object["last_assistant_message"] = message
            let data = try JSONSerialization.data(withJSONObject: object)
            return try XCTUnwrap(
                HookEventSanitizer.payload(from: data, provider: .codex, timestamp: 1)
            )
        }

        let permissionPlan = try payload(permissionMode: "plan", message: "ordinary")
        XCTAssertEqual(permissionPlan.eventKind, .waitingForInput)
        XCTAssertEqual(permissionPlan.waitingReason, .planConfirmation)
        let envelopePlan = try payload(
            message: "<proposed_plan>\nprivate plan\n</proposed_plan>"
        )
        XCTAssertEqual(envelopePlan.eventKind, .waitingForInput)
        XCTAssertEqual(envelopePlan.waitingReason, .planConfirmation)
        let incidental = try payload(
            message: "Mention <proposed_plan> without a protocol envelope"
        )
        XCTAssertEqual(incidental.eventKind, .turnCompleted)
        XCTAssertNil(incidental.waitingReason)
    }

    func testNotifyPayloadSanitizesPlanAndOrdinaryCompletion() throws {
        let privatePlan = "<proposed_plan>\nsecret implementation text\n</proposed_plan>"
        let planArgument = try String(decoding: JSONSerialization.data(withJSONObject: [
            "type": "agent-turn-complete",
            "thread-id": "thread-1",
            "turn-id": "turn-1",
            "input-messages": ["private prompt"],
            "last-assistant-message": privatePlan,
        ]), as: UTF8.self)
        let plan = try XCTUnwrap(
            CodexNotifyEventSanitizer.payload(from: planArgument, timestamp: 7)
        )
        XCTAssertEqual(plan.eventKind, .waitingForInput)
        XCTAssertEqual(plan.waitingReason, .planConfirmation)
        XCTAssertNil(plan.backgroundWork)
        XCTAssertNil(plan.backgroundWorkCount)
        XCTAssertEqual(plan.sessionID, "thread-1")
        XCTAssertEqual(plan.turnID, "turn-1")
        let encoded = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret implementation text"))
        XCTAssertFalse(encoded.contains("private prompt"))
        XCTAssertFalse(encoded.contains("proposed_plan"))

        let ordinaryArgument = try String(decoding: JSONSerialization.data(withJSONObject: [
            "type": "agent-turn-complete",
            "thread-id": "thread-1",
            "turn-id": "turn-2",
            "last-assistant-message": "Done.",
        ]), as: UTF8.self)
        let ordinary = try XCTUnwrap(
            CodexNotifyEventSanitizer.payload(from: ordinaryArgument)
        )
        XCTAssertEqual(ordinary.eventKind, .turnCompleted)
        XCTAssertNil(ordinary.backgroundWork)
        XCTAssertNil(ordinary.backgroundWorkCount)

        let ordinaryObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(
                    CodexNotifyEventSanitizer.encodedPayload(from: ordinaryArgument)
                )
            ) as? [String: Any]
        )
        XCTAssertNil(ordinaryObject["backgroundWork"])
        XCTAssertNil(ordinaryObject["backgroundWorkCount"])
    }

    func testLateOrdinaryNotifyCannotEraseActiveSubagentCount() throws {
        let base: TimeInterval = 1_700_000_000
        let rawNotify = try String(decoding: JSONSerialization.data(withJSONObject: [
            "type": "agent-turn-complete",
            "thread-id": "thread-with-child",
            "turn-id": "parent-turn",
            "last-assistant-message": "Done.",
        ]), as: UTF8.self)
        let notify = try XCTUnwrap(
            CodexNotifyEventSanitizer.payload(from: rawNotify, timestamp: base + 3)
        )

        func agentEvent(
            kind: AgentEventKind,
            timestamp: TimeInterval,
            backgroundWork: Bool? = nil,
            backgroundWorkCount: Int? = nil,
            workToken: String? = nil
        ) -> AgentEvent {
            AgentEvent(
                provider: .codex,
                sessionID: "thread-with-child",
                turnID: "parent-turn",
                eventKind: kind,
                backgroundWork: backgroundWork,
                backgroundWorkCount: backgroundWorkCount,
                workToken: workToken,
                timestamp: Date(timeIntervalSince1970: timestamp)
            )
        }

        var machine = AgentStateMachine(
            maximumTurnDuration: 1_000,
            completionConfirmation: 5,
            waitingGrace: 300
        )
        machine.ingest(agentEvent(kind: .promptSubmitted, timestamp: base))
        machine.ingest(agentEvent(
            kind: .backgroundWorkChanged,
            timestamp: base + 1,
            backgroundWork: true,
            workToken: String(repeating: "a", count: 64)
        ))
        machine.ingest(agentEvent(kind: .turnCompleted, timestamp: base + 2))

        let disposition = machine.ingest(AgentEvent(
            schemaVersion: notify.schemaVersion,
            provider: .codex,
            sessionID: notify.sessionID,
            turnID: notify.turnID,
            eventKind: .turnCompleted,
            backgroundWork: notify.backgroundWork,
            backgroundWorkCount: notify.backgroundWorkCount,
            timestamp: Date(timeIntervalSince1970: notify.timestamp)
        ))

        XCTAssertEqual(disposition, .duplicate)
        let state = try XCTUnwrap(machine.allSessions(
            at: Date(timeIntervalSince1970: base + 3)
        ).first)
        XCTAssertEqual(state.phase, .working)
        XCTAssertEqual(state.backgroundWorkCount, 1)
        XCTAssertTrue(state.backgroundWork)
        XCTAssertEqual(machine.activeSessions(
            at: Date(timeIntervalSince1970: base + 10)
        ).count, 1)
    }

    func testNotifyRuntimeArgumentsPreserveRawPayloadAndForwardArgvExactly() throws {
        let raw = "{\"type\":\"agent-turn-complete\",\"opaque\":\"a b\\\\c\"}"
        let runtimeArguments = [
            "--notify-relay",
            "--app-bundle-id", HookIntegrationPaths.releaseAppBundleIdentifier,
            "--socket-path", "/tmp/private.sock",
            "--forward-count", "3",
            "/Applications/Existing Tool", "turn-ended", "--forward-count",
            raw,
        ]
        let invocation = try XCTUnwrap(
            CodexNotifyRelayInvocation.parse(runtimeArguments: runtimeArguments)
        )
        XCTAssertEqual(
            invocation.forwardedArguments,
            ["/Applications/Existing Tool", "turn-ended", "--forward-count"]
        )
        XCTAssertEqual(invocation.rawPayloadArgument, raw)
    }

    func testClaudeStopReportsOnlyAbsoluteBackgroundCountAndGuardBit() throws {
        let active = try JSONSerialization.data(withJSONObject: [
            "session_id": "session",
            "prompt_id": "prompt",
            "hook_event_name": "Stop",
            "background_tasks": [["id": "secret", "command": "private command"]],
            "session_crons": [["id": "cron-secret", "schedule": "private"]],
            "stop_hook_active": true,
        ])
        let activePayload = try XCTUnwrap(
            HookEventSanitizer.payload(from: active, provider: .claudeCode, timestamp: 9)
        )
        XCTAssertEqual(activePayload.backgroundWork, true)
        XCTAssertEqual(activePayload.backgroundWorkCount, 2)
        XCTAssertEqual(activePayload.stopHookActive, true)
        let encodedText = String(decoding: try JSONEncoder().encode(activePayload), as: UTF8.self)
        XCTAssertFalse(encodedText.contains("private command"))
        XCTAssertFalse(encodedText.contains("secret"))
        XCTAssertFalse(encodedText.contains("schedule"))

        let complete = try JSONSerialization.data(withJSONObject: [
            "session_id": "session",
            "prompt_id": "prompt",
            "hook_event_name": "Stop",
            "background_tasks": [],
            "session_crons": [],
        ])
        let completePayload = try XCTUnwrap(
            HookEventSanitizer.payload(from: complete, provider: .claudeCode)
        )
        XCTAssertEqual(completePayload.backgroundWork, false)
        XCTAssertEqual(completePayload.backgroundWorkCount, 0)
    }

    func testBackgroundEventsExposeStableHashedTokenWithoutRawID() throws {
        var tokens: [String] = []
        for (hookName, expected) in [("SubagentStart", true), ("SubagentStop", false)] {
            let data = try JSONSerialization.data(withJSONObject: [
                "session_id": "session",
                "turn_id": "turn",
                "hook_event_name": hookName,
                "agent_id": "private-agent-id",
                "agent_type": "private-agent-type",
            ])
            let payload = try XCTUnwrap(
                HookEventSanitizer.payload(from: data, provider: .codex, timestamp: 1)
            )
            XCTAssertEqual(payload.eventKind, .backgroundWorkChanged)
            XCTAssertEqual(payload.backgroundWork, expected)
            XCTAssertEqual(payload.workToken?.count, 64)
            tokens.append(try XCTUnwrap(payload.workToken))
            let encoded = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
            XCTAssertFalse(encoded.contains("private-agent-id"))
            XCTAssertFalse(encoded.contains("private-agent-type"))
        }
        XCTAssertEqual(tokens[0], tokens[1])

        let other = try JSONSerialization.data(withJSONObject: [
            "session_id": "session",
            "turn_id": "turn",
            "hook_event_name": "SubagentStart",
            "agent_id": "different-agent-id",
        ])
        XCTAssertNotEqual(
            HookEventSanitizer.payload(from: other, provider: .codex)?.workToken,
            tokens[0]
        )
    }

    func testStopFailureMapsToNonSuccessfulTerminalEvent() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "session_id": "session",
            "prompt_id": "prompt",
            "hook_event_name": "StopFailure",
            "stop_hook_active": true,
            "error": "private API error",
        ])
        let payload = try XCTUnwrap(
            HookEventSanitizer.payload(from: data, provider: .claudeCode, timestamp: 1)
        )
        XCTAssertEqual(payload.eventKind, .turnFailed)
        XCTAssertEqual(payload.stopHookActive, true)
        XCTAssertNil(payload.backgroundWorkCount)
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
                .contains("private API error")
        )
    }

    func testClaudeNotificationOnlyMapsWaitingKinds() throws {
        for (notificationType, reason) in [
            ("permission_prompt", HookWaitingReason.permission),
            ("elicitation_dialog", .userInput),
            ("elicitation_url_dialog", .userInput),
            ("agent_needs_input", .userInput),
        ] {
            let waiting = try JSONSerialization.data(withJSONObject: [
                "session_id": "session",
                "prompt_id": "prompt",
                "hook_event_name": "Notification",
                "notification_type": notificationType,
                "message": "private notification text",
            ])
            XCTAssertEqual(
                HookEventSanitizer.payload(from: waiting, provider: .claudeCode)?.eventKind,
                .waitingForInput
            )
            XCTAssertEqual(
                HookEventSanitizer.payload(from: waiting, provider: .claudeCode)?.waitingReason,
                reason
            )
        }
        // `idle_prompt` arrives after the turn already finished; it must not
        // re-open it as a wait.
        let idle = try JSONSerialization.data(withJSONObject: [
            "session_id": "session",
            "hook_event_name": "Notification",
            "notification_type": "idle_prompt",
        ])
        XCTAssertNil(HookEventSanitizer.payload(from: idle, provider: .claudeCode))

        let irrelevant = try JSONSerialization.data(withJSONObject: [
            "session_id": "session",
            "hook_event_name": "Notification",
            "notification_type": "auth_success",
        ])
        XCTAssertNil(HookEventSanitizer.payload(from: irrelevant, provider: .claudeCode))
    }

    func testSanitizerRejectsMalformedOversizedAndUnknownEvents() throws {
        XCTAssertNil(HookEventSanitizer.payload(from: Data("{".utf8), provider: .codex))
        XCTAssertNil(HookEventSanitizer.payload(
            from: Data(repeating: 0x20, count: HookEventSanitizer.maximumInputBytes + 1),
            provider: .codex
        ))
        let unknown = try JSONSerialization.data(withJSONObject: [
            "session_id": "session",
            "hook_event_name": "FuturePrivateEvent",
        ])
        XCTAssertNil(HookEventSanitizer.payload(from: unknown, provider: .codex))
    }

    func testLargeOfficialPromptIsSanitizedInsteadOfDroppingLifecycleEvent() throws {
        let privatePrompt = String(repeating: "p", count: 128 * 1024)
        let input = try JSONSerialization.data(withJSONObject: [
            "session_id": "large-session",
            "turn_id": "large-turn",
            "hook_event_name": "UserPromptSubmit",
            "prompt": privatePrompt,
        ])

        let encoded = try XCTUnwrap(
            HookEventSanitizer.encodedPayload(from: input, provider: .codex, timestamp: 5)
        )
        XCTAssertLessThan(encoded.count, 1_024)
        XCTAssertFalse(
            String(decoding: encoded, as: UTF8.self)
                .contains(String(privatePrompt.prefix(64)))
        )
    }

    func testInstallPreservesUnknownJSONAndExistingHooks() throws {
        let original = try JSONSerialization.data(withJSONObject: [
            "customTopLevel": ["future": true],
            "hooks": [
                "PostToolUse": [[
                    "matcher": "Bash",
                    "customGroup": 42,
                    "hooks": [[
                        "type": "command",
                        "command": "/usr/local/bin/existing-hook",
                        "futureHandlerField": "keep-me",
                    ]],
                ]],
            ],
        ])
        let edit = try HookConfigurationEditor.installing(in: original, provider: .codex)
        XCTAssertTrue(edit.changed)
        let root = try jsonObject(edit.data)
        XCTAssertNotNil(root["customTopLevel"])

        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        for event in HookProvider.codex.installedEvents {
            XCTAssertNotNil(hooks[event], "missing \(event)")
        }
        let postGroups = try XCTUnwrap(hooks["PostToolUse"] as? [[String: Any]])
        let existingGroup = try XCTUnwrap(postGroups.first)
        XCTAssertEqual(existingGroup["customGroup"] as? Int, 42)
        let existingHandlers = try XCTUnwrap(existingGroup["hooks"] as? [[String: Any]])
        XCTAssertEqual(existingHandlers.first?["futureHandlerField"] as? String, "keep-me")
    }

    func testInstallIsByteStableWhenAlreadyInstalled() throws {
        let first = try HookConfigurationEditor.installing(in: nil, provider: .claudeCode)
        let second = try HookConfigurationEditor.installing(in: first.data, provider: .claudeCode)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.data, first.data)
        XCTAssertEqual(
            HookConfigurationEditor.health(of: second.data, provider: .claudeCode),
            .installed
        )
    }

    func testWrongNotificationMatcherIsDetectedAndRepaired() throws {
        let installed = try HookConfigurationEditor.installing(
            in: nil,
            provider: .claudeCode
        )
        var root = try jsonObject(installed.data)
        var hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        var groups = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])
        groups[0]["matcher"] = "auth_success"
        hooks["Notification"] = groups
        root["hooks"] = hooks
        let wrong = try JSONSerialization.data(withJSONObject: root)

        XCTAssertEqual(
            HookConfigurationEditor.health(of: wrong, provider: .claudeCode),
            .needsRepair
        )
        let repaired = try HookConfigurationEditor.installing(
            in: wrong,
            provider: .claudeCode
        )
        XCTAssertTrue(repaired.changed)
        XCTAssertEqual(
            HookConfigurationEditor.health(of: repaired.data, provider: .claudeCode),
            .installed
        )
    }

    func testCriticalBoundariesAreOrderedButPostToolHooksStayAsync() throws {
        for provider in [HookProvider.codex, .claudeCode] {
            let edit = try HookConfigurationEditor.installing(in: nil, provider: provider)
            let root = try jsonObject(edit.data)
            let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])

            var ordered = [
                "SessionStart",
                "UserPromptSubmit",
                "PreToolUse",
                "PermissionRequest",
                "Stop",
                "SubagentStart",
                "SubagentStop",
                "SessionEnd",
            ]
            if provider == .claudeCode {
                ordered.append(contentsOf: ["Notification", "StopFailure"])
            }
            for event in ordered {
                let groups = try XCTUnwrap(hooks[event] as? [[String: Any]])
                let handlers = try XCTUnwrap(groups.first?["hooks"] as? [[String: Any]])
                XCTAssertNil(handlers.first?["async"], "\(provider) \(event) must be ordered")
            }

            let postEvents = provider == .claudeCode
                ? ["PostToolUse", "PostToolUseFailure"]
                : ["PostToolUse"]
            for event in postEvents {
                let groups = try XCTUnwrap(hooks[event] as? [[String: Any]])
                let handlers = try XCTUnwrap(groups.first?["hooks"] as? [[String: Any]])
                XCTAssertEqual(handlers.first?["async"] as? Bool, true)
            }
        }
    }

    func testWaitingAndBackgroundBoundariesAreOrderedForBothProviders() throws {
        for provider in [HookProvider.codex, .claudeCode] {
            let edit = try HookConfigurationEditor.installing(in: nil, provider: provider)
            let root = try jsonObject(edit.data)
            let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
            let ordered = ["PreToolUse", "PermissionRequest", "SubagentStart", "SubagentStop"]
                + (provider == .claudeCode ? ["Notification"] : [])
            for event in ordered {
                let groups = try XCTUnwrap(hooks[event] as? [[String: Any]])
                let handlers = try XCTUnwrap(groups.first?["hooks"] as? [[String: Any]])
                XCTAssertNil(handlers.first?["async"], "\(provider) \(event) must be ordered")
            }
        }
    }

    func testOlderAsyncClaudeBoundaryConfigurationIsUpgraded() throws {
        let installed = try HookConfigurationEditor.installing(in: nil, provider: .claudeCode)
        var root = try jsonObject(installed.data)
        var hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        var groups = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])
        var handlers = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
        handlers[0]["async"] = true
        handlers[0]["timeout"] = 1
        groups[0]["hooks"] = handlers
        hooks["UserPromptSubmit"] = groups
        root["hooks"] = hooks
        let old = try JSONSerialization.data(withJSONObject: root)

        XCTAssertEqual(
            HookConfigurationEditor.health(of: old, provider: .claudeCode),
            .needsRepair
        )
        let upgraded = try HookConfigurationEditor.installing(
            in: old,
            provider: .claudeCode
        )
        XCTAssertTrue(upgraded.changed)
        XCTAssertEqual(
            HookConfigurationEditor.health(of: upgraded.data, provider: .claudeCode),
            .installed
        )
    }

    func testOlderAsyncCodexStopConfigurationIsUpgraded() throws {
        let installed = try HookConfigurationEditor.installing(in: nil, provider: .codex)
        var root = try jsonObject(installed.data)
        var hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        var groups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        var handlers = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
        handlers[0]["async"] = true
        groups[0]["hooks"] = handlers
        hooks["Stop"] = groups
        root["hooks"] = hooks
        let old = try JSONSerialization.data(withJSONObject: root)

        XCTAssertEqual(
            HookConfigurationEditor.health(of: old, provider: .codex),
            .needsRepair
        )
        XCTAssertEqual(
            HookConfigurationEditor.health(
                of: try HookConfigurationEditor.installing(in: old, provider: .codex).data,
                provider: .codex
            ),
            .installed
        )
    }

    func testNumericAsyncAndBooleanTimeoutAreNotAcceptedAsCanonicalTypes() throws {
        let installed = try HookConfigurationEditor.installing(in: nil, provider: .codex)
        var root = try jsonObject(installed.data)
        var hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        var groups = try XCTUnwrap(hooks["PostToolUse"] as? [[String: Any]])
        var handlers = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
        handlers[0]["async"] = 1
        handlers[0]["timeout"] = true
        groups[0]["hooks"] = handlers
        hooks["PostToolUse"] = groups
        root["hooks"] = hooks
        let malformedTypes = try JSONSerialization.data(withJSONObject: root)

        XCTAssertEqual(
            HookConfigurationEditor.health(of: malformedTypes, provider: .codex),
            .needsRepair
        )
        XCTAssertTrue(try HookConfigurationEditor.installing(
            in: malformedTypes,
            provider: .codex
        ).changed)
    }

    func testFloatingPointTimeoutIsNotAcceptedAsCanonicalInteger() throws {
        let installed = try HookConfigurationEditor.installing(in: nil, provider: .codex)
        var text = try XCTUnwrap(String(data: installed.data, encoding: .utf8))
        let integerToken = try XCTUnwrap(text.range(of: "\"timeout\" : 2"))
        text.replaceSubrange(integerToken, with: "\"timeout\" : 2.0")
        let floatingTimeout = Data(text.utf8)

        XCTAssertEqual(
            HookConfigurationEditor.health(of: floatingTimeout, provider: .codex),
            .needsRepair
        )
        XCTAssertTrue(try HookConfigurationEditor.installing(
            in: floatingTimeout,
            provider: .codex
        ).changed)
    }

    func testOwnedHandlerExecutionModifierIsDetectedAndRepaired() throws {
        let installed = try HookConfigurationEditor.installing(in: nil, provider: .claudeCode)
        var root = try jsonObject(installed.data)
        var hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        var groups = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])
        var handlers = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
        handlers[0]["if"] = "Bash(*)"
        groups[0]["hooks"] = handlers
        hooks["UserPromptSubmit"] = groups
        root["hooks"] = hooks
        let filtered = try JSONSerialization.data(withJSONObject: root)

        XCTAssertEqual(
            HookConfigurationEditor.health(of: filtered, provider: .claudeCode),
            .needsRepair
        )
        let repaired = try HookConfigurationEditor.installing(
            in: filtered,
            provider: .claudeCode
        )
        XCTAssertTrue(repaired.changed)
        XCTAssertEqual(
            HookConfigurationEditor.health(of: repaired.data, provider: .claudeCode),
            .installed
        )
    }

    func testDevelopmentBuildUsesIsolatedLaunchTargetAndSocket() throws {
        let releaseCommand = HookIntegrationPaths.bridgeCommand(provider: .codex)
        let developmentCommand = HookIntegrationPaths.bridgeCommand(
            provider: .codex,
            appBundleIdentifier: HookIntegrationPaths.developmentAppBundleIdentifier
        )
        XCTAssertNotEqual(releaseCommand, developmentCommand)
        XCTAssertTrue(releaseCommand.contains("LIDLESS_AI_APP_BUNDLE_ID=com.kenny.lidlessai "))
        XCTAssertTrue(releaseCommand.contains("/events.sock\""))
        XCTAssertTrue(developmentCommand.contains("LIDLESS_AI_APP_BUNDLE_ID=com.kenny.lidlessai.dev "))
        XCTAssertTrue(developmentCommand.contains("/events.dev.sock\""))

        let home = URL(fileURLWithPath: "/tmp/lidless-ai-home", isDirectory: true)
        XCTAssertNotEqual(
            HookIntegrationPaths.socketURL(homeDirectory: home),
            HookIntegrationPaths.socketURL(
                homeDirectory: home,
                appBundleIdentifier: HookIntegrationPaths.developmentAppBundleIdentifier
            )
        )

        let edit = try HookConfigurationEditor.installing(
            in: nil,
            provider: .codex,
            appBundleIdentifier: HookIntegrationPaths.developmentAppBundleIdentifier
        )
        XCTAssertEqual(
            HookConfigurationEditor.health(
                of: edit.data,
                provider: .codex,
                appBundleIdentifier: HookIntegrationPaths.developmentAppBundleIdentifier
            ),
            .installed
        )
        XCTAssertEqual(
            HookConfigurationEditor.health(of: edit.data, provider: .codex),
            .conflict
        )
    }

    func testInvalidAndConflictingDocumentsAreRejected() throws {
        XCTAssertThrowsError(
            try HookConfigurationEditor.installing(in: Data("not json".utf8), provider: .codex)
        ) { XCTAssertEqual($0 as? HookIntegrationError, .invalidJSON) }

        let conflictingShape = try JSONSerialization.data(withJSONObject: ["hooks": "wrong"])
        XCTAssertThrowsError(
            try HookConfigurationEditor.installing(in: conflictingShape, provider: .codex)
        )

        let conflictingCommand = try JSONSerialization.data(withJSONObject: [
            "hooks": [
                "Stop": [["hooks": [[
                    "type": "command",
                    "command": "/tmp/LidlessAIHookBridge --provider codex",
                ]]]],
            ],
        ])
        XCTAssertThrowsError(
            try HookConfigurationEditor.installing(in: conflictingCommand, provider: .codex)
        ) { XCTAssertEqual($0 as? HookIntegrationError, .conflictingBridgeCommand("Stop")) }
    }

    func testUninstallRemovesOnlyOurHandlers() throws {
        let customCommand = "/usr/local/bin/my-hook"
        let original = try JSONSerialization.data(withJSONObject: [
            "unrelated": "preserve",
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": customCommand]]]],
            ],
        ])
        let installed = try HookConfigurationEditor.installing(in: original, provider: .codex)
        let removed = try HookConfigurationEditor.uninstalling(from: installed.data, provider: .codex)
        XCTAssertTrue(removed.changed)

        let root = try jsonObject(removed.data)
        XCTAssertEqual(root["unrelated"] as? String, "preserve")
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let handlers = try XCTUnwrap(stop.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(handlers.first?["command"] as? String, customCommand)
        XCTAssertEqual(HookConfigurationEditor.health(of: removed.data, provider: .codex), .notInstalled)
    }

    func testNotifyRelayPreservesExistingCommandAndIsIdempotent() throws {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let existing = ["/Applications/Existing Tool", "turn-ended", "argument with spaces"]
        let original = Data("notify = [\"/Applications/Existing Tool\", \"turn-ended\", \"argument with spaces\"]\nmodel = \"gpt\"\n\n[plugins.demo]\nenabled = true\n".utf8)

        let installed = try CodexNotifyConfigurationEditor.installing(
            in: original,
            homeDirectory: home
        )
        XCTAssertTrue(installed.changed)
        let installedText = String(decoding: installed.data, as: UTF8.self)
        for argument in existing { XCTAssertTrue(installedText.contains(argument)) }
        XCTAssertTrue(installedText.contains("--notify-relay"))
        XCTAssertEqual(
            CodexNotifyConfigurationEditor.health(of: installed.data, homeDirectory: home),
            .installed
        )

        let second = try CodexNotifyConfigurationEditor.installing(
            in: installed.data,
            homeDirectory: home
        )
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.data, installed.data)

        let removed = try CodexNotifyConfigurationEditor.uninstalling(
            from: installed.data,
            homeDirectory: home
        )
        XCTAssertTrue(removed.changed)
        let removedText = String(decoding: removed.data, as: UTF8.self)
        for argument in existing { XCTAssertTrue(removedText.contains(argument)) }
        XCTAssertFalse(removedText.contains("LidlessAIHookBridge"))
        XCTAssertTrue(removedText.contains("[plugins.demo]"))
        XCTAssertTrue(removedText.contains("model = \"gpt\""))
    }

    func testNotifyRelayCollapsesAlternatingInstallerLayersToInnermostExternalCommand() throws {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let externalCommand = [
            "/Applications/Computer Use.app/Contents/MacOS/Computer Use",
            "turn-ended",
            "argument with spaces",
            "literal \"quote\"",
            "unicode-测试",
        ]
        var nested = externalCommand
        for _ in 0..<4 {
            nested = HookIntegrationPaths.notifyRelayArguments(
                homeDirectory: home,
                forwardedArguments: nested
            )
            nested = try previousNotifyCommand(
                baseArguments: externalCommand,
                nestedArguments: nested
            )
        }
        let original = try notifyConfigurationData(
            nested,
            suffix: "model = \"gpt\"\n"
        )

        XCTAssertEqual(
            CodexNotifyConfigurationEditor.health(of: original, homeDirectory: home),
            .needsRepair
        )
        let installed = try CodexNotifyConfigurationEditor.installing(
            in: original,
            homeDirectory: home
        )
        XCTAssertTrue(installed.changed)
        let expected = HookIntegrationPaths.notifyRelayArguments(
            homeDirectory: home,
            forwardedArguments: externalCommand
        )
        XCTAssertEqual(try notifyArguments(in: installed.data), expected)
        XCTAssertEqual(
            try notifyArguments(in: installed.data).filter {
                URL(fileURLWithPath: $0).lastPathComponent
                    == HookIntegrationPaths.bridgeExecutableName
            }.count,
            1
        )
        XCTAssertEqual(
            CodexNotifyConfigurationEditor.health(of: installed.data, homeDirectory: home),
            .installed
        )

        let second = try CodexNotifyConfigurationEditor.installing(
            in: installed.data,
            homeDirectory: home
        )
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.data, installed.data)

        let removed = try CodexNotifyConfigurationEditor.uninstalling(
            from: installed.data,
            homeDirectory: home
        )
        XCTAssertTrue(removed.changed)
        XCTAssertEqual(try notifyArguments(in: removed.data), externalCommand)
    }

    func testNotifyRelayPreservesDistinctExternalPreviousNotifyChain() throws {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let outerExternal = [
            "/Applications/Computer Use.app/Contents/MacOS/Computer Use",
            "turn-ended",
            "--mode",
            "safe value",
        ]
        let innerExternal = [
            "/Applications/Another Notifier.app/Contents/MacOS/Notifier",
            "notify",
            "inner argument with spaces",
            "inner \"quote\"",
        ]
        let ownedInner = HookIntegrationPaths.notifyRelayArguments(
            homeDirectory: home,
            forwardedArguments: innerExternal
        )
        let originalArguments = try previousNotifyCommand(
            baseArguments: outerExternal,
            nestedArguments: ownedInner
        )
        let original = try notifyConfigurationData(originalArguments)

        let installed = try CodexNotifyConfigurationEditor.installing(
            in: original,
            homeDirectory: home
        )
        let normalizedExternal = try previousNotifyCommand(
            baseArguments: outerExternal,
            nestedArguments: innerExternal
        )
        let expected = HookIntegrationPaths.notifyRelayArguments(
            homeDirectory: home,
            forwardedArguments: normalizedExternal
        )
        let installedArguments = try notifyArguments(in: installed.data)
        XCTAssertEqual(installedArguments, expected)

        let forwarded = Array(installedArguments.dropFirst(8))
        let previousIndex = try XCTUnwrap(forwarded.firstIndex(of: "--previous-notify"))
        let nestedData = try XCTUnwrap(
            forwarded[previousIndex + 1].data(using: .utf8)
        )
        XCTAssertEqual(
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: nestedData) as? [String]
            ),
            innerExternal
        )
        XCTAssertTrue(forwarded.starts(with: outerExternal.prefix(2)))

        let second = try CodexNotifyConfigurationEditor.installing(
            in: installed.data,
            homeDirectory: home
        )
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.data, installed.data)
    }

    func testNotifyRelayInstallsBeforeTablesAndSupportsMultilineExistingArray() throws {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let original = Data("# preserve\nnotify = [\n  '/existing/tool', # exact argv\n  \"turn-ended\",\n]\n\n[plugins.demo]\nenabled = true\n".utf8)
        let installed = try CodexNotifyConfigurationEditor.installing(
            in: original,
            homeDirectory: home
        )
        let text = String(decoding: installed.data, as: UTF8.self)
        XCTAssertLessThan(
            try XCTUnwrap(text.range(of: "notify =")).lowerBound,
            try XCTUnwrap(text.range(of: "[plugins.demo]")).lowerBound
        )
        XCTAssertTrue(text.contains("/existing/tool"))
        XCTAssertTrue(text.contains("turn-ended"))
        XCTAssertEqual(text.components(separatedBy: "notify =").count - 1, 1)
    }

    func testNotifyUninstallDoesNotOverwriteLaterUserEdit() throws {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let installed = try CodexNotifyConfigurationEditor.installing(
            in: Data("notify = [\"/existing\"]\n".utf8),
            homeDirectory: home
        )
        var text = String(decoding: installed.data, as: UTF8.self)
        let lineEnd = text.firstIndex(of: "\n") ?? text.endIndex
        text.replaceSubrange(text.startIndex..<lineEnd, with: "notify = [\"/user/new-command\"]")
        let userEdited = Data(text.utf8)

        let removed = try CodexNotifyConfigurationEditor.uninstalling(
            from: userEdited,
            homeDirectory: home
        )
        XCTAssertFalse(removed.changed)
        XCTAssertEqual(removed.data, userEdited)
    }

    func testInstallerBacksUpWritesActualPathAndUninstallsIdempotently() throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("lidless-hook-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let source = temporaryHome.appendingPathComponent("source-bridge")
        try Data("test executable".utf8).write(to: source)
        XCTAssertEqual(Darwin.chmod(source.path, 0o755), 0)

        let configURL = HookProvider.codex.configurationURL(homeDirectory: temporaryHome)
        try fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\"unknown\":true}\n".utf8).write(to: configURL)

        let installer = HookIntegrationInstaller(
            homeDirectory: temporaryHome,
            bridgeSourceURL: source,
            fileManager: fileManager
        )
        let installed = try installer.install(.codex)
        XCTAssertTrue(installed.configurationChanged)
        XCTAssertTrue(installed.bridgeChanged)
        XCTAssertNotNil(installed.backupURL)
        XCTAssertTrue(installed.notifyConfigurationChanged)
        XCTAssertNil(installed.notifyBackupURL)
        XCTAssertTrue(fileManager.fileExists(atPath: installed.backupURL?.path ?? ""))
        XCTAssertEqual(
            try installed.backupURL.map { try Data(contentsOf: $0) },
            Data("{\"unknown\":true}\n".utf8)
        )
        XCTAssertEqual(
            installer.bridgeURL.path,
            temporaryHome.path + "/Library/Application Support/Lidless AI/bin/LidlessAIHookBridge"
        )
        XCTAssertEqual(installer.health(for: .codex).state, .installed)
        let codexConfig = try Data(contentsOf: HookIntegrationPaths.codexConfigurationURL(
            homeDirectory: temporaryHome
        ))
        XCTAssertTrue(String(decoding: codexConfig, as: UTF8.self).contains("--notify-relay"))

        let idempotent = try installer.install(.codex)
        XCTAssertFalse(idempotent.configurationChanged)
        XCTAssertFalse(idempotent.bridgeChanged)
        XCTAssertNil(idempotent.backupURL)
        XCTAssertFalse(idempotent.notifyConfigurationChanged)
        XCTAssertNil(idempotent.notifyBackupURL)

        let removed = try installer.uninstall(.codex)
        XCTAssertTrue(removed.configurationChanged)
        XCTAssertTrue(removed.bridgeChanged)
        XCTAssertTrue(removed.notifyConfigurationChanged)
        XCTAssertEqual(installer.health(for: .codex).state, .notInstalled)
        XCTAssertFalse(fileManager.fileExists(atPath: installer.bridgeURL.path))

        let removedAgain = try installer.uninstall(.codex)
        XCTAssertFalse(removedAgain.configurationChanged)
        XCTAssertFalse(removedAgain.bridgeChanged)
        XCTAssertFalse(removedAgain.notifyConfigurationChanged)
    }

    func testComputerUseReorderedNotifyKeepsActivityChannelHealthyButNeedsRepair() throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent(
                "lidless-computer-use-notify-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let source = temporaryHome.appendingPathComponent("source-bridge")
        try Data("current bridge".utf8).write(to: source)
        XCTAssertEqual(Darwin.chmod(source.path, 0o755), 0)

        let codexConfiguration = HookIntegrationPaths.codexConfigurationURL(
            homeDirectory: temporaryHome
        )
        try fileManager.createDirectory(
            at: codexConfiguration.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let computerUse = [
            "/Applications/Computer Use.app/Contents/MacOS/Computer Use",
            "turn-ended",
        ]
        try notifyConfigurationData(computerUse).write(to: codexConfiguration)

        let installer = HookIntegrationInstaller(
            homeDirectory: temporaryHome,
            bridgeSourceURL: source,
            fileManager: fileManager
        )
        try installer.install(.codex)
        let canonicalNotify = try notifyArguments(
            in: Data(contentsOf: codexConfiguration)
        )
        let reordered = try previousNotifyCommand(
            baseArguments: computerUse,
            nestedArguments: canonicalNotify
        )
        try notifyConfigurationData(reordered).write(
            to: codexConfiguration,
            options: .atomic
        )

        let degraded = installer.codexHealth()
        XCTAssertEqual(degraded.integration.state, .needsRepair)
        XCTAssertEqual(degraded.hookConfigurationState, .installed)
        XCTAssertEqual(degraded.completionNotifyConfigurationState, .needsRepair)
        XCTAssertTrue(degraded.installedBridgeMatchesBundledSource)

        let channel = CodexLifecycleChannelHealth.evaluate(
            integration: degraded,
            eventServerAvailable: true
        )
        XCTAssertTrue(channel.activityEventsHealthy)
        XCTAssertFalse(channel.idleEvidenceHealthy)

        let repaired = try installer.install(.codex)
        XCTAssertTrue(repaired.notifyConfigurationChanged)
        XCTAssertNotNil(repaired.notifyBackupURL)
        let repairedArguments = try notifyArguments(
            in: Data(contentsOf: codexConfiguration)
        )
        XCTAssertEqual(Array(repairedArguments.dropFirst(8)), computerUse)
        XCTAssertEqual(installer.codexHealth().integration.state, .installed)
    }

    func testInstallerBacksUpAndRestoresExistingCodexNotifyCommand() throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("lidless-notify-backup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let source = temporaryHome.appendingPathComponent("source-bridge")
        try Data("bridge".utf8).write(to: source)
        XCTAssertEqual(Darwin.chmod(source.path, 0o755), 0)
        let codexDirectory = temporaryHome.appendingPathComponent(".codex", isDirectory: true)
        try fileManager.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let configURL = HookIntegrationPaths.codexConfigurationURL(homeDirectory: temporaryHome)
        let originalConfig = Data("notify = [\"/existing/client\", \"turn-ended\"]\nmodel = \"gpt\"\n".utf8)
        try originalConfig.write(to: configURL)

        let installer = HookIntegrationInstaller(
            homeDirectory: temporaryHome,
            bridgeSourceURL: source,
            fileManager: fileManager
        )
        let installed = try installer.install(.codex)
        XCTAssertTrue(installed.notifyConfigurationChanged)
        let notifyBackup = try XCTUnwrap(installed.notifyBackupURL)
        XCTAssertEqual(try Data(contentsOf: notifyBackup), originalConfig)
        let installedText = String(decoding: try Data(contentsOf: configURL), as: UTF8.self)
        XCTAssertTrue(installedText.contains("/existing/client"))
        XCTAssertTrue(installedText.contains("--notify-relay"))

        let removed = try installer.uninstall(.codex)
        XCTAssertTrue(removed.notifyConfigurationChanged)
        let restoredText = String(decoding: try Data(contentsOf: configURL), as: UTF8.self)
        XCTAssertTrue(restoredText.contains("/existing/client"))
        XCTAssertTrue(restoredText.contains("turn-ended"))
        XCTAssertFalse(restoredText.contains("LidlessAIHookBridge"))
        XCTAssertTrue(restoredText.contains("model = \"gpt\""))
    }

    func testInvalidJSONCausesNoFileSystemWrites() throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("lidless-hook-conflict-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let source = temporaryHome.appendingPathComponent("source-bridge")
        try Data("test executable".utf8).write(to: source)
        XCTAssertEqual(Darwin.chmod(source.path, 0o755), 0)
        let configURL = HookProvider.codex.configurationURL(homeDirectory: temporaryHome)
        try fileManager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = Data("{ invalid".utf8)
        try invalid.write(to: configURL)

        let installer = HookIntegrationInstaller(
            homeDirectory: temporaryHome,
            bridgeSourceURL: source,
            fileManager: fileManager
        )
        XCTAssertThrowsError(try installer.install(.codex))
        XCTAssertEqual(try Data(contentsOf: configURL), invalid)
        XCTAssertFalse(fileManager.fileExists(atPath: installer.bridgeURL.path))
        let directoryItems = try fileManager.contentsOfDirectory(atPath: configURL.deletingLastPathComponent().path)
        XCTAssertEqual(directoryItems, ["hooks.json"])
    }

    func testUninstallKeepsBridgeWhenOtherProviderConfigurationIsInvalid() throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("lidless-hook-uninstall-safety-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let source = temporaryHome.appendingPathComponent("source-bridge")
        try Data("test executable".utf8).write(to: source)
        XCTAssertEqual(Darwin.chmod(source.path, 0o755), 0)
        let installer = HookIntegrationInstaller(
            homeDirectory: temporaryHome,
            bridgeSourceURL: source,
            fileManager: fileManager
        )
        try installer.install(.codex)

        let claudeConfiguration = HookProvider.claudeCode.configurationURL(homeDirectory: temporaryHome)
        try fileManager.createDirectory(
            at: claudeConfiguration.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ invalid".utf8).write(to: claudeConfiguration)

        let removed = try installer.uninstall(.codex)
        XCTAssertTrue(removed.configurationChanged)
        XCTAssertFalse(removed.bridgeChanged)
        XCTAssertTrue(fileManager.fileExists(atPath: installer.bridgeURL.path))
        XCTAssertEqual(installer.health(for: .claudeCode).state, .invalidConfiguration)
    }

    func testSymlinkConfigurationIsRejectedWithoutFollowingOrWritingTarget() throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("lidless-hook-symlink-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let source = temporaryHome.appendingPathComponent("source-bridge")
        try Data("bridge".utf8).write(to: source)
        XCTAssertEqual(Darwin.chmod(source.path, 0o755), 0)
        let target = temporaryHome.appendingPathComponent("outside-target.json")
        let targetData = Data("{\"mustRemain\":true}\n".utf8)
        try targetData.write(to: target)
        let configuration = HookProvider.codex.configurationURL(homeDirectory: temporaryHome)
        try fileManager.createDirectory(
            at: configuration.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(at: configuration, withDestinationURL: target)

        let installer = HookIntegrationInstaller(
            homeDirectory: temporaryHome,
            bridgeSourceURL: source,
            fileManager: fileManager
        )
        XCTAssertEqual(installer.health(for: .codex).state, .invalidConfiguration)
        XCTAssertThrowsError(try installer.install(.codex)) {
            XCTAssertEqual($0 as? HookIntegrationError, .unsafeConfigurationFile)
        }
        XCTAssertEqual(try Data(contentsOf: target), targetData)
        XCTAssertFalse(fileManager.fileExists(atPath: installer.bridgeURL.path))
    }

    func testSymlinkCodexConfigIsRejectedWithoutReplacingNotifyTarget() throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("lidless-notify-symlink-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let source = temporaryHome.appendingPathComponent("source-bridge")
        try Data("bridge".utf8).write(to: source)
        XCTAssertEqual(Darwin.chmod(source.path, 0o755), 0)
        let target = temporaryHome.appendingPathComponent("outside-config.toml")
        let targetData = Data("notify = [\"/must/remain\"]\n".utf8)
        try targetData.write(to: target)
        let configURL = HookIntegrationPaths.codexConfigurationURL(homeDirectory: temporaryHome)
        try fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(at: configURL, withDestinationURL: target)

        let installer = HookIntegrationInstaller(
            homeDirectory: temporaryHome,
            bridgeSourceURL: source,
            fileManager: fileManager
        )
        XCTAssertEqual(installer.health(for: .codex).state, .invalidConfiguration)
        XCTAssertThrowsError(try installer.install(.codex)) {
            XCTAssertEqual($0 as? HookIntegrationError, .unsafeConfigurationFile)
        }
        XCTAssertEqual(try Data(contentsOf: target), targetData)
        XCTAssertFalse(fileManager.fileExists(atPath: installer.bridgeURL.path))
        XCTAssertFalse(fileManager.fileExists(
            atPath: HookProvider.codex.configurationURL(homeDirectory: temporaryHome).path
        ))
    }

    func testFIFOConfigurationIsRejectedWithoutBlocking() throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("lidless-hook-fifo-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let source = temporaryHome.appendingPathComponent("source-bridge")
        try Data("bridge".utf8).write(to: source)
        XCTAssertEqual(Darwin.chmod(source.path, 0o755), 0)
        let configuration = HookProvider.claudeCode.configurationURL(homeDirectory: temporaryHome)
        try fileManager.createDirectory(
            at: configuration.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(Darwin.mkfifo(configuration.path, 0o600), 0)

        let installer = HookIntegrationInstaller(
            homeDirectory: temporaryHome,
            bridgeSourceURL: source,
            fileManager: fileManager
        )
        XCTAssertEqual(installer.health(for: .claudeCode).state, .invalidConfiguration)
        XCTAssertThrowsError(try installer.install(.claudeCode)) {
            XCTAssertEqual($0 as? HookIntegrationError, .unsafeConfigurationFile)
        }
        XCTAssertFalse(fileManager.fileExists(atPath: installer.bridgeURL.path))
    }

    func testOversizedConfigurationIsRejectedBeforeParsingOrWriting() throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("lidless-hook-oversized-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let source = temporaryHome.appendingPathComponent("source-bridge")
        try Data("bridge".utf8).write(to: source)
        XCTAssertEqual(Darwin.chmod(source.path, 0o755), 0)
        let configuration = HookProvider.codex.configurationURL(homeDirectory: temporaryHome)
        try fileManager.createDirectory(
            at: configuration.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let oversized = Data(
            repeating: 0x20,
            count: HookIntegrationInstaller.maximumConfigurationFileBytes + 1
        )
        try oversized.write(to: configuration)

        let installer = HookIntegrationInstaller(
            homeDirectory: temporaryHome,
            bridgeSourceURL: source,
            fileManager: fileManager
        )
        XCTAssertEqual(installer.health(for: .codex).state, .invalidConfiguration)
        XCTAssertThrowsError(try installer.install(.codex)) {
            XCTAssertEqual($0 as? HookIntegrationError, .configurationTooLarge)
        }
        XCTAssertEqual(try Data(contentsOf: configuration).count, oversized.count)
        XCTAssertFalse(fileManager.fileExists(atPath: installer.bridgeURL.path))
        XCTAssertEqual(
            try fileManager.contentsOfDirectory(
                atPath: configuration.deletingLastPathComponent().path
            ),
            ["hooks.json"]
        )
    }

    func testHealthMarksOutdatedInstalledBridgeAsNeedsRepair() throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("lidless-hook-old-bridge-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let source = temporaryHome.appendingPathComponent("source-bridge")
        let currentBridge = Data("current bridge".utf8)
        try currentBridge.write(to: source)
        XCTAssertEqual(Darwin.chmod(source.path, 0o755), 0)
        let installer = HookIntegrationInstaller(
            homeDirectory: temporaryHome,
            bridgeSourceURL: source,
            fileManager: fileManager
        )
        try installer.install(.codex)
        try Data("outdated bridge".utf8).write(to: installer.bridgeURL)
        XCTAssertEqual(Darwin.chmod(installer.bridgeURL.path, 0o755), 0)

        XCTAssertEqual(installer.health(for: .codex).state, .needsRepair)
        let repaired = try installer.install(.codex)
        XCTAssertFalse(repaired.configurationChanged)
        XCTAssertTrue(repaired.bridgeChanged)
        XCTAssertEqual(try Data(contentsOf: installer.bridgeURL), currentBridge)
        XCTAssertEqual(installer.health(for: .codex).state, .installed)
    }

    func testInstallRefusesConcurrentConfigurationReplacementAtCommit() throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("lidless-hook-install-cas-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let source = temporaryHome.appendingPathComponent("source-bridge")
        try Data("bridge".utf8).write(to: source)
        XCTAssertEqual(Darwin.chmod(source.path, 0o755), 0)
        let configuration = HookProvider.codex.configurationURL(homeDirectory: temporaryHome)
        try fileManager.createDirectory(
            at: configuration.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\"before\":true}\n".utf8).write(to: configuration)
        let concurrent = Data("{\"writtenByCodex\":true,\"padding\":12345}\n".utf8)
        var injected = false
        let installer = HookIntegrationInstaller(
            homeDirectory: temporaryHome,
            bridgeSourceURL: source,
            fileManager: fileManager,
            beforeConfigurationCommit: {
                guard !injected else { return }
                injected = true
                try? concurrent.write(to: configuration, options: .atomic)
            }
        )

        XCTAssertThrowsError(try installer.install(.codex)) {
            XCTAssertEqual($0 as? HookIntegrationError, .configurationChangedDuringRead)
        }
        XCTAssertEqual(try Data(contentsOf: configuration), concurrent)
    }

    func testUninstallRefusesConcurrentConfigurationReplacementAtCommit() throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("lidless-hook-uninstall-cas-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let source = temporaryHome.appendingPathComponent("source-bridge")
        try Data("bridge".utf8).write(to: source)
        XCTAssertEqual(Darwin.chmod(source.path, 0o755), 0)
        let bootstrap = HookIntegrationInstaller(
            homeDirectory: temporaryHome,
            bridgeSourceURL: source,
            fileManager: fileManager
        )
        try bootstrap.install(.codex)
        let configuration = HookProvider.codex.configurationURL(homeDirectory: temporaryHome)
        let concurrent = Data("{\"writtenByCodex\":true,\"padding\":12345}\n".utf8)
        var injected = false
        let installer = HookIntegrationInstaller(
            homeDirectory: temporaryHome,
            bridgeSourceURL: source,
            fileManager: fileManager,
            beforeConfigurationCommit: {
                guard !injected else { return }
                injected = true
                try? concurrent.write(to: configuration, options: .atomic)
            }
        )

        XCTAssertThrowsError(try installer.uninstall(.codex)) {
            XCTAssertEqual($0 as? HookIntegrationError, .configurationChangedDuringRead)
        }
        XCTAssertEqual(try Data(contentsOf: configuration), concurrent)
    }

    func testAntigravityHooksConfigurationInstallsRepairsConflictsAndUninstallsPreservingForeignHooks() throws {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let foreign = try JSONSerialization.data(withJSONObject: [
            "my-logger": [
                "SessionStart": [[
                    "type": "command",
                    "command": "/usr/local/bin/my-hook",
                ]],
            ],
        ])

        let installed = try HookConfigurationEditor.installing(
            in: foreign,
            provider: .antigravity,
            homeDirectory: home
        )
        XCTAssertTrue(installed.changed)
        XCTAssertEqual(
            HookConfigurationEditor.health(
                of: installed.data,
                provider: .antigravity,
                homeDirectory: home
            ),
            .installed
        )
        let root = try jsonObject(installed.data)
        XCTAssertNotNil(root["my-logger"])
        let codewake = try XCTUnwrap(root["codewake"] as? [String: Any])
        for event in ["SessionStart", "PreInvocation", "PostInvocation", "Stop"] {
            let handlers = try XCTUnwrap(codewake[event] as? [[String: Any]])
            XCTAssertEqual(handlers.count, 1)
            XCTAssertNil(handlers[0]["matcher"])
        }
        let postToolGroups = try XCTUnwrap(codewake["PostToolUse"] as? [[String: Any]])
        XCTAssertEqual(postToolGroups.first?["matcher"] as? String, "*")
        let postToolHandlers = try XCTUnwrap(postToolGroups.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(postToolHandlers.count, 1)
        // `PreToolUse` is a permission gate in Antigravity; an observer must
        // never register for it (its `{}` output hard-denies every tool).
        XCTAssertNil(codewake["PreToolUse"])

        let second = try HookConfigurationEditor.installing(
            in: installed.data,
            provider: .antigravity,
            homeDirectory: home
        )
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.data, installed.data)

        // Missing Stop inside `codewake` is detected as needsRepair and repaired cleanly.
        var brokenRoot = root
        var brokenEntry = codewake
        brokenEntry.removeValue(forKey: "Stop")
        brokenRoot["codewake"] = brokenEntry
        let brokenData = try JSONSerialization.data(withJSONObject: brokenRoot)
        XCTAssertEqual(
            HookConfigurationEditor.health(
                of: brokenData,
                provider: .antigravity,
                homeDirectory: home
            ),
            .needsRepair
        )
        let repaired = try HookConfigurationEditor.installing(
            in: brokenData,
            provider: .antigravity,
            homeDirectory: home
        )
        XCTAssertTrue(repaired.changed)
        XCTAssertEqual(
            HookConfigurationEditor.health(
                of: repaired.data,
                provider: .antigravity,
                homeDirectory: home
            ),
            .installed
        )

        // A conflicting LidlessAIHookBridge command under another hook key is rejected.
        let conflicting = try JSONSerialization.data(withJSONObject: [
            "other-entry": [
                "Stop": [[
                    "type": "command",
                    "command": "/tmp/LidlessAIHookBridge --provider antigravity --custom",
                ]],
            ],
        ])
        XCTAssertEqual(
            HookConfigurationEditor.health(
                of: conflicting,
                provider: .antigravity,
                homeDirectory: home
            ),
            .conflict
        )
        XCTAssertThrowsError(
            try HookConfigurationEditor.installing(
                in: conflicting,
                provider: .antigravity,
                homeDirectory: home
            )
        )

        let uninstalled = try HookConfigurationEditor.uninstalling(
            from: repaired.data,
            provider: .antigravity,
            homeDirectory: home
        )
        XCTAssertTrue(uninstalled.changed)
        let uninstalledRoot = try jsonObject(uninstalled.data)
        XCTAssertNil(uninstalledRoot["codewake"])
        XCTAssertNotNil(uninstalledRoot["my-logger"])
    }

    func testLegacyAntigravityPreToolUseEntryNeedsRepairAndRepairRemovesTheGate() throws {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let command = HookIntegrationPaths.bridgeCommand(provider: .antigravity)
        let handler: [String: Any] = ["type": "command", "command": command, "timeout": 2]
        let grouped: [[String: Any]] = [["matcher": "*", "hooks": [handler]]]
        // Exact shape written by builds up to 0.2.19.
        let legacy = try JSONSerialization.data(withJSONObject: [
            "codewake": [
                "SessionStart": [handler],
                "PreInvocation": [handler],
                "PostInvocation": [handler],
                "PreToolUse": grouped,
                "PostToolUse": grouped,
                "Stop": [handler],
            ],
            "my-gate": [
                "PreToolUse": [["matcher": "run_command", "hooks": [[
                    "type": "command", "command": "/usr/local/bin/my-gate",
                ]]]],
            ],
        ])
        XCTAssertEqual(
            HookConfigurationEditor.health(of: legacy, provider: .antigravity, homeDirectory: home),
            .needsRepair
        )
        let repaired = try HookConfigurationEditor.installing(
            in: legacy,
            provider: .antigravity,
            homeDirectory: home
        )
        XCTAssertTrue(repaired.changed)
        XCTAssertEqual(
            HookConfigurationEditor.health(of: repaired.data, provider: .antigravity, homeDirectory: home),
            .installed
        )
        let root = try jsonObject(repaired.data)
        let codewake = try XCTUnwrap(root["codewake"] as? [String: Any])
        XCTAssertNil(codewake["PreToolUse"])
        XCTAssertNotNil(codewake["PostToolUse"])
        // A foreign user gate is preserved untouched.
        let foreign = try XCTUnwrap(root["my-gate"] as? [String: Any])
        XCTAssertNotNil(foreign["PreToolUse"])
    }

    func testAntigravityHookResponseNeverDeniesAGateAndStaysPassiveOtherwise() throws {
        func response(_ object: [String: Any]) throws -> [String: Any] {
            let data = AntigravityHookResponse.stdout(
                forRawInput: try JSONSerialization.data(withJSONObject: object)
            )
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        // A gate must carry an explicit, non-escalating decision: `{}` is an
        // empty decision that Antigravity enforces as deny, and "allow" would
        // silently bypass the user's permission settings.
        let gate = try response([
            "conversationId": "conv-1",
            "hookEventName": "PreToolUse",
            "toolCall": ["name": "run_command", "args": ["CommandLine": "ls"]],
        ])
        XCTAssertEqual(gate["decision"] as? String, "ask")
        XCTAssertEqual(gate.count, 1)

        for event in ["SessionStart", "PreInvocation", "PostInvocation", "PostToolUse", "Stop"] {
            let passive = try response(["conversationId": "conv-1", "hookEventName": event])
            XCTAssertTrue(passive.isEmpty, event)
        }

        // Unreadable input cannot prove the event is not a gate.
        for raw in [nil, Data(), Data("not json".utf8), Data("[]".utf8), Data("{}".utf8)] {
            let data = AntigravityHookResponse.stdout(forRawInput: raw)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["decision"] as? String, "ask")
        }
    }

    func testAntigravityPayloadSanitizesLifecycleWaitingCancellationFailureAndStripsPrivateFields() throws {
        func sanitize(_ object: [String: Any]) throws -> HookBridgePayload {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try XCTUnwrap(
                HookEventSanitizer.payload(from: data, provider: .antigravity, timestamp: 42)
            )
        }

        let start = try sanitize([
            "conversationId": "conv-1",
            "executionId": "exec-1",
            "hookEventName": "PreInvocation",
            "userMessage": "secret prompt",
            "workspaceRoot": "/Users/private/repo",
        ])
        XCTAssertEqual(start.provider, "antigravity")
        XCTAssertEqual(start.sessionID, "conv-1")
        XCTAssertEqual(start.turnID, "exec-1")
        XCTAssertEqual(start.eventKind, .promptSubmitted)
        let startJSON = String(decoding: try JSONEncoder().encode(start), as: UTF8.self)
        XCTAssertFalse(startJSON.contains("secret prompt"))
        XCTAssertFalse(startJSON.contains("/Users/private/repo"))

        let askTool = try sanitize([
            "conversationId": "conv-1",
            "executionId": "exec-1",
            "hookEventName": "PreToolUse",
            "toolCall": [
                "name": "ask_question",
                "arguments": ["questions": "private"],
            ],
        ])
        XCTAssertEqual(askTool.eventKind, .waitingForInput)
        XCTAssertEqual(askTool.waitingReason, .userInput)

        let askDone = try sanitize([
            "conversationId": "conv-1",
            "executionId": "exec-1",
            "hookEventName": "PostToolUse",
            "toolCall": ["name": "ask_question"],
        ])
        XCTAssertEqual(askDone.eventKind, .inputReceived)

        let postStep = try sanitize([
            "conversationId": "conv-1",
            "executionId": "exec-1",
            "hookEventName": "PostInvocation",
        ])
        XCTAssertEqual(postStep.eventKind, .activity)

        // Subagents still running: Stop with fullyIdle=false keeps backgroundWorkCount=1.
        let stopWithSubagents = try sanitize([
            "conversationId": "conv-1",
            "executionId": "exec-1",
            "hookEventName": "Stop",
            "terminationReason": "COMPLETE",
            "fullyIdle": false,
        ])
        XCTAssertEqual(stopWithSubagents.eventKind, .turnCompleted)
        XCTAssertEqual(stopWithSubagents.backgroundWorkCount, 1)

        // Fully idle completion: backgroundWorkCount=0 allows normal sleep release.
        let stopIdle = try sanitize([
            "conversationId": "conv-1",
            "executionId": "exec-1",
            "hookEventName": "Stop",
            "terminationReason": "COMPLETE",
            "fullyIdle": true,
        ])
        XCTAssertEqual(stopIdle.eventKind, .turnCompleted)
        XCTAssertEqual(stopIdle.backgroundWorkCount, 0)

        let canceled = try sanitize([
            "conversationId": "conv-1",
            "executionId": "exec-1",
            "hookEventName": "Stop",
            "terminationReason": "USER_CANCELED",
        ])
        XCTAssertEqual(canceled.eventKind, .turnCancelled)

        let failed = try sanitize([
            "conversationId": "conv-1",
            "executionId": "exec-1",
            "hookEventName": "Stop",
            "terminationReason": "ERROR",
        ])
        XCTAssertEqual(failed.eventKind, .turnFailed)
    }

    func testPaseoConfigurationAndPluginFilesInstallRepairConflictAndUninstallPreservingUserConfig() throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("lidless-paseo-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let source = temporaryHome.appendingPathComponent("source-bridge")
        try Data("bridge".utf8).write(to: source)
        XCTAssertEqual(Darwin.chmod(source.path, 0o755), 0)

        let paseoConfig = HookProvider.paseo.configurationURL(homeDirectory: temporaryHome)
        try fileManager.createDirectory(
            at: paseoConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let initialConfig = try JSONSerialization.data(withJSONObject: [
            "listen": "127.0.0.1:6767",
            "plugins": [
                "user-plugin": [
                    "source": "directory",
                    "path": "/Users/tester/my-plugin",
                    "enabled": true,
                ],
            ],
        ])
        try initialConfig.write(to: paseoConfig)

        let installer = HookIntegrationInstaller(
            homeDirectory: temporaryHome,
            bridgeSourceURL: source,
            fileManager: fileManager
        )
        XCTAssertEqual(installer.health(for: .paseo).state, .notInstalled)

        let installed = try installer.install(.paseo)
        XCTAssertTrue(installed.configurationChanged)
        XCTAssertTrue(installed.bridgeChanged)
        XCTAssertEqual(installer.health(for: .paseo).state, .installed)

        let manifestURL = HookIntegrationPaths.paseoPluginManifestURL(homeDirectory: temporaryHome)
        let entryURL = HookIntegrationPaths.paseoPluginServerEntryURL(homeDirectory: temporaryHome)
        XCTAssertTrue(fileManager.fileExists(atPath: manifestURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: entryURL.path))
        let manifest = try jsonObject(Data(contentsOf: manifestURL))
        let requirements = try XCTUnwrap(manifest["requirements"] as? [String: Any])
        XCTAssertEqual(requirements["paseo"] as? String, ">=0.9.0")

        let root = try jsonObject(Data(contentsOf: paseoConfig))
        XCTAssertEqual(root["listen"] as? String, "127.0.0.1:6767")
        XCTAssertEqual(root["pluginsEnabled"] as? Bool, true)
        let plugins = try XCTUnwrap(root["plugins"] as? [String: Any])
        XCTAssertNotNil(plugins["user-plugin"])
        let codewakePlugin = try XCTUnwrap(plugins["codewake"] as? [String: Any])
        XCTAssertEqual(codewakePlugin["source"] as? String, "directory")
        XCTAssertEqual(
            codewakePlugin["path"] as? String,
            HookIntegrationPaths.paseoPluginDirectory(homeDirectory: temporaryHome).path
        )

        let idempotent = try installer.install(.paseo)
        XCTAssertFalse(idempotent.configurationChanged)
        XCTAssertFalse(idempotent.bridgeChanged)

        // Removing the managed plugin entry file marks Paseo as needsRepair and repairs cleanly.
        try fileManager.removeItem(at: entryURL)
        XCTAssertEqual(installer.health(for: .paseo).state, .needsRepair)
        let repaired = try installer.install(.paseo)
        XCTAssertTrue(repaired.configurationChanged)
        XCTAssertFalse(repaired.bridgeChanged)
        XCTAssertEqual(installer.health(for: .paseo).state, .installed)

        let uninstalled = try installer.uninstall(.paseo)
        XCTAssertTrue(uninstalled.configurationChanged)
        XCTAssertEqual(installer.health(for: .paseo).state, .notInstalled)
        XCTAssertFalse(
            fileManager.fileExists(
                atPath: HookIntegrationPaths.paseoPluginDirectory(homeDirectory: temporaryHome).path
            )
        )
        let afterRoot = try jsonObject(Data(contentsOf: paseoConfig))
        XCTAssertEqual(afterRoot["listen"] as? String, "127.0.0.1:6767")
        let afterPlugins = try XCTUnwrap(afterRoot["plugins"] as? [String: Any])
        XCTAssertNotNil(afterPlugins["user-plugin"])
        XCTAssertNil(afterPlugins["codewake"])
    }

    func testPaseoPayloadSanitizesTurnsPermissionsCancellationAndSessionClose() throws {
        func sanitize(_ object: [String: Any]) throws -> HookBridgePayload {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try XCTUnwrap(
                HookEventSanitizer.payload(from: data, provider: .paseo, timestamp: 99)
            )
        }

        let created = try sanitize([
            "agentId": "agent-1",
            "hookEventName": "agent.create.after",
            "cwd": "/Users/private/project",
        ])
        XCTAssertEqual(created.provider, "paseo")
        XCTAssertEqual(created.sessionID, "agent-1")
        XCTAssertEqual(created.eventKind, .sessionStarted)
        let createdJSON = String(decoding: try JSONEncoder().encode(created), as: UTF8.self)
        XCTAssertFalse(createdJSON.contains("/Users/private/project"))

        let turnStart = try sanitize([
            "agentId": "agent-1",
            "turnId": "turn-7",
            "hookEventName": "agent.turn.before",
            "prompt": "do not forward",
        ])
        XCTAssertEqual(turnStart.turnID, "turn-7")
        XCTAssertEqual(turnStart.eventKind, .promptSubmitted)

        let permissionWait = try sanitize([
            "agentId": "agent-1",
            "turnId": "turn-7",
            "hookEventName": "agent.permission.before",
        ])
        XCTAssertEqual(permissionWait.eventKind, .waitingForInput)
        XCTAssertEqual(permissionWait.waitingReason, .permission)

        let permissionDone = try sanitize([
            "agentId": "agent-1",
            "turnId": "turn-7",
            "hookEventName": "agent.permission.after",
        ])
        XCTAssertEqual(permissionDone.eventKind, .inputReceived)

        let completed = try sanitize([
            "agentId": "agent-1",
            "turnId": "turn-7",
            "hookEventName": "agent.turn.after",
            "outcome": "completed",
        ])
        XCTAssertEqual(completed.eventKind, .turnCompleted)
        XCTAssertEqual(completed.backgroundWorkCount, 0)

        let canceledWithTurn = try sanitize([
            "agentId": "agent-1",
            "turnId": "turn-7",
            "hookEventName": "agent.turn.after",
            "outcome": "canceled",
        ])
        XCTAssertEqual(canceledWithTurn.eventKind, .turnCancelled)

        // When Paseo omits turnId on cancellation, sessionEnded immediately ends active turns
        // with policy-only release and allows later turns to reopen the session cleanly.
        let canceledWithoutTurn = try sanitize([
            "agentId": "agent-1",
            "hookEventName": "agent.turn.after",
            "outcome": "canceled",
        ])
        XCTAssertEqual(canceledWithoutTurn.eventKind, .sessionEnded)

        let failed = try sanitize([
            "agentId": "agent-1",
            "turnId": "turn-7",
            "hookEventName": "agent.turn.after",
            "outcome": "failed",
        ])
        XCTAssertEqual(failed.eventKind, .turnFailed)

        let closed = try sanitize([
            "agentId": "agent-1",
            "hookEventName": "agent.close.after",
        ])
        XCTAssertEqual(closed.eventKind, .sessionEnded)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func notifyConfigurationData(
        _ arguments: [String],
        suffix: String = ""
    ) throws -> Data {
        let encoded = try JSONSerialization.data(
            withJSONObject: arguments,
            options: [.withoutEscapingSlashes]
        )
        return Data("notify = \(String(decoding: encoded, as: UTF8.self))\n\(suffix)".utf8)
    }

    private func notifyArguments(in data: Data) throws -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        let line = try XCTUnwrap(
            text.split(separator: "\n", omittingEmptySubsequences: false).first {
                $0.hasPrefix("notify = ")
            }
        )
        let value = line.dropFirst("notify = ".count)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String]
        )
    }

    private func previousNotifyCommand(
        baseArguments: [String],
        nestedArguments: [String]
    ) throws -> [String] {
        let nested = try JSONSerialization.data(
            withJSONObject: nestedArguments,
            options: [.withoutEscapingSlashes]
        )
        return baseArguments + [
            "--previous-notify",
            String(decoding: nested, as: UTF8.self),
        ]
    }
}

// MARK: - Regression tests for hook contract fixes

extension HookIntegrationTests {
    func testClaudeIdlePromptIsNotAWaitAndNotificationReasonsFollowTheirType() throws {
        func payload(_ type: String) throws -> HookBridgePayload? {
            let data = try JSONSerialization.data(withJSONObject: [
                "session_id": "s1",
                "hook_event_name": "Notification",
                "notification_type": type,
            ])
            return HookEventSanitizer.payload(from: data, provider: .claudeCode, timestamp: 1)
        }
        XCTAssertNil(try payload("idle_prompt"))
        XCTAssertEqual(try payload("permission_prompt")?.waitingReason, .permission)
        XCTAssertEqual(try payload("elicitation_dialog")?.waitingReason, .userInput)
        XCTAssertEqual(try payload("agent_needs_input")?.waitingReason, .userInput)
    }

    func testPaseoUsesPluginEmissionTimeOnlyNearTheBridgeClock() throws {
        func payload(emittedAt: Any?) throws -> HookBridgePayload {
            var object: [String: Any] = [
                "session_id": "agent-1",
                "hook_event_name": "agent.turn.before",
            ]
            object["emitted_at"] = emittedAt
            let data = try JSONSerialization.data(withJSONObject: object)
            return try XCTUnwrap(
                HookEventSanitizer.payload(from: data, provider: .paseo, timestamp: 1_000)
            )
        }
        XCTAssertEqual(try payload(emittedAt: 999.25).timestamp, 999.25)
        XCTAssertEqual(try payload(emittedAt: nil).timestamp, 1_000)
        XCTAssertEqual(try payload(emittedAt: 1_000 - 301).timestamp, 1_000)
        XCTAssertEqual(try payload(emittedAt: 1_000 + 301).timestamp, 1_000)
        XCTAssertEqual(try payload(emittedAt: "999").timestamp, 1_000)

        let script = String(decoding: HookIntegrationPaths.paseoPluginServerEntryData(
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        ), as: UTF8.self)
        XCTAssertTrue(script.contains("emitted_at: emittedAt"))
    }

    func testAntigravityEnabledFlagIsAcceptedAndADisabledCodeWakeEntryIsNotInstalled() throws {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let installed = try HookConfigurationEditor.installing(
            in: try JSONSerialization.data(withJSONObject: [
                "paused-linter": [
                    "enabled": false,
                    "PostToolUse": [["matcher": "*", "hooks": [[
                        "type": "command", "command": "/usr/local/bin/lint",
                    ]]]],
                ],
            ]),
            provider: .antigravity,
            homeDirectory: home
        )
        XCTAssertEqual(
            HookConfigurationEditor.health(of: installed.data, provider: .antigravity, homeDirectory: home),
            .installed
        )

        var root = try jsonObject(installed.data)
        var codewake = try XCTUnwrap(root["codewake"] as? [String: Any])
        codewake["enabled"] = false
        root["codewake"] = codewake
        let disabled = try JSONSerialization.data(withJSONObject: root)
        XCTAssertEqual(
            HookConfigurationEditor.health(of: disabled, provider: .antigravity, homeDirectory: home),
            .notInstalled
        )

        codewake["enabled"] = true
        root["codewake"] = codewake
        let enabled = try JSONSerialization.data(withJSONObject: root)
        XCTAssertEqual(
            HookConfigurationEditor.health(of: enabled, provider: .antigravity, homeDirectory: home),
            .installed
        )

        codewake["enabled"] = "no"
        root["codewake"] = codewake
        XCTAssertEqual(
            HookConfigurationEditor.health(
                of: try JSONSerialization.data(withJSONObject: root),
                provider: .antigravity,
                homeDirectory: home
            ),
            .conflict
        )
    }
}
