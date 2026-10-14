import AppKit
import SwiftUI

/// Sizing rules for the scrollable body of the menu-bar panel.
///
/// `MenuBarExtra(.window)` can initially propose a zero height, so every mode
/// starts from the legacy 520-point body until real content measurements arrive.
/// Once the panel has a screen, the body is capped to that screen's visible
/// frame so the fixed footer and its safety margin remain reachable.
enum MenuPopoverLayout {
    static let width: CGFloat = 360
    static let legacyBodyHeight: CGFloat = 520
    static let safeInitialBodyHeight = legacyBodyHeight
    static let screenSafeMargin: CGFloat = 16
    static let thirtyPercentScale: CGFloat = 1.3
    static let screenMetricsTolerance: CGFloat = 0.5

    /// Resolves the scroll viewport height from measurements owned by the menu.
    ///
    /// - Parameters:
    ///   - mode: The user's persisted menu-height choice.
    ///   - contentHeight: The natural, unconstrained height of the scroll body.
    ///   - footerHeight: The measured fixed-footer region, including its divider.
    ///   - screenVisibleHeight: `window.screen.visibleFrame.height` from the
    ///     window-hosted probe, or `nil` before that screen is known.
    static func resolvedBodyHeight(
        mode: MenuPopoverHeightMode,
        contentHeight: CGFloat,
        footerHeight: CGFloat,
        screenVisibleHeight: CGFloat?
    ) -> CGFloat {
        let measuredFooterHeight = validPositiveMeasurement(footerHeight)
        let footerHeight = measuredFooterHeight ?? 0
        let measuredContentHeight = validPositiveMeasurement(contentHeight)
            ?? safeInitialBodyHeight

        let desiredBodyHeight: CGFloat
        switch mode {
        case .thirtyPercentTaller:
            // The requested 30% applies to the whole legacy panel, not just the
            // scroll body. Wait for the real footer before scaling so the first
            // zero-height proposal remains at the safe legacy body height.
            if measuredFooterHeight != nil {
                desiredBodyHeight = (
                    (legacyBodyHeight + footerHeight) * thirtyPercentScale
                ) - footerHeight
            } else {
                desiredBodyHeight = safeInitialBodyHeight
            }
        case .showAll:
            desiredBodyHeight = measuredContentHeight
        }

        guard let screenVisibleHeight = validPositiveMeasurement(screenVisibleHeight)
        else {
            return desiredBodyHeight
        }

        let availableBodyHeight = max(
            0,
            screenVisibleHeight - footerHeight - screenSafeMargin
        )
        return min(desiredBodyHeight, availableBodyHeight)
    }

    /// Used by the AppKit probe to avoid state churn from sub-point geometry
    /// noise while still publishing the first valid screen measurement.
    static func shouldPublishScreenVisibleHeight(
        _ proposedHeight: CGFloat,
        after previousHeight: CGFloat?,
        tolerance: CGFloat = screenMetricsTolerance
    ) -> Bool {
        guard let proposedHeight = validPositiveMeasurement(proposedHeight) else {
            return false
        }
        guard let previousHeight = validPositiveMeasurement(previousHeight) else {
            return true
        }
        return abs(proposedHeight - previousHeight) > max(0, tolerance)
    }

