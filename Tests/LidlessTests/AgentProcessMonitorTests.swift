import XCTest

final class AgentProcessMonitorTests: XCTestCase {
    func testProviderDetectionUsesExecutableIdentityOnly() {
        XCTAssertEqual(AgentProcessProvider.detect(executableName: "codex"), .codex)
        XCTAssertEqual(AgentProcessProvider.detect(executableName: "codex-cli"), .codex)
        XCTAssertEqual(
            AgentProcessProvider.detect(executableName: "codex-aarch64-apple-darwin"),
            .codex
        )
        XCTAssertEqual(AgentProcessProvider.detect(executableName: "claude"), .claude)
        XCTAssertNil(AgentProcessProvider.detect(executableName: "codex-code-mode-host"))
        XCTAssertNil(AgentProcessProvider.detect(executableName: "Terminal"))
        XCTAssertNil(AgentProcessProvider.detect(executableName: "my-codex-notes"))
    }

    func testCodexDesktopAndCLIUseTheExecutablePathOnlyForSurfaceClassification() {
        XCTAssertEqual(
            AgentProcessProvider.executionSurface(
                executableName: "codex",
                executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex",
                parentExecutablePath: "/Applications/ChatGPT.app/Contents/MacOS/Codex"
            ),
            .codexDesktop
        )
        XCTAssertEqual(
            AgentProcessProvider.executionSurface(
                executableName: "codex-aarch64-apple-darwin",
                executablePath: "/opt/homebrew/bin/codex-aarch64-apple-darwin",
                parentExecutablePath: "/bin/zsh"
            ),
            .codexCLI
        )
        XCTAssertFalse(AgentExecutionSurface.codexDesktop.supportsStandaloneDiscovery)
        XCTAssertTrue(AgentExecutionSurface.codexCLI.supportsStandaloneDiscovery)
    }

    func testAppEmbeddedCodexLaunchedFromTerminalIsStillCLI() {
        XCTAssertEqual(
            AgentProcessProvider.executionSurface(
                executableName: "codex",
                executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex",
                parentExecutablePath: "/bin/zsh"
            ),
            .codexCLI
        )
    }

    func testCodexEmbeddedByAnUnrelatedAppIsNotMarkedAsCodexDesktop() {
        XCTAssertEqual(
            AgentProcessProvider.executionSurface(
                executableName: "codex",
                executablePath: "/Applications/Other.app/Contents/Resources/codex",
                parentExecutablePath: "/Applications/Other.app/Contents/MacOS/Other"
            ),
            .codexCLI
        )
    }

    func testClaudeDesktopIsNotMistakenForClaudeCode() {
        XCTAssertNil(AgentProcessProvider.executionSurface(
            executableName: "claude",
            executablePath: "/Applications/Claude.app/Contents/MacOS/claude",
            parentExecutablePath: "/Applications/Claude.app/Contents/MacOS/Claude"
        ))
        XCTAssertEqual(
            AgentProcessProvider.executionSurface(
                executableName: "claude",
                executablePath: "/Users/test/.local/bin/claude",
                parentExecutablePath: "/bin/zsh"
            ),
            .claudeCodeCLI
        )
    }

    func testClaudeDesktopCodeTabRuntimeIsClaudeCodeDesktop() {
        XCTAssertEqual(
            AgentProcessProvider.executionSurface(
                executableName: "claude",
                executablePath: "/Users/test/Library/Application Support/Claude/claude-code/2.1.308/a93ded4b1b47/claude.app/Contents/MacOS/claude",
                parentExecutablePath: "/Applications/Claude.app/Contents/Helpers/disclaimer"
            ),
            .claudeCodeDesktop
        )
        // An unrelated bundle named claude.app elsewhere is still not proof.
        XCTAssertNil(AgentProcessProvider.executionSurface(
            executableName: "claude",
            executablePath: "/Users/test/Downloads/claude.app/Contents/MacOS/claude",
            parentExecutablePath: "/bin/zsh"
        ))
        XCTAssertNil(AgentProcessProvider.executionSurface(
            executableName: "Claude",
            executablePath: "/Applications/Claude.app/Contents/MacOS/Claude",
            parentExecutablePath: "/sbin/launchd"
        ))
    }

