import XCTest

final class AudioInputSwitchConfigurationTests: XCTestCase {
    private let primary = AudioInputSelection(uid: "uid-a", lastKnownName: "Built-in")
    private let secondary = AudioInputSelection(uid: "uid-b", lastKnownName: "Display")

    func testEmptyHasNoSelections() {
        XCTAssertNil(AudioInputSwitchConfiguration.empty.primary)
        XCTAssertNil(AudioInputSwitchConfiguration.empty.secondary)
    }

    func testSanitizedTrimsUIDAndLastKnownName() {
        let configuration = AudioInputSwitchConfiguration(
            primary: AudioInputSelection(
                uid: "  uid-a\n",
                lastKnownName: "  MacBook Pro Microphone \n"
            ),
            secondary: nil
        ).sanitized()

        XCTAssertEqual(
            configuration.primary,
            AudioInputSelection(uid: "uid-a", lastKnownName: "MacBook Pro Microphone")
        )
    }

    func testSanitizedDropsWhitespaceOnlyUIDs() {
        let configuration = AudioInputSwitchConfiguration(
            primary: AudioInputSelection(uid: " \n", lastKnownName: "Primary"),
            secondary: AudioInputSelection(uid: "\t", lastKnownName: "Secondary")
        ).sanitized()

        XCTAssertEqual(configuration, .empty)
    }

    func testSanitizedKeepsPrimaryAndDropsDuplicateSecondary() {
        let configuration = AudioInputSwitchConfiguration(
            primary: AudioInputSelection(uid: "uid-a", lastKnownName: "Primary"),
            secondary: AudioInputSelection(uid: " uid-a ", lastKnownName: "Duplicate")
        ).sanitized()

        XCTAssertEqual(configuration.primary?.uid, "uid-a")
        XCTAssertNil(configuration.secondary)
    }

    func testConfigurationCodableRoundTripPreservesPersistentUIDs() throws {
        let original = configuration()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            AudioInputSwitchConfiguration.self,
            from: data
        )

        XCTAssertEqual(decoded, original)
    }

    func testRouteFromPrimaryTargetsSecondaryEvenWhenSecondaryIsOffline() {
        XCTAssertEqual(
            route(currentUID: primary.uid, availableUIDs: [primary.uid]),
            AudioInputSwitchRoute(slot: .secondary, selection: secondary)
        )
    }

    func testRouteFromSecondaryTargetsPrimaryEvenWhenPrimaryIsOffline() {
        XCTAssertEqual(
            route(currentUID: secondary.uid, availableUIDs: [secondary.uid]),
            AudioInputSwitchRoute(slot: .primary, selection: primary)
        )
    }

    func testRouteFromUnconfiguredInputPrefersOnlinePrimary() {
        XCTAssertEqual(
            route(currentUID: "uid-other", availableUIDs: [primary.uid, secondary.uid]),
            AudioInputSwitchRoute(slot: .primary, selection: primary)
        )
    }

    func testRouteFromUnconfiguredInputUsesSecondaryWhenPrimaryIsOffline() {
        XCTAssertEqual(
            route(currentUID: nil, availableUIDs: [secondary.uid]),
            AudioInputSwitchRoute(slot: .secondary, selection: secondary)
        )
    }

    func testRouteFromUnconfiguredInputKeepsPrimaryAsFailedTargetWhenBothOffline() {
        XCTAssertEqual(
            route(currentUID: "uid-other", availableUIDs: []),
            AudioInputSwitchRoute(slot: .primary, selection: primary)
        )
    }

    func testRouteRequiresBothDistinctSelections() {
        XCTAssertNil(AudioInputSwitchRouter.route(
            configuration: AudioInputSwitchConfiguration(
                primary: primary,
                secondary: nil
            ),
            currentUID: nil,
            availableUIDs: [primary.uid]
        ))

        XCTAssertNil(AudioInputSwitchRouter.route(
            configuration: AudioInputSwitchConfiguration(
                primary: primary,
                secondary: primary
            ),
            currentUID: nil,
            availableUIDs: [primary.uid]
        ))
    }

    private func configuration() -> AudioInputSwitchConfiguration {
        AudioInputSwitchConfiguration(primary: primary, secondary: secondary)
    }

    private func route(
        currentUID: String?,
        availableUIDs: Set<String>
    ) -> AudioInputSwitchRoute? {
        AudioInputSwitchRouter.route(
            configuration: configuration(),
            currentUID: currentUID,
            availableUIDs: availableUIDs
        )
    }
}
