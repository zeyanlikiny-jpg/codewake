import XCTest

final class DisplaySleepRecoveryPresentationTests: XCTestCase {
    private let external = AllDisplaysSleepTopology.Display(id: 202, isBuiltIn: false)
    private let builtin = AllDisplaysSleepTopology.Display(id: 101, isBuiltIn: true)

    func testClosedLidOfflinePanelExplainsDeferredRecovery() {
        XCTAssertEqual(
            BuiltInDisplayRecoveryPresentation.message(
                status: .builtInUnavailable,
                failure: nil,
                topology: .known(lidClosed: true, displays: [external])
            ),
            "The lid is closed. Built-in brightness will recover when opened; external displays can still be turned off."
        )
    }

    func testOpenLidOfflinePanelDoesNotAdvertiseSafeDeferral() {
        XCTAssertEqual(
            BuiltInDisplayRecoveryPresentation.message(
                status: .builtInUnavailable,
                failure: nil,
                topology: .known(lidClosed: false, displays: [external])
            ),
            "The built-in display is offline. Brightness will be restored when it reconnects."
        )
    }

    func testOnlineBuiltinBrightnessFailureShowsActionableError() {
        XCTAssertEqual(
            BuiltInDisplayRecoveryPresentation.message(
                status: .brightnessUnavailable,
                failure: nil,
                topology: .known(lidClosed: false, displays: [builtin, external])
            ),
            "Built-in brightness recovery failed. Raise the built-in display brightness and try again."
        )
    }

    func testUnknownRecoveryStateDoesNotAdvertiseSafeDeferral() {
        XCTAssertEqual(
            BuiltInDisplayRecoveryPresentation.message(
                status: .topologyUnknown,
                failure: nil,
                topology: .unknown
            ),
            "Couldn’t confirm the lid or display state. Wait for the displays to reconnect and try again."
        )
        XCTAssertEqual(
            BuiltInDisplayRecoveryPresentation.message(
                status: nil,
                failure: nil,
                topology: .unknown
            ),
            "Built-in display brightness recovery is pending."
        )
        XCTAssertEqual(
            BuiltInDisplayRecoveryPresentation.message(
                status: .builtInUnavailable,
                failure: nil,
                topology: .known(lidClosed: nil, displays: [external])
            ),
            "The built-in display is offline. Brightness will be restored when it reconnects."
        )
    }

    func testExplicitFailureOverridesClosedLidFriendlyMessage() {
        let failures: [AllDisplaysSleepPreparationFailure] = [
            .builtInUnavailable,
            .brightnessUnavailable,
            .topologyUnknown,
            .invalidRecoveryRecord,
            .recoveryUnavailable,
            .recoveryFailed,
            .timedOut
        ]
        for failure in failures {
            XCTAssertEqual(
                BuiltInDisplayRecoveryPresentation.message(
                    status: .builtInUnavailable,
                    failure: failure,
                    topology: .known(lidClosed: true, displays: [external])
                ),
                failure.message,
                "An explicit \(failure) must not be hidden by the closed-lid explanation."
            )
        }
    }

    func testClosedLidWithOnlineBuiltinDoesNotAdvertiseSafeDeferral() {
        XCTAssertEqual(
            BuiltInDisplayRecoveryPresentation.message(
                status: .builtInUnavailable,
                failure: nil,
                topology: .known(lidClosed: true, displays: [builtin, external])
            ),
            "The built-in display is offline. Brightness will be restored when it reconnects."
        )
    }
}
