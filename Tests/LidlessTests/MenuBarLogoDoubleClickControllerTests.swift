import AppKit
import XCTest

@MainActor
final class MenuBarLogoDoubleClickControllerTests: XCTestCase {
    private let logoRect = NSRect(x: 0, y: 0, width: 30, height: 24)
    private let baseTime: TimeInterval = 10

    func testSingleClickPassesThroughWithoutTriggeringBlackout() async {
        var callbacks = 0
        let controller = makeController { callbacks += 1 }
        let down = event(.leftMouseDown)
        let up = event(.leftMouseUp)

        XCTAssertTrue(controller.handle(down) === down)
        XCTAssertTrue(controller.handle(up) === up)
        await drainMainQueue()
        XCTAssertEqual(callbacks, 0)
    }

    func testDoubleClickConsumesSecondClickAndDefersCallbackUntilAfterRelease() async {
        var callbacks = 0
        let controller = makeController { callbacks += 1 }
        _ = controller.handle(event(.leftMouseDown))
        _ = controller.handle(event(.leftMouseUp))

        XCTAssertNil(controller.handle(event(.leftMouseDown, clickCount: 2, timestamp: secondClickTime)))
        await drainMainQueue()
        XCTAssertEqual(callbacks, 0, "A held second click must not start blackout")

        XCTAssertNil(controller.handle(event(.leftMouseUp, clickCount: 2, timestamp: secondClickTime)))
        XCTAssertEqual(callbacks, 0, "Dismissal and blackout must wait until mouseUp routing finishes")
        await drainMainQueue()
        XCTAssertEqual(callbacks, 1)
    }

    func testDoubleClickWorksWhenNativeButtonTrackingConsumesFirstRelease() async {
        var callbacks = 0
        let controller = makeController { callbacks += 1 }
        _ = controller.handle(event(.leftMouseDown))

        XCTAssertNil(controller.handle(event(.leftMouseDown, clickCount: 2, timestamp: secondClickTime)))
        XCTAssertNil(controller.handle(event(.leftMouseUp, clickCount: 2, timestamp: secondClickTime)))
        await drainMainQueue()
        XCTAssertEqual(callbacks, 1)
    }

    func testSecondClickOutsideLogoDoesNotTrigger() async {
        var callbacks = 0
        let controller = makeController { callbacks += 1 }
        _ = controller.handle(event(.leftMouseDown))
        let down = event(.leftMouseDown, clickCount: 2, timestamp: secondClickTime, point: NSPoint(x: 50, y: 12))
        let up = event(.leftMouseUp, clickCount: 2, timestamp: secondClickTime, point: NSPoint(x: 50, y: 12))

        XCTAssertTrue(controller.handle(down) === down)
        XCTAssertTrue(controller.handle(up) === up)
        await drainMainQueue()
        XCTAssertEqual(callbacks, 0)
    }

    func testStaleOrBackwardsSecondClickDoesNotTrigger() async {
        for timestamp in [baseTime + NSEvent.doubleClickInterval + 0.1, baseTime - 0.1] {
            var callbacks = 0
            let controller = makeController { callbacks += 1 }
            _ = controller.handle(event(.leftMouseDown))
            let down = event(.leftMouseDown, clickCount: 2, timestamp: timestamp)
            let up = event(.leftMouseUp, clickCount: 2, timestamp: timestamp)

            XCTAssertTrue(controller.handle(down) === down)
            XCTAssertTrue(controller.handle(up) === up)
            await drainMainQueue()
            XCTAssertEqual(callbacks, 0)
        }
    }

    func testSecondClickInAnotherWindowDoesNotTrigger() async {
        var callbacks = 0
        let controller = makeController { callbacks += 1 }
        _ = controller.handle(event(.leftMouseDown))
        let down = event(.leftMouseDown, clickCount: 2, timestamp: secondClickTime, windowNumber: 8)
        let up = event(.leftMouseUp, clickCount: 2, timestamp: secondClickTime, windowNumber: 8)

        XCTAssertTrue(controller.handle(down) === down)
        XCTAssertTrue(controller.handle(up) === up)
        await drainMainQueue()
        XCTAssertEqual(callbacks, 0)
    }

    func testUnrelatedLeftClickOrRightClickResetsFirstClick() async {
        for interveningEvent in [
            event(.leftMouseDown, point: NSPoint(x: 50, y: 12)),
            event(.rightMouseDown)
        ] {
            var callbacks = 0
            let controller = makeController { callbacks += 1 }
            _ = controller.handle(event(.leftMouseDown))
            XCTAssertTrue(controller.handle(interveningEvent) === interveningEvent)
            let down = event(.leftMouseDown, clickCount: 2, timestamp: secondClickTime)
            let up = event(.leftMouseUp, clickCount: 2, timestamp: secondClickTime)

            XCTAssertTrue(controller.handle(down) === down)
            XCTAssertTrue(controller.handle(up) === up)
            await drainMainQueue()
            XCTAssertEqual(callbacks, 0)
        }
    }

