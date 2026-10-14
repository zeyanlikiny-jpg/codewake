import AppKit
import Combine
import CoreGraphics
import Foundation

/// The external-display topology visible to the logged-in user session.
///
/// This is presentation state only. The privileged helper still performs its
/// own topology check immediately before a completion-triggered sleep request.
enum ExternalDisplayState: Equatable {
    case connected(count: Int, names: [String])
    case disconnected
    case unknown
}

/// Injectable boundary around CoreGraphics and AppKit display discovery.
/// Keeping the three operations together lets tests model WindowServer errors,
/// mirrored displays, and screens without a user-facing name independently.
@MainActor
struct DisplayTopologyProbe {
    let onlineDisplayIDs: () throws -> [CGDirectDisplayID]
    let isBuiltin: (CGDirectDisplayID) -> Bool
    let displayNamesByID: () -> [CGDirectDisplayID: String]

    static var system: DisplayTopologyProbe {
        DisplayTopologyProbe(
            onlineDisplayIDs: {
                var count: UInt32 = 0
                guard CGGetOnlineDisplayList(0, nil, &count) == .success else {
                    throw SystemDisplayProbeError.coreGraphicsFailure
                }
                guard count > 0 else { return [] }

                var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
                var populated: UInt32 = 0
                guard CGGetOnlineDisplayList(count, &displayIDs, &populated) == .success else {
                    throw SystemDisplayProbeError.coreGraphicsFailure
                }
                return Array(displayIDs.prefix(Int(populated)))
            },
            isBuiltin: { CGDisplayIsBuiltin($0) != 0 },
            displayNamesByID: {
                var names: [CGDirectDisplayID: String] = [:]
                let displayNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

                for screen in NSScreen.screens {
                    guard let number = screen.deviceDescription[displayNumberKey] as? NSNumber else {
                        continue
                    }
                    let name = screen.localizedName.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    guard !name.isEmpty else { continue }
                    names[CGDirectDisplayID(number.uint32Value)] = name
                }
                return names
            }
        )
    }

    private enum SystemDisplayProbeError: Error {
        case coreGraphicsFailure
    }
}

/// Maintains a live external-display snapshot for the menu-bar app.
///
/// The initial value is probed synchronously, `currentState()` supports an
/// explicit refresh whenever the menu opens, and AppKit screen-change
/// notifications keep the value current while the app remains resident.
@MainActor
final class DisplayTopologyMonitor: ObservableObject {
    @Published private(set) var state: ExternalDisplayState

    private let probe: DisplayTopologyProbe
    private let notificationCenter: NotificationCenter
    private var screenParametersObserver: NSObjectProtocol?

    convenience init(
        notificationCenter: NotificationCenter = .default,
        observesScreenChanges: Bool = true
    ) {
        self.init(
            probe: .system,
            notificationCenter: notificationCenter,
            observesScreenChanges: observesScreenChanges
        )
    }

    init(
        probe: DisplayTopologyProbe,
        notificationCenter: NotificationCenter = .default,
        observesScreenChanges: Bool = true
    ) {
        self.probe = probe
        self.notificationCenter = notificationCenter
        state = Self.resolve(using: probe)

        guard observesScreenChanges else { return }
        screenParametersObserver = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.currentState()
            }
        }
    }

    deinit {
        if let screenParametersObserver {
            notificationCenter.removeObserver(screenParametersObserver)
        }
    }

    /// Re-probes the current topology, publishes it, and returns the same value.
    /// Calling this when the popover opens prevents a notification missed during
    /// launch or display reconfiguration from leaving stale UI behind.
    @discardableResult
    func currentState() -> ExternalDisplayState {
        let current = Self.resolve(using: probe)
        state = current
        return current
    }

    private static func resolve(using probe: DisplayTopologyProbe) -> ExternalDisplayState {
        let onlineDisplayIDs: [CGDirectDisplayID]
        do {
            onlineDisplayIDs = try probe.onlineDisplayIDs()
        } catch {
            return .unknown
        }

        // A normal WindowServer session always exposes at least one endpoint.
        // A successful empty result is therefore not evidence of disconnection.
        guard !onlineDisplayIDs.isEmpty else { return .unknown }

        var seen = Set<CGDirectDisplayID>()
        let uniqueDisplayIDs = onlineDisplayIDs.filter { seen.insert($0).inserted }
        let externalDisplayIDs = uniqueDisplayIDs.filter { !probe.isBuiltin($0) }
        guard !externalDisplayIDs.isEmpty else { return .disconnected }

        let namesByID = probe.displayNamesByID()
        let names = externalDisplayIDs.compactMap { displayID -> String? in
            guard let rawName = namesByID[displayID] else { return nil }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }

        return .connected(count: externalDisplayIDs.count, names: names)
    }
}