    private static func validPositiveMeasurement(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

}

extension View {
    /// Applies an explicit viewport height so an initial zero-height proposal
    /// cannot collapse the menu body. Callers replace the default with a
    /// resolved height as content, footer, and screen measurements arrive.
    func lidlessMenuScrollViewport(
        height: CGFloat = MenuPopoverLayout.safeInitialBodyHeight
    ) -> some View {
        let height = height.isFinite && height >= 0
            ? height
            : MenuPopoverLayout.safeInitialBodyHeight
        return frame(height: height)
    }
}

/// A zero-size AppKit bridge that reports the visible height of the screen
/// containing the actual `MenuBarExtraWindow`.
///
/// Reading `NSScreen.main` here would follow keyboard focus and can therefore
/// select a different display than the one containing the open menu.
struct MenuWindowScreenMetricsProbe: NSViewRepresentable {
    let onVisibleFrameHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onVisibleFrameHeightChange: onVisibleFrameHeightChange)
    }

    func makeNSView(context: Context) -> MenuWindowScreenProbeView {
        let view = MenuWindowScreenProbeView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        context.coordinator.startObservingApplicationScreenChanges()
        context.coordinator.attach(to: view.window)
        return view
    }

    func updateNSView(_ nsView: MenuWindowScreenProbeView, context: Context) {
        context.coordinator.onVisibleFrameHeightChange = onVisibleFrameHeightChange
        context.coordinator.attach(to: nsView.window)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: MenuWindowScreenProbeView,
        context: Context
    ) -> CGSize? {
        .zero
    }

    static func dismantleNSView(
        _ nsView: MenuWindowScreenProbeView,
        coordinator: Coordinator
    ) {
        nsView.onWindowChange = nil
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator {
        var onVisibleFrameHeightChange: (CGFloat) -> Void

        private let notificationCenter: NotificationCenter
        private weak var observedWindow: NSWindow?
        private var windowScreenObserver: NSObjectProtocol?
        private var applicationScreenParametersObserver: NSObjectProtocol?
        private var lastScheduledVisibleHeight: CGFloat?
        private var publicationGeneration = 0

        init(
            notificationCenter: NotificationCenter = .default,
            onVisibleFrameHeightChange: @escaping (CGFloat) -> Void
        ) {
            self.notificationCenter = notificationCenter
            self.onVisibleFrameHeightChange = onVisibleFrameHeightChange
        }

        func startObservingApplicationScreenChanges() {
            guard applicationScreenParametersObserver == nil else { return }
            applicationScreenParametersObserver = notificationCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleCurrentVisibleHeightIfNeeded()
                }
            }
        }

        func attach(to window: NSWindow?) {
            if observedWindow !== window {
                if let windowScreenObserver {
                    notificationCenter.removeObserver(windowScreenObserver)
                }
                windowScreenObserver = nil
                observedWindow = window

                if let window {
                    windowScreenObserver = notificationCenter.addObserver(
                        forName: NSWindow.didChangeScreenNotification,
                        object: window,
                        queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor in
                            self?.scheduleCurrentVisibleHeightIfNeeded()
                        }
                    }
                }
            }

            scheduleCurrentVisibleHeightIfNeeded()
        }

        func stopObserving() {
            if let windowScreenObserver {
                notificationCenter.removeObserver(windowScreenObserver)
            }
            if let applicationScreenParametersObserver {
                notificationCenter.removeObserver(applicationScreenParametersObserver)
            }
            windowScreenObserver = nil
            applicationScreenParametersObserver = nil
            observedWindow = nil
            publicationGeneration += 1
        }

        private func scheduleCurrentVisibleHeightIfNeeded() {
            guard let visibleHeight = observedWindow?.screen?.visibleFrame.height,
                  MenuPopoverLayout.shouldPublishScreenVisibleHeight(
                      visibleHeight,
                      after: lastScheduledVisibleHeight
                  )
            else { return }

            lastScheduledVisibleHeight = visibleHeight
            publicationGeneration += 1
            let scheduledGeneration = publicationGeneration

            // Publishing on the next main-loop turn avoids mutating SwiftUI
            // state from inside `updateNSView` during an active layout pass.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.publicationGeneration == scheduledGeneration else {
                    return
                }
                self.onVisibleFrameHeightChange(visibleHeight)
            }
        }
    }
}

/// Lets the representable notice when SwiftUI moves it into a different menu
/// window; the coordinator then rebinds the window-specific screen observer.
final class MenuWindowScreenProbeView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 0, height: 0)
    }
}
