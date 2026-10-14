import AppKit

/// Dismisses the popover SwiftUI presents for `MenuBarExtra(.window)`.
///
/// SwiftUI gives a view inside that popover no way to close it: there's no
/// `isPresented` binding on `MenuBarExtra`, and the `dismiss` environment action
/// doesn't reach the panel, since the popover is its own scene (FB11984872).
///
/// So we do what the user would: click the status item. That lets SwiftUI close
/// the panel through its own path and reset its presentation state, instead of
/// leaving the menu-bar icon stuck highlighted.
///
/// Both window classes involved are private AppKit/SwiftUI types matched by
/// name, so every step degrades to doing nothing rather than crashing if those
/// internals change.
@MainActor
enum MenuBarExtraPanel {
    /// SwiftUI hosts the popover in a private `NSWindow` subclass.
    static func isPanelWindow(className: String) -> Bool {
        className.contains("MenuBarExtraWindow")
    }

    /// The status bar hosts its items in a different private subclass — one per
    /// screen when "Displays have Separate Spaces" is on.
    static func isStatusBarWindow(className: String) -> Bool {
        className.contains("NSStatusBarWindow")
    }

    /// Which window `dismiss` would fall back to closing, given the class names
    /// of the app's windows in order — or nil when none of them is the panel.
    ///
    /// Pulled out as a pure function so the selection can be tested against
    /// arbitrary window lists. The alternative is standing up real `NSWindow`s
    /// in a test, which drags in window-server availability and AppKit's
    /// release-on-close lifecycle — neither of which has anything to do with
    /// the thing worth checking, which is that only the panel is ever picked.
    static func panelWindowIndex(classNames: [String]) -> Int? {
        classNames.firstIndex { isPanelWindow(className: $0) }
    }

    /// Class names of the status-bar windows to try, in order.
    static func statusBarWindowIndices(classNames: [String]) -> [Int] {
        classNames.indices.filter { isStatusBarWindow(className: classNames[$0]) }
    }

    static func statusItemButton(in window: NSWindow) -> NSStatusBarButton? {
        // Ask before reading this private property so a framework change is a
        // harmless no-op instead of an Objective-C KVC exception.
        guard isStatusBarWindow(className: window.className),
              window.responds(to: NSSelectorFromString("statusItem")),
              let item = window.value(forKey: "statusItem") as? NSStatusItem else {
            return nil
        }
        return item.button
    }

    static func isStatusItemButtonEvent(_ event: NSEvent) -> Bool {
        guard let window = event.window,
              let button = statusItemButton(in: window) else { return false }
        return button.bounds.contains(button.convert(event.locationInWindow, from: nil))
    }

    /// Close the popover if it's open. No-op when it isn't.
    static func dismiss() {
        dismiss(windows: NSApp.windows)
    }

    static func dismiss(windows: [NSWindow]) {
        for window in windows where isStatusBarWindow(className: window.className) {
            guard let button = statusItemButton(in: window),
                  button.state != .off  // clicking a closed popover would open it
            else { continue }

            button.performClick(button)
            button.isHighlighted = button.state != .off
            return
        }

        // If that shape ever changes, close the panel directly. The icon stays
        // highlighted until the next click, which beats a popover that won't go.
        if let index = panelWindowIndex(classNames: windows.map(\.className)) {
            windows[index].close()
        }
    }
}
