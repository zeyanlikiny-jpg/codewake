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
}
