import AppKit
import CoreGraphics
import XCTest

@MainActor
final class DisplayTopologyMonitorTests: XCTestCase {
    private let builtin: CGDirectDisplayID = 1
    private let externalOne: CGDirectDisplayID = 2
    private let externalTwo: CGDirectDisplayID = 3

    func testOnlyBuiltinDisplayIsDisconnected() {
        let monitor = makeMonitor(
            onlineDisplayIDs: [builtin],
            builtinDisplayIDs: [builtin]
        )

        XCTAssertEqual(monitor.state, .disconnected)
    }

    func testBuiltinAndNamedExternalDisplayAreConnected() {
        let monitor = makeMonitor(
            onlineDisplayIDs: [builtin, externalOne],
            builtinDisplayIDs: [builtin],
            namesByID: [externalOne: "LG UltraFine"]
        )

        XCTAssertEqual(
            monitor.state,
            .connected(count: 1, names: ["LG UltraFine"])
        )
    }

    func testExternalOnlyTopologyIsConnectedWhenBuiltinPanelIsOffline() {
        let monitor = makeMonitor(
            onlineDisplayIDs: [externalOne],
            namesByID: [externalOne: "LG UltraFine"]
        )

        XCTAssertEqual(
            monitor.state,
            .connected(count: 1, names: ["LG UltraFine"])
        )
    }

    func testMirroredExternalDisplayDoesNotDependOnNSScreenNameMapping() {
        let monitor = makeMonitor(
            onlineDisplayIDs: [builtin, externalOne],
            builtinDisplayIDs: [builtin],
            // In mirror mode NSScreen may expose only the mirror master.
            namesByID: [builtin: "Built-in Retina Display"]
        )

        XCTAssertEqual(monitor.state, .connected(count: 1, names: []))
    }

    func testMultipleExternalDisplaysPreserveEveryAvailableName() {
        let monitor = makeMonitor(
            onlineDisplayIDs: [builtin, externalOne, externalTwo],
            builtinDisplayIDs: [builtin],
            namesByID: [
                externalOne: "LG UltraFine",
                externalTwo: "DELL U2723QE"
            ]
        )

        XCTAssertEqual(
            monitor.state,
            .connected(count: 2, names: ["LG UltraFine", "DELL U2723QE"])
        )
    }

    func testDuplicateDisplayIDsDoNotInflateExternalCount() {
        let monitor = makeMonitor(
            onlineDisplayIDs: [builtin, externalOne, externalOne],
            builtinDisplayIDs: [builtin],
            namesByID: [externalOne: "LG UltraFine"]
        )

        XCTAssertEqual(
            monitor.state,
            .connected(count: 1, names: ["LG UltraFine"])
        )
    }

    func testMissingAndBlankNamesStillReportConnected() {
        let monitor = makeMonitor(
            onlineDisplayIDs: [externalOne, externalTwo],
            namesByID: [externalOne: "  "]
        )

        XCTAssertEqual(monitor.state, .connected(count: 2, names: []))
    }

    func testSuccessfulEmptyDisplayListIsUnknown() {
        let monitor = makeMonitor(onlineDisplayIDs: [])

        XCTAssertEqual(monitor.state, .unknown)
    }

    func testCoreGraphicsFailureIsUnknown() {
        let probe = DisplayTopologyProbe(
            onlineDisplayIDs: { throw ProbeFailure.unavailable },
            isBuiltin: { _ in false },
            displayNamesByID: { [:] }
        )
        let monitor = DisplayTopologyMonitor(
            probe: probe,
            observesScreenChanges: false
        )

        XCTAssertEqual(monitor.state, .unknown)
    }

    func testCurrentStateReprobesAndPublishesLatestTopology() {
        var onlineDisplayIDs = [builtin]
        let probe = DisplayTopologyProbe(
            onlineDisplayIDs: { onlineDisplayIDs },
            isBuiltin: { $0 == self.builtin },
            displayNamesByID: { [self.externalOne: "LG UltraFine"] }
        )
        let monitor = DisplayTopologyMonitor(
            probe: probe,
            observesScreenChanges: false
        )
        XCTAssertEqual(monitor.state, .disconnected)

        onlineDisplayIDs = [builtin, externalOne]

        XCTAssertEqual(
            monitor.currentState(),
            .connected(count: 1, names: ["LG UltraFine"])
        )
        XCTAssertEqual(
            monitor.state,
            .connected(count: 1, names: ["LG UltraFine"])
        )
    }

    func testScreenParametersNotificationRefreshesTopology() {
        let notificationCenter = NotificationCenter()
        var onlineDisplayIDs = [builtin]
        let probe = DisplayTopologyProbe(
            onlineDisplayIDs: { onlineDisplayIDs },
            isBuiltin: { $0 == self.builtin },
            displayNamesByID: { [self.externalOne: "LG UltraFine"] }
        )
        let monitor = DisplayTopologyMonitor(
            probe: probe,
            notificationCenter: notificationCenter
        )
        XCTAssertEqual(monitor.state, .disconnected)

        onlineDisplayIDs = [builtin, externalOne]
        notificationCenter.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(
            monitor.state,
            .connected(count: 1, names: ["LG UltraFine"])
        )
    }

    private func makeMonitor(
        onlineDisplayIDs: [CGDirectDisplayID],
        builtinDisplayIDs: Set<CGDirectDisplayID> = [],
        namesByID: [CGDirectDisplayID: String] = [:]
    ) -> DisplayTopologyMonitor {
        let probe = DisplayTopologyProbe(
            onlineDisplayIDs: { onlineDisplayIDs },
            isBuiltin: { builtinDisplayIDs.contains($0) },
            displayNamesByID: { namesByID }
        )
        return DisplayTopologyMonitor(
            probe: probe,
            observesScreenChanges: false
        )
    }

    private enum ProbeFailure: Error {
        case unavailable
    }
}