    func testModifiedSecondClickDoesNotTrigger() async {
        let modifierSets: [NSEvent.ModifierFlags] = [.command, .control, .option, .shift]
        for modifiers in modifierSets {
            var callbacks = 0
            let controller = makeController { callbacks += 1 }
            _ = controller.handle(event(.leftMouseDown))
            let down = event(.leftMouseDown, clickCount: 2, timestamp: secondClickTime, modifiers: modifiers)
            let up = event(.leftMouseUp, clickCount: 2, timestamp: secondClickTime, modifiers: modifiers)

            XCTAssertTrue(controller.handle(down) === down)
            XCTAssertTrue(controller.handle(up) === up)
            await drainMainQueue()
            XCTAssertEqual(callbacks, 0)
        }
    }

    func testReleaseInAnotherWindowCancelsDoubleClick() async {
        var callbacks = 0
        let controller = makeController { callbacks += 1 }
        _ = controller.handle(event(.leftMouseDown))
        XCTAssertNil(controller.handle(event(.leftMouseDown, clickCount: 2, timestamp: secondClickTime)))
        XCTAssertNil(controller.handle(event(.leftMouseUp, clickCount: 2, timestamp: secondClickTime, windowNumber: 8)))

        await drainMainQueue()
        XCTAssertEqual(callbacks, 0)
        let nextUp = event(.leftMouseUp, clickCount: 2, timestamp: secondClickTime)
        XCTAssertTrue(controller.handle(nextUp) === nextUp, "A mismatched release must clear the pending click")
    }

    func testDraggingOutCancelsEvenIfReleasedBackInsideLogo() async {
        var callbacks = 0
        let controller = makeController { callbacks += 1 }
        _ = controller.handle(event(.leftMouseDown))
        XCTAssertNil(controller.handle(event(.leftMouseDown, clickCount: 2, timestamp: secondClickTime)))
        let drag = event(.leftMouseDragged, clickCount: 2, timestamp: secondClickTime, point: NSPoint(x: 50, y: 12))
        _ = controller.handle(drag)
        _ = controller.handle(event(.leftMouseUp, clickCount: 2, timestamp: secondClickTime))

        await drainMainQueue()
        XCTAssertEqual(callbacks, 0, "Leaving the logo cancels the action for this click")
    }

    func testTripleClickTriggersOnlyOnce() async {
        var callbacks = 0
        let controller = makeController { callbacks += 1 }
        _ = controller.handle(event(.leftMouseDown))
        _ = controller.handle(event(.leftMouseUp))
        XCTAssertNil(controller.handle(event(.leftMouseDown, clickCount: 2, timestamp: secondClickTime)))
        XCTAssertNil(controller.handle(event(.leftMouseUp, clickCount: 2, timestamp: secondClickTime)))
        let thirdDown = event(.leftMouseDown, clickCount: 3, timestamp: secondClickTime)
        let thirdUp = event(.leftMouseUp, clickCount: 3, timestamp: secondClickTime)

        XCTAssertTrue(controller.handle(thirdDown) === thirdDown)
        XCTAssertTrue(controller.handle(thirdUp) === thirdUp)
        await drainMainQueue()
        XCTAssertEqual(callbacks, 1)
    }

    func testStopClearsFirstClickAndInterceptedClick() async {
        for stopAfterSecondDown in [false, true] {
            var callbacks = 0
            let controller = makeController { callbacks += 1 }
            _ = controller.handle(event(.leftMouseDown))
            if stopAfterSecondDown {
                XCTAssertNil(controller.handle(event(.leftMouseDown, clickCount: 2, timestamp: secondClickTime)))
            }
            controller.stop()
            if !stopAfterSecondDown {
                let down = event(.leftMouseDown, clickCount: 2, timestamp: secondClickTime)
                XCTAssertTrue(controller.handle(down) === down)
            }
            let up = event(.leftMouseUp, clickCount: 2, timestamp: secondClickTime)
            XCTAssertTrue(controller.handle(up) === up)

            await drainMainQueue()
            XCTAssertEqual(callbacks, 0)
        }
    }

    private var secondClickTime: TimeInterval {
        baseTime + NSEvent.doubleClickInterval / 2
    }

    private func makeController(onDoubleClick: @escaping () -> Void) -> MenuBarLogoDoubleClickController {
        MenuBarLogoDoubleClickController(
            isLogoEvent: { [logoRect] event in
                event.windowNumber == 7 && logoRect.contains(event.locationInWindow)
            },
            onDoubleClick: onDoubleClick
        )
    }

    private func event(
        _ type: NSEvent.EventType,
        clickCount: Int = 1,
        timestamp: TimeInterval? = nil,
        windowNumber: Int = 7,
        point: NSPoint = NSPoint(x: 15, y: 12),
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifiers,
            timestamp: timestamp ?? baseTime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        )!
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