    func testDesktopSurfacesNeverCreateStandaloneDiscovery() {
        XCTAssertFalse(AgentExecutionSurface.codexDesktop.supportsStandaloneDiscovery)
        XCTAssertFalse(AgentExecutionSurface.claudeCodeDesktop.supportsStandaloneDiscovery)
        XCTAssertFalse(AgentExecutionSurface.paseo.supportsStandaloneDiscovery)
        XCTAssertFalse(AgentExecutionSurface.antigravity.supportsStandaloneDiscovery)
        XCTAssertTrue(AgentExecutionSurface.claudeCodeCLI.supportsStandaloneDiscovery)
        XCTAssertEqual(AgentExecutionSurface.claudeCodeDesktop.provider, .claude)
        XCTAssertEqual(AgentExecutionSurface.paseo.provider, .paseo)
        XCTAssertEqual(AgentExecutionSurface.antigravity.provider, .antigravity)
    }

    func testPaseoAndAntigravityExecutionSurfacesRejectUnrelatedProcesses() {
        // Antigravity main app, bundled language_server, and agy CLI are recognized.
        XCTAssertEqual(
            AgentProcessProvider.executionSurface(
                executableName: "Antigravity",
                executablePath: "/Applications/Antigravity.app/Contents/MacOS/Antigravity",
                parentExecutablePath: "/sbin/launchd"
            ),
            .antigravity
        )
        XCTAssertEqual(
            AgentProcessProvider.executionSurface(
                executableName: "language_server",
                executablePath: "/Applications/Antigravity.app/Contents/Resources/bin/language_server",
                parentExecutablePath: "/Applications/Antigravity.app/Contents/MacOS/Antigravity"
            ),
            .antigravity
        )
        XCTAssertEqual(
            AgentProcessProvider.executionSurface(
                executableName: "agy",
                executablePath: "/opt/homebrew/bin/agy",
                parentExecutablePath: "/bin/zsh"
            ),
            .antigravity
        )
        // Unrelated LSPs named `language_server` and Renderer helpers are rejected.
        XCTAssertNil(
            AgentProcessProvider.executionSurface(
                executableName: "language_server",
                executablePath: "/opt/homebrew/bin/language_server",
                parentExecutablePath: "/bin/zsh"
            )
        )
        XCTAssertNil(AgentProcessProvider.detect(executableName: "Antigravity Helper (Renderer)"))

        // Paseo app, Paseo Helper (daemon/supervisor/plugin worker), and CLI are recognized.
        XCTAssertEqual(
            AgentProcessProvider.executionSurface(
                executableName: "Paseo",
                executablePath: "/Applications/Paseo.app/Contents/MacOS/Paseo",
                parentExecutablePath: "/sbin/launchd"
            ),
            .paseo
        )
        XCTAssertEqual(
            AgentProcessProvider.executionSurface(
                executableName: "Paseo Helper",
                executablePath: "/Applications/Paseo.app/Contents/Frameworks/Paseo Helper.app/Contents/MacOS/Paseo Helper",
                parentExecutablePath: "/Applications/Paseo.app/Contents/MacOS/Paseo"
            ),
            .paseo
        )
        XCTAssertEqual(
            AgentProcessProvider.executionSurface(
                executableName: "paseo",
                executablePath: "/usr/local/bin/paseo",
                parentExecutablePath: "/bin/zsh"
            ),
            .paseo
        )
        // Electron renderer helpers and Paseo Helper outside Paseo.app are rejected.
        XCTAssertNil(AgentProcessProvider.detect(executableName: "Paseo Helper (Renderer)"))
        XCTAssertNil(
            AgentProcessProvider.executionSurface(
                executableName: "Paseo Helper",
                executablePath: "/Applications/Other.app/Contents/Frameworks/Paseo Helper.app/Contents/MacOS/Paseo Helper",
                parentExecutablePath: "/Applications/Other.app/Contents/MacOS/Other"
            )
        )

        XCTAssertEqual(
            scan(surfaces: [.paseo, .antigravity]).codexPresence,
            .notDetected
        )
    }

    func testCodexPresenceDistinguishesDesktopCLIAndBoth() {
        XCTAssertEqual(
            CodexProcessPresence(scan: scan(surfaces: [.codexDesktop])),
            .desktopOnly
        )
        XCTAssertEqual(
            CodexProcessPresence(scan: scan(surfaces: [.codexCLI])),
            .cliOnly
        )
        XCTAssertEqual(
            CodexProcessPresence(scan: scan(surfaces: [.codexDesktop, .codexCLI])),
            .both
        )
    }

    func testCodexPresenceDistinguishesNoDetectionFromScanFailure() {
        XCTAssertEqual(CodexProcessPresence(scan: nil), .scanFailed)
        XCTAssertEqual(CodexProcessPresence(scan: scan(surfaces: [])), .notDetected)
        XCTAssertEqual(
            scan(surfaces: [.claudeCodeCLI, .claudeCodeDesktop]).codexPresence,
            .notDetected
        )
    }

