import CoreGraphics
import Foundation
import IOKit

/// Preparing a one-shot display sleep must not discard an outstanding built-in
/// brightness recovery transaction. Deferral is a successful, distinct state.
enum AllDisplaysSleepPreparation: Equatable {
    case ready
    case deferredBuiltInRecovery
    case blocked(AllDisplaysSleepPreparationFailure)
}

enum AllDisplaysSleepPreparationFailure: String, Equatable {
    case builtInUnavailable
    case brightnessUnavailable
    case topologyUnknown
    case invalidRecoveryRecord
    case recoveryUnavailable
    case recoveryFailed
    case timedOut
}

/// Complete online-display identity and lid state, independent of the menu's
/// external-display count. Unknown lid state is normal on desktop Macs, but can
/// never authorize deferred restoration of a notebook's built-in display.
enum AllDisplaysSleepTopology: Equatable {
    struct Display: Equatable {
        var id: UInt32
        var isBuiltIn: Bool
    }

    case unknown
    case known(lidClosed: Bool?, displays: [Display])

    struct Probe {
        var onlineDisplays: () -> [Display]?
        var lidClosed: () -> Bool?
    }

    var permitsDeferredBuiltInRecovery: Bool {
        guard case .known(true, let displays) = self, isKnown else { return false }
        return displays.allSatisfy { !$0.isBuiltIn }
    }

    /// Validate injected values too: a caller cannot turn an empty, duplicated,
    /// or truncated result into authoritative topology merely by using .known.
    var isKnown: Bool {
        guard case .known(_, let displays) = self else { return false }
        return Self.validated(displays) != nil
    }

    static func system() -> Self {
        resolve(using: Probe(
            onlineDisplays: {
                var ids = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
                var count: UInt32 = 0
                guard CGGetOnlineDisplayList(capacity, &ids, &count) == .success,
                      count < capacity else { return nil }
                return ids.prefix(Int(count)).map {
                    Display(id: $0, isBuiltIn: CGDisplayIsBuiltin($0) != 0)
                }
            },
            lidClosed: {
                let root = IOServiceGetMatchingService(
                    kIOMainPortDefault,
                    IOServiceMatching("IOPMrootDomain")
                )
                guard root != IO_OBJECT_NULL else { return nil }
                defer { IOObjectRelease(root) }
                return IORegistryEntryCreateCFProperty(
                    root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? Bool
            }
        ))
    }

    /// Bracket both complete display reads with lid reads. An observed change
    /// during the probe is uncertainty, never evidence that recovery is safe.
    static func resolve(using probe: Probe) -> Self {
        let lidBefore = probe.lidClosed()
        guard let before = validated(probe.onlineDisplays()),
              let after = validated(probe.onlineDisplays()) else { return .unknown }
        let lidAfter = probe.lidClosed()
        guard before == after, lidBefore == lidAfter else { return .unknown }
        return .known(lidClosed: lidAfter, displays: after)
    }

    private static let capacity: UInt32 = 64

    private static func validated(_ displays: [Display]?) -> [Display]? {
        guard let displays, !displays.isEmpty, displays.count < Int(capacity),
              displays.allSatisfy({ $0.id != 0 }),
              Set(displays.map(\.id)).count == displays.count else { return nil }
        return displays.sorted { $0.id < $1.id }
    }
}
