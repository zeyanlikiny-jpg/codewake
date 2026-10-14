import AppKit

/// Leaves the first click to SwiftUI and handles only a native double-click on
/// our status item. Intercepting the second mouseDown avoids button tracking,
/// which can otherwise consume mouseUp before a local event monitor sees it.
@MainActor
final class MenuBarLogoDoubleClickController {
    private let isLogoEvent: @MainActor (NSEvent) -> Bool
    private let onDoubleClick: () -> Void
    private var monitor: Any?
    private var firstClick: (windowNumber: Int, timestamp: TimeInterval)?
    private var interceptedWindowNumber: Int?
    private var interceptedClickCancelled = false

    init(
        isLogoEvent: @escaping @MainActor (NSEvent) -> Bool = MenuBarExtraPanel.isStatusItemButtonEvent,
        onDoubleClick: @escaping () -> Void
    ) {
        self.isLogoEvent = isLogoEvent
        self.onDoubleClick = onDoubleClick
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        firstClick = nil
        interceptedWindowNumber = nil
        interceptedClickCancelled = false
    }

    /// Internal so tests can exercise the actual event routing without a live
    /// menu bar or changing the display brightness.
    func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            interceptedWindowNumber = nil
            interceptedClickCancelled = false
            let previous = firstClick
            firstClick = nil
            guard isLogoEvent(event),
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
                return event
            }
            if event.clickCount == 2,
               let previous,
               previous.windowNumber == event.windowNumber,
               event.timestamp >= previous.timestamp,
               event.timestamp - previous.timestamp <= NSEvent.doubleClickInterval {
                interceptedWindowNumber = event.windowNumber
                return nil
            }
            if event.clickCount == 1 {
                firstClick = (event.windowNumber, event.timestamp)
            }
            return event
        case .leftMouseDragged:
            guard interceptedWindowNumber != nil else { return event }
            if !isLogoEvent(event) { interceptedClickCancelled = true }
            return nil
        case .leftMouseUp:
            guard let windowNumber = interceptedWindowNumber else { return event }
            interceptedWindowNumber = nil
            if !interceptedClickCancelled,
               event.windowNumber == windowNumber, isLogoEvent(event) {
                // Finish the physical click before dismissing the panel and
                // arming the existing blackout watchdog's input baseline.
                DispatchQueue.main.async { [weak self] in
                    self?.onDoubleClick()
                }
            }
            interceptedClickCancelled = false
            return nil
        case .rightMouseDown:
            firstClick = nil
            interceptedWindowNumber = nil
            return event
        default:
            return event
        }
    }
}