    func testCodexPresenceDoesNotUseCPUAsTaskEvidence() {
        let coldDesktop = scan(surfaces: [.codexDesktop], cpuNanoseconds: 0)
        let hotDesktop = scan(surfaces: [.codexDesktop], cpuNanoseconds: .max)
        let unavailableCPU = scan(surfaces: [.codexDesktop], cpuNanoseconds: nil)

        XCTAssertEqual(coldDesktop.codexPresence, .desktopOnly)
        XCTAssertEqual(hotDesktop.codexPresence, .desktopOnly)
        XCTAssertEqual(unavailableCPU.codexPresence, .desktopOnly)
        XCTAssertEqual(
            CodexProcessPresence(snapshots: unavailableCPU.snapshots),
            .desktopOnly
        )
    }

    func testStartTimePreventsPIDReuseCollision() {
        let first = AgentProcessIdentity(pid: 42, startTimeMicroseconds: 100)
        let recycled = AgentProcessIdentity(pid: 42, startTimeMicroseconds: 200)
        XCTAssertNotEqual(first, recycled)
    }

    func testOnlyNewestProcessScanGenerationCanApply() {
        var gate = AgentProcessScanGenerationGate()
        let first = gate.begin()
        let second = gate.begin()

        XCTAssertFalse(gate.accepts(first))
        XCTAssertTrue(gate.accepts(second))

        gate.invalidate()
        XCTAssertFalse(gate.accepts(second))
        let third = gate.begin()
        XCTAssertTrue(gate.accepts(third))
    }

    func testAssociationRequiresTwoCompleteMissingScans() {
        let identity = AgentProcessIdentity(pid: 42, startTimeMicroseconds: 100)
        let session = AgentSessionKey(provider: .codex, sessionID: "session-1")
        var tracker = AgentProcessAssociationTracker()
        tracker.associate(identity, with: session)

        XCTAssertTrue(tracker.observe(currentIdentities: []).isEmpty)
        XCTAssertEqual(tracker.observe(currentIdentities: []), [session])
        XCTAssertTrue(tracker.observe(currentIdentities: []).isEmpty)
    }

    func testAssociationPresenceResetsMissCountAndWaitsForLastProcess() {
        let first = AgentProcessIdentity(pid: 42, startTimeMicroseconds: 100)
        let second = AgentProcessIdentity(pid: 43, startTimeMicroseconds: 200)
        let session = AgentSessionKey(provider: .claudeCode, sessionID: "session-2")
        var tracker = AgentProcessAssociationTracker()
        tracker.associate(first, with: session)
        tracker.associate(second, with: session)

        XCTAssertTrue(tracker.observe(currentIdentities: [second]).isEmpty)
        XCTAssertTrue(tracker.observe(currentIdentities: [first, second]).isEmpty)
        XCTAssertTrue(tracker.observe(currentIdentities: [first]).isEmpty)
        XCTAssertTrue(tracker.observe(currentIdentities: [first]).isEmpty)
        XCTAssertTrue(tracker.observe(currentIdentities: []).isEmpty)
        XCTAssertEqual(tracker.observe(currentIdentities: []), [session])
    }

    func testSharedProcessRequiresTwoMissesForEachSession() {
        let identity = AgentProcessIdentity(pid: 42, startTimeMicroseconds: 100)
        let first = AgentSessionKey(provider: .codex, sessionID: "session-a")
        let second = AgentSessionKey(provider: .codex, sessionID: "session-b")
        var tracker = AgentProcessAssociationTracker()
        tracker.associate(identity, with: first)
        tracker.associate(identity, with: second)

        XCTAssertTrue(tracker.observe(currentIdentities: []).isEmpty)
        XCTAssertEqual(tracker.observe(currentIdentities: []), [first, second])
    }

    private func scan(
        surfaces: [AgentExecutionSurface],
        cpuNanoseconds: UInt64? = 10
    ) -> AgentProcessScan {
        let snapshots = surfaces.enumerated().map { index, surface in
            AgentProcessSnapshot(
                identity: AgentProcessIdentity(
                    pid: pid_t(index + 10),
                    startTimeMicroseconds: UInt64(index + 100)
                ),
                parentPID: 1,
                executableName: surface.provider == .claude ? "claude" : "codex",
                executionSurface: surface,
                cumulativeCPUNanoseconds: cpuNanoseconds
            )
        }
        return AgentProcessScan(
            snapshots: snapshots,
            listedPIDs: Set(snapshots.map(\.identity.pid)),
            startTimesByPID: Dictionary(uniqueKeysWithValues: snapshots.map {
                ($0.identity.pid, $0.identity.startTimeMicroseconds)
            })
        )
    }
}
