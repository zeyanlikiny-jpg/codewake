import Foundation

public enum AudioInputSlot: String, Codable, CaseIterable, Sendable {
    case primary
    case secondary
}

/// A persisted reference to an audio input. Core Audio object IDs are process-
/// local and transient, so only the device UID is used as identity.
public struct AudioInputSelection: Codable, Equatable, Sendable {
    public var uid: String
    public var lastKnownName: String

    public init(uid: String, lastKnownName: String) {
        self.uid = uid
        self.lastKnownName = lastKnownName
    }

    fileprivate func sanitized() -> AudioInputSelection? {
        let cleanUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUID.isEmpty else { return nil }

        return AudioInputSelection(
            uid: cleanUID,
            lastKnownName: lastKnownName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

public struct AudioInputSwitchConfiguration: Codable, Equatable, Sendable {
    public var primary: AudioInputSelection?
    public var secondary: AudioInputSelection?

    public static let empty = AudioInputSwitchConfiguration(primary: nil, secondary: nil)

    public init(primary: AudioInputSelection?, secondary: AudioInputSelection?) {
        self.primary = primary
        self.secondary = secondary
    }

    /// Repairs preferences loaded from disk without guessing replacement
    /// devices. Primary wins when corrupted preferences contain the same UID in
    /// both slots.
    public func sanitized() -> AudioInputSwitchConfiguration {
        let cleanPrimary = primary?.sanitized()
        var cleanSecondary = secondary?.sanitized()
        if cleanSecondary?.uid == cleanPrimary?.uid {
            cleanSecondary = nil
        }
        return AudioInputSwitchConfiguration(
            primary: cleanPrimary,
            secondary: cleanSecondary
        )
    }
}

struct AudioInputSwitchRoute: Equatable, Sendable {
    /// The default input visible when the UI resolved this route. Keeping it in
    /// the request prevents a queued click from overwriting a newer manual
    /// input choice, while `target` remains the one and only A/B destination.
    let fromUID: String?
    let target: AudioInputSelection
    let slot: AudioInputSlot

    var selection: AudioInputSelection { target }

    init(fromUID: String?, target: AudioInputSelection, slot: AudioInputSlot) {
        self.fromUID = fromUID
        self.target = target
        self.slot = slot
    }

    /// Source-compatible convenience for pure routing expectations. Runtime
    /// switch requests should use the frozen-source initializer above.
    init(slot: AudioInputSlot, selection: AudioInputSelection) {
        self.init(fromUID: nil, target: selection, slot: slot)
    }

    static func == (lhs: AudioInputSwitchRoute, rhs: AudioInputSwitchRoute) -> Bool {
        // Routing identity is the selected slot/device. `fromUID` is a
        // preflight guard, not part of the user-visible A/B route.
        lhs.slot == rhs.slot && lhs.target == rhs.target
    }
}

enum AudioInputSwitchRouter {
    /// A -> B and B -> A even when that exact target is offline, allowing the
    /// caller to report the unavailable slot without silently choosing another
    /// device. From any other current input, prefer an online A, then online B;
    /// when neither is online, retain A as the deterministic failed target.
    static func route(
        configuration: AudioInputSwitchConfiguration,
        currentUID: String?,
        availableUIDs: Set<String>
    ) -> AudioInputSwitchRoute? {
        let configuration = configuration.sanitized()
        guard let primary = configuration.primary,
              let secondary = configuration.secondary else {
            return nil
        }

        if currentUID == primary.uid {
            return AudioInputSwitchRoute(
                fromUID: currentUID,
                target: secondary,
                slot: .secondary
            )
        }
        if currentUID == secondary.uid {
            return AudioInputSwitchRoute(
                fromUID: currentUID,
                target: primary,
                slot: .primary
            )
        }
        if !availableUIDs.contains(primary.uid), availableUIDs.contains(secondary.uid) {
            return AudioInputSwitchRoute(
                fromUID: currentUID,
                target: secondary,
                slot: .secondary
            )
        }
        return AudioInputSwitchRoute(
            fromUID: currentUID,
            target: primary,
            slot: .primary
        )
    }
}
