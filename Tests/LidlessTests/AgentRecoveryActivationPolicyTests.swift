import XCTest

final class AgentRecoveryActivationPolicyTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testTurnStartActivatesOnlyExactTurnNotSibling() {
        let snapshot = recovery([
            state(session: "shared", turn: "parent"),
            state(session: "shared", turn: "child"),
        ])

        for kind in [
            AgentEventKind.promptSubmitted,
            .toolStarted,
            .inputReceived,
        ] {
            let matches = AgentRecoveryActivationPolicy.matchingStates(
                in: snapshot,
                for: event(kind, session: "shared", turn: "parent", seconds: 2)
            )
            XCTAssertEqual(matches.compactMap(\.turnID), ["parent"], "kind: \(kind)")
        }
    }

    func testTerminalWaitAndToolFinishEventsCannotActivateRecovery() {
        let snapshot = recovery([state(session: "shared", turn: "parent")])
        let rejectedKinds: [AgentEventKind] = [
            .toolFinished,
            .turnCompleted,
            .waitingForInput,
            .turnStopped,
            .turnFailed,
            .turnCancelled,
            .backgroundWorkChanged,
            .sessionEnded,
            .processExited,
            .activity,
        ]

        for kind in rejectedKinds {
            XCTAssertTrue(
                AgentRecoveryActivationPolicy.matchingStates(
                    in: snapshot,
                    for: event(kind, session: "shared", turn: "parent", seconds: 2)
                ).isEmpty,
                "kind: \(kind)"
            )
        }
    }

    func testSessionAndProcessStartsDoNotReactivateTurns() {
        let snapshot = recovery([
            state(session: "shared", turn: "parent"),
            state(session: "shared", turn: "child"),
            state(session: "other", turn: "other-turn"),
        ])

        for kind in [AgentEventKind.sessionStarted, .processDiscovered] {
            let matches = AgentRecoveryActivationPolicy.matchingStates(
                in: snapshot,
                for: event(kind, session: "shared", turn: nil, seconds: 2)
            )
            XCTAssertTrue(matches.isEmpty, "kind: \(kind)")
        }
    }

    func testTurnScopedStartWithoutTurnIDCannotSelectSiblingTurns() {
        let snapshot = recovery([
            state(session: "shared", turn: "parent"),
            state(session: "shared", turn: "child"),
        ])

        for kind in [
            AgentEventKind.promptSubmitted,
            .toolStarted,
            .inputReceived,
        ] {
            XCTAssertTrue(
                AgentRecoveryActivationPolicy.matchingStates(
                    in: snapshot,
                    for: event(kind, session: "shared", turn: nil, seconds: 2)
                ).isEmpty,
                "kind: \(kind)"
            )
        }
    }

    func testStartOlderThanRecoveredStateCannotActivateIt() {
        let snapshot = recovery([
            state(session: "shared", turn: "parent", lastEventSeconds: 5),
        ])

        XCTAssertTrue(
            AgentRecoveryActivationPolicy.matchingStates(
                in: snapshot,
                for: event(.toolStarted, session: "shared", turn: "parent", seconds: 4)
            ).isEmpty
        )
        XCTAssertEqual(
            AgentRecoveryActivationPolicy.matchingStates(
                in: snapshot,
                for: event(.toolStarted, session: "shared", turn: "parent", seconds: 5)
            ).compactMap(\.turnID),
            ["parent"]
        )
    }

    private func recovery(_ states: [AgentSessionState]) -> AgentStateRecoverySnapshot {
        AgentStateRecoverySnapshot(sessions: states, tombstones: [])
    }

    private func event(
        _ kind: AgentEventKind,
        session: String,
        turn: String?,
        seconds: TimeInterval
    ) -> AgentEvent {
        AgentEvent(
            provider: .codex,
            sessionID: session,
            turnID: turn,
            eventKind: kind,
            timestamp: base.addingTimeInterval(seconds)
        )
    }

    private func state(
        session: String,
        turn: String,
        lastEventSeconds: TimeInterval = 1
    ) -> AgentSessionState {
        let started = base
        return AgentSessionState(
            key: AgentSessionKey(provider: .codex, sessionID: session),
            turnRole: turn == "parent" ? .primary : .auxiliary,
            phase: .working,
            turnID: turn,
            turnStartedAt: started,
            hardDeadline: started.addingTimeInterval(100),
            lastActivityAt: base.addingTimeInterval(lastEventSeconds),
            lastEventAt: base.addingTimeInterval(lastEventSeconds),
            graceDeadline: nil,
            backgroundWork: false,
            backgroundWorkCount: 0,
            turnStopObserved: false,
            waitingObserved: false,
            lastBackgroundSignalAt: nil,
            lastBackgroundSignalValue: nil
        )
    }
}
