import AppKit
import SwiftUI

/// AppKit's terminate-later handshake is required to make every normal exit
/// wait for Lidless to persist tombstones and release its durable helper lease.
/// A will-terminate notification cannot delay process death.
@MainActor
final class LidlessAppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?
    private var terminationInProgress = false
    private var terminationApproved = false
    private lazy var logoDoubleClickController = MenuBarLogoDoubleClickController {
        [weak self] in
        guard let state = self?.state,
              state.canToggleBuiltInDisplayBlackout,
              !state.builtInDisplayBlackoutActive else { return }
        MenuBarExtraPanel.dismiss()
        state.toggleBuiltInDisplayBlackout()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        logoDoubleClickController.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        logoDoubleClickController.stop()
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        if terminationApproved { return .terminateNow }
        guard let state else { return .terminateNow }
        guard !terminationInProgress else { return .terminateLater }

        terminationInProgress = true
        state.prepareForApplicationTermination { [weak self, weak sender] in
            // The no-helper path may complete synchronously while this delegate
            // call is still deciding to return `.terminateLater`. Queue the reply
            // so AppKit always receives it after that return value.
            DispatchQueue.main.async {
                guard let self, let sender else { return }
                self.terminationApproved = true
                self.terminationInProgress = false
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

@main
struct LidlessApp: App {
    @NSApplicationDelegateAdaptor(LidlessAppDelegate.self) private var appDelegate
    @StateObject private var state: AppState

    init() {
        let state = AppState()
        _state = StateObject(wrappedValue: state)
        appDelegate.state = state
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
                .environment(\.locale, state.appLanguage.locale)
        } label: {
            LidlessMenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.window)
        // No `Settings` scene: it doesn't reliably surface in an LSUIElement app
        // (issue #22). `AppState.showSettings()` presents it via AppKit instead.
    }
}

@MainActor
private struct LidlessMenuBarLabel: View {
    @ObservedObject var state: AppState

    private var presentation: MenuBarIconPresentation {
        state.activityPresentation
    }

    var body: some View {
        icon
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Double-click to turn off the built-in display.")
            .help("Double-click to turn off the built-in display.")
            .environment(\.locale, state.appLanguage.locale)
    }

    private var icon: Image {
        switch presentation {
        case .normal:
            return Image(state.isEnabled ? "MenubarLaptopActive" : "MenubarLaptop")
                .renderingMode(.template)
        case .manualActive, .working:
            return Image("MenubarLaptopWorking")
                .renderingMode(.original)
        case .attention:
            return Image("MenubarLaptopAttention")
                .renderingMode(.original)
        }
    }

    private var accessibilityLabel: Text {
        switch presentation {
        case .manualActive:
            return Text("CodeWake, Mac awake, manual hold active")
        case .working:
            return Text("CodeWake, Mac awake, Codex working")
        case .attention:
            return Text("CodeWake, Mac awake, Codex waiting for input or confirming completion")
        case .normal:
            return state.isEnabled
                ? Text("CodeWake, Mac awake")
                : Text("CodeWake, Normal sleep")
        }
    }
}
