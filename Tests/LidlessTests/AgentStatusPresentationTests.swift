import XCTest

final class AgentStatusPresentationTests: XCTestCase {
    func testWorkingAndAttentionUseSemanticAgentStatusColors() {
        XCTAssertEqual(
            AgentStatusColorRole.resolve(for: .working),
            .working
        )
        XCTAssertEqual(
            AgentStatusColorRole.resolve(for: .attention),
            .attention
        )
    }

    func testNormalAndManualOnlyActivityKeepAgentStatusNeutral() {
        XCTAssertEqual(
            AgentStatusColorRole.resolve(for: .normal),
            .neutral
        )
        XCTAssertEqual(
            AgentStatusColorRole.resolve(for: .manualActive),
            .neutral,
            "A manual hold may color the menu icon green without implying that an agent is working."
        )
    }

    func testPaseoAndAntigravityStatusesDriveWorkingAndAttentionPresentation() {
        let working = CodexTaskSemanticStatus.working(CodexTaskSemanticDetails(
            workingCount: 1,
            waitingCount: 0,
            finishingCount: 0,
            unknownCount: 0,
            waitingReason: nil
        ))
        let waiting = CodexTaskSemanticStatus.waiting(CodexTaskSemanticDetails(
            workingCount: 0,
            waitingCount: 1,
            finishingCount: 0,
            unknownCount: 0,
            waitingReason: .permission
        ))

        XCTAssertEqual(
            MenuBarIconPresentation.resolve(
                isKeepAwakeActive: true,
                isManualKeepAwakeActive: false,
                codexStatus: .idle,
                antigravityStatus: working
            ),
            .working
        )
        XCTAssertEqual(
            MenuBarIconPresentation.resolve(
                isKeepAwakeActive: true,
                isManualKeepAwakeActive: false,
                codexStatus: .idle,
                paseoStatus: working
            ),
            .working
        )
        XCTAssertEqual(
            MenuBarIconPresentation.resolve(
                isKeepAwakeActive: true,
                isManualKeepAwakeActive: false,
                codexStatus: working,
                paseoStatus: waiting
            ),
            .attention
        )
    }
}
