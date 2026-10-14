import XCTest

final class CodexRuntimeStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testNoCodexTaskIsIdleAndOtherProvidersAreIgnored() {
        XCTAssertEqual(CodexTaskSemanticStatus.summarize(sessions: [], at: now), .idle)
        XCTAssertEqual(
            CodexTaskSemanticStatus.summarize(
                sessions: [state(provider: .claudeCode, phase: .working)],
                at: now
            ),
            .idle
        )
    }

    func testUnknownCodexTaskRemainsDistinctFromIdle() {
        let status = CodexTaskSemanticStatus.summarize(
            sessions: [state(phase: .unknown)],
            at: now
        )

        guard case let .unknown(details) = status else {
            return XCTFail("Expected an unknown Codex task")
        }
        XCTAssertEqual(details.unknownCount, 1)
        XCTAssertEqual(details.taskCount, 1)
        XCTAssertEqual(details.activeTaskCount, 0)
        XCTAssertNil(details.waitingReason)
    }

    func testWorkingTakesPriorityWhilePreservingTaskCategoryCounts() {
        let status = CodexTaskSemanticStatus.summarize(
            sessions: [
                state(sessionID: "working", phase: .working),
                state(
                    sessionID: "waiting",
                    phase: .waitingForInput,
                    waitingReason: .permission
                ),
                state(sessionID: "finishing", phase: .pendingCompletion),
                state(sessionID: "unknown", phase: .unknown)
            ],
            at: now
        )

        guard case let .working(details) = status else {
            return XCTFail("Expected working to be the primary semantic")
        }
        XCTAssertEqual(details.workingCount, 1)
        XCTAssertEqual(details.waitingCount, 1)
        XCTAssertEqual(details.finishingCount, 1)
        XCTAssertEqual(details.unknownCount, 1)
        XCTAssertEqual(details.activeTaskCount, 3)
        XCTAssertEqual(details.taskCount, 4)
        XCTAssertEqual(details.waitingReason, .permission)
    }

    func testMultipleTurnsInOneRootTaskAreCountedOnce() {
        let status = CodexTaskSemanticStatus.summarize(
            sessions: [
                state(sessionID: "root", turnID: "root-turn", phase: .waitingForInput),
                state(sessionID: "root", turnID: "subagent", phase: .working)
            ],
            at: now
        )

        guard case let .working(details) = status else {
            return XCTFail("Expected the working turn to win within its root task")
        }
        XCTAssertEqual(details.workingCount, 1)
        XCTAssertEqual(details.waitingCount, 0)
        XCTAssertEqual(details.taskCount, 1)
        XCTAssertNil(details.waitingReason)
    }

    func testWaitingProvidesReasonAndCount() {
        let status = CodexTaskSemanticStatus.summarize(
            sessions: [
                state(
                    sessionID: "first",
                    phase: .waitingForInput,
                    waitingReason: .planConfirmation
                ),
                state(
                    sessionID: "second",
                    phase: .waitingForInput,
                    waitingReason: .planConfirmation
                )
            ],
            at: now
        )

        guard case let .waiting(details) = status else {
            return XCTFail("Expected waiting")
        }
        XCTAssertEqual(details.waitingCount, 2)
        XCTAssertEqual(details.taskCount, 2)
        XCTAssertEqual(details.waitingReason, .planConfirmation)
    }

    func testMixedOrMissingWaitingReasonsBecomeUnknown() {
        let mixed = CodexTaskSemanticStatus.summarize(
            sessions: [
                state(
                    sessionID: "first",
                    phase: .waitingForInput,
                    waitingReason: .permission
                ),
                state(
                    sessionID: "second",
                    phase: .waitingForInput,
                    waitingReason: .userInput
                )
            ],
            at: now
        )
        let missing = CodexTaskSemanticStatus.summarize(
            sessions: [state(phase: .waitingForInput)],
            at: now
        )

        XCTAssertEqual(mixed.details.waitingReason, .unknown)
        XCTAssertEqual(missing.details.waitingReason, .unknown)
    }

    func testPendingAndStoppedTasksAreFinishing() {
        let status = CodexTaskSemanticStatus.summarize(
            sessions: [
                state(sessionID: "pending", phase: .pendingCompletion),
                state(sessionID: "stopped", phase: .turnStopped)
            ],
            at: now
        )

        guard case let .finishing(details) = status else {
            return XCTFail("Expected finishing")
        }
        XCTAssertEqual(details.finishingCount, 2)
        XCTAssertEqual(details.taskCount, 2)
    }

    func testExpiredWaitingAndFinishingTasksAreIdle() {
        let expired = now.addingTimeInterval(-1)
        let status = CodexTaskSemanticStatus.summarize(
            sessions: [
                state(
                    sessionID: "waiting",
                    phase: .waitingForInput,
                    graceDeadline: expired
                ),
                state(
                    sessionID: "finishing",
                    phase: .pendingCompletion,
                    graceDeadline: expired
                )
            ],
            at: now
        )

        XCTAssertEqual(status, .idle)
        XCTAssertEqual(status.details.taskCount, 0)
    }

    func testCodexChannelHealthSeparatesActivityFromIdleEvidence() {
        let canonical = CodexLifecycleChannelHealth.evaluate(
            integration: integrationHealth(),
            eventServerAvailable: true
        )
        XCTAssertTrue(canonical.activityEventsHealthy)
        XCTAssertTrue(canonical.idleEvidenceHealthy)

        let reorderedNotify = CodexLifecycleChannelHealth.evaluate(
            integration: integrationHealth(
                overall: .needsRepair,
                completionNotify: .needsRepair
            ),
            eventServerAvailable: true
        )
        XCTAssertTrue(reorderedNotify.activityEventsHealthy)
        XCTAssertFalse(reorderedNotify.idleEvidenceHealthy)

        for unavailable in [
            CodexLifecycleChannelHealth.evaluate(
                integration: integrationHealth(hooks: .needsRepair),
                eventServerAvailable: true
            ),
            CodexLifecycleChannelHealth.evaluate(
                integration: integrationHealth(bridgeMatches: false),
                eventServerAvailable: true
            ),
            CodexLifecycleChannelHealth.evaluate(
                integration: integrationHealth(),
                eventServerAvailable: false
            ),
        ] {
            XCTAssertFalse(unavailable.activityEventsHealthy)
            XCTAssertFalse(unavailable.idleEvidenceHealthy)
        }
    }

    func testUnhealthyLifecycleChannelDowngradesActiveStateToUnknown() {
        let statuses = [
            CodexTaskSemanticStatus.summarize(
                sessions: [state(phase: .working)],
                at: now
            ),
            CodexTaskSemanticStatus.summarize(
                sessions: [state(phase: .waitingForInput)],
                at: now
            ),
            CodexTaskSemanticStatus.summarize(
                sessions: [state(phase: .pendingCompletion)],
                at: now
            ),
        ]

        for status in statuses {
            let validated = status.validatedForPresentation(
                lifecycleChannelHealth: .unavailable,
                processScanSucceeded: true,
                allDetectedProcessesObserved: true
            )
            guard case .unknown = validated else {
                return XCTFail("An unhealthy channel must not present active state as current")
            }
            XCTAssertEqual(validated.details, status.details)
        }
    }

    func testIdleRequiresSuccessfulScanAndLifecycleProofForDetectedProcesses() {
        let idle = CodexTaskSemanticStatus.idle
        XCTAssertEqual(
            idle.validatedForPresentation(
                lifecycleChannelHealth: fullyHealthyChannel,
                processScanSucceeded: true,
                allDetectedProcessesObserved: true
            ),
            .idle
        )

        for evidence in [(false, true), (true, false)] {
            guard case .unknown = idle.validatedForPresentation(
                lifecycleChannelHealth: fullyHealthyChannel,
                processScanSucceeded: evidence.0,
                allDetectedProcessesObserved: evidence.1
            ) else {
                return XCTFail("Missing process evidence must keep an empty state unknown")
            }
        }

        guard case .unknown = idle.validatedForPresentation(
            lifecycleChannelHealth: activityOnlyChannel,
            processScanSucceeded: true,
            allDetectedProcessesObserved: true
        ) else {
            return XCTFail("A non-canonical completion relay cannot prove idle")
        }
    }

    func testPositiveLifecycleStateSurvivesScanFailureAndNotifyReorder() {
        let working = CodexTaskSemanticStatus.summarize(
            sessions: [state(phase: .working)],
            at: now
        )
        XCTAssertEqual(
            working.validatedForPresentation(
                lifecycleChannelHealth: activityOnlyChannel,
                processScanSucceeded: false,
                allDetectedProcessesObserved: false
            ),
            working
        )
    }

    func testMenuBarIconRequiresKeepAwakeAndVerifiedCodexWork() {
        let working = CodexTaskSemanticStatus.summarize(
            sessions: [state(phase: .working)],
            at: now
        )
        let unknown = working.validatedForPresentation(
            lifecycleChannelHealth: .unavailable,
            processScanSucceeded: true,
            allDetectedProcessesObserved: true
        )

        XCTAssertEqual(
            MenuBarIconPresentation.resolve(
                isKeepAwakeActive: false,
                isManualKeepAwakeActive: true,
                codexStatus: working
            ),
            .normal
        )
        XCTAssertEqual(
            MenuBarIconPresentation.resolve(
                isKeepAwakeActive: true,
                isManualKeepAwakeActive: false,
                codexStatus: nil
            ),
            .normal
        )
        XCTAssertEqual(
            MenuBarIconPresentation.resolve(
                isKeepAwakeActive: true,
                isManualKeepAwakeActive: false,
                codexStatus: .idle
            ),
            .normal
        )
        XCTAssertEqual(
            MenuBarIconPresentation.resolve(
                isKeepAwakeActive: true,
                isManualKeepAwakeActive: false,
                codexStatus: unknown
            ),
            .normal,
            "An unhealthy lifecycle channel must not color the icon from retained counts."
        )
    }

    func testMenuBarIconIsGreenForWorkingCodexOnly() {
        let working = CodexTaskSemanticStatus.summarize(
            sessions: [state(phase: .working)],
            at: now
        )
        let claudeOnly = CodexTaskSemanticStatus.summarize(
            sessions: [state(provider: .claudeCode, phase: .working)],
            at: now
        )

        XCTAssertEqual(
            MenuBarIconPresentation.resolve(
                isKeepAwakeActive: true,
                isManualKeepAwakeActive: false,
                codexStatus: working
            ),
            .working
        )
        XCTAssertEqual(
            MenuBarIconPresentation.resolve(
                isKeepAwakeActive: true,
                isManualKeepAwakeActive: false,
                codexStatus: claudeOnly
            ),
            .normal
        )
    }

    func testMenuBarIconIsGreenForActiveManualHoldWithoutTrustedCodexWork() {
        let unknown = CodexTaskSemanticStatus.summarize(
            sessions: [state(phase: .unknown)],
            at: now
        )
        let statuses: [CodexTaskSemanticStatus?] = [nil, .idle, unknown]

        for status in statuses {
            XCTAssertEqual(
                MenuBarIconPresentation.resolve(
                    isKeepAwakeActive: true,
                    isManualKeepAwakeActive: true,
                    codexStatus: status
                ),
                .manualActive
            )
        }
    }

    func testCodexColorTakesPriorityOverManualGreen() {
        let working = CodexTaskSemanticStatus.summarize(
            sessions: [state(phase: .working)],
            at: now
        )
        let waiting = CodexTaskSemanticStatus.summarize(
            sessions: [state(phase: .waitingForInput)],
            at: now
        )

        XCTAssertEqual(
            MenuBarIconPresentation.resolve(
                isKeepAwakeActive: true,
                isManualKeepAwakeActive: true,
                codexStatus: working
            ),
            .working
        )
        XCTAssertEqual(
            MenuBarIconPresentation.resolve(
                isKeepAwakeActive: true,
                isManualKeepAwakeActive: true,
                codexStatus: waiting
            ),
            .attention
        )
    }

    func testEndingManualHoldReturnsToNormalWithoutCodexActivity() {
        XCTAssertEqual(
            MenuBarIconPresentation.resolve(
                isKeepAwakeActive: true,
                isManualKeepAwakeActive: false,
                codexStatus: .idle
            ),
            .normal
        )
    }

    func testMenuBarIconStaysNormalWhenWorkingAndUnknownCodexTasksAreMixed() {
        let mixed = CodexTaskSemanticStatus.summarize(
            sessions: [
                state(sessionID: "working", phase: .working),
                state(sessionID: "unknown", phase: .unknown)
            ],
            at: now
        )

        XCTAssertEqual(
            MenuBarIconPresentation.resolve(
                isKeepAwakeActive: true,
                isManualKeepAwakeActive: false,
                codexStatus: mixed
            ),
            .normal
        )
        XCTAssertEqual(
            MenuBarIconPresentation.resolve(
                isKeepAwakeActive: true,
                isManualKeepAwakeActive: true,
                codexStatus: mixed
            ),
            .manualActive,
            "Unknown Codex work must not suppress an independently active manual hold."
        )
    }

    func testMenuBarIconIsRedForWaitingOrFinishingCodex() {
        for phase in [AgentSessionPhase.waitingForInput, .pendingCompletion, .turnStopped] {
            let status = CodexTaskSemanticStatus.summarize(
                sessions: [state(phase: phase)],
                at: now
            )
            XCTAssertEqual(
                MenuBarIconPresentation.resolve(
                    isKeepAwakeActive: true,
                    isManualKeepAwakeActive: false,
                    codexStatus: status
                ),
                .attention
            )
        }
    }

    func testMenuBarIconGivesAttentionPriorityAcrossCodexTasks() {
        let mixed = CodexTaskSemanticStatus.summarize(
            sessions: [
                state(sessionID: "working", phase: .working),
                state(sessionID: "waiting", phase: .waitingForInput),
                state(sessionID: "finishing", phase: .pendingCompletion)
            ],
            at: now
        )

        XCTAssertEqual(
            MenuBarIconPresentation.resolve(
                isKeepAwakeActive: true,
                isManualKeepAwakeActive: false,
                codexStatus: mixed
            ),
            .attention
        )
    }

    func testMenuBarIconReturnsToNormalAfterWaitingAndFinishingExpire() {
        let expired = now.addingTimeInterval(-1)
        let status = CodexTaskSemanticStatus.summarize(
            sessions: [
                state(phase: .waitingForInput, graceDeadline: expired),
                state(
                    sessionID: "finishing",
                    phase: .pendingCompletion,
                    graceDeadline: expired
                )
            ],
            at: now
        )

        XCTAssertEqual(
            MenuBarIconPresentation.resolve(
                isKeepAwakeActive: true,
                isManualKeepAwakeActive: false,
                codexStatus: status
            ),
            .normal
        )
    }

    func testAgentStatusColorRoleUsesOnlyVerifiedCodexSemantics() {
        XCTAssertEqual(AgentStatusColorRole.resolve(for: .normal), .neutral)
        XCTAssertEqual(AgentStatusColorRole.resolve(for: .manualActive), .neutral)
        XCTAssertEqual(AgentStatusColorRole.resolve(for: .working), .working)
        XCTAssertEqual(AgentStatusColorRole.resolve(for: .attention), .attention)
    }

    private var fullyHealthyChannel: CodexLifecycleChannelHealth {
        CodexLifecycleChannelHealth(
            activityEventsHealthy: true,
            idleEvidenceHealthy: true
        )
    }

    private var activityOnlyChannel: CodexLifecycleChannelHealth {
        CodexLifecycleChannelHealth(
            activityEventsHealthy: true,
            idleEvidenceHealthy: false
        )
    }

    private func integrationHealth(
        overall: HookIntegrationHealthState = .installed,
        hooks: HookIntegrationHealthState = .installed,
        completionNotify: HookIntegrationHealthState = .installed,
        bridgeMatches: Bool = true
    ) -> CodexIntegrationHealth {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        return CodexIntegrationHealth(
            integration: HookIntegrationHealth(
                provider: .codex,
                state: overall,
                configurationURL: HookProvider.codex.configurationURL(
                    homeDirectory: home
                ),
                bridgeURL: HookIntegrationPaths.bridgeURL(homeDirectory: home)
            ),
            hookConfigurationState: hooks,
            completionNotifyConfigurationState: completionNotify,
            installedBridgeMatchesBundledSource: bridgeMatches
        )
    }

    private func state(
        provider: AgentProvider = .codex,
        sessionID: String = "session",
        turnID: String = "turn",
        phase: AgentSessionPhase,
        waitingReason: AgentWaitingReason? = nil,
        graceDeadline: Date? = nil
    ) -> AgentSessionState {
        AgentSessionState(
            key: AgentSessionKey(provider: provider, sessionID: sessionID),
            phase: phase,
            turnID: turnID,
            turnStartedAt: now.addingTimeInterval(-10),
            hardDeadline: now.addingTimeInterval(1_000),
            lastActivityAt: now.addingTimeInterval(-1),
            lastEventAt: now.addingTimeInterval(-1),
            graceDeadline: graceDeadline,
            backgroundWork: false,
            backgroundWorkCount: 0,
            turnStopObserved: phase == .turnStopped,
            waitingObserved: phase == .waitingForInput,
            waitingReason: waitingReason,
            lastBackgroundSignalAt: nil,
            lastBackgroundSignalValue: nil
        )
    }
}
