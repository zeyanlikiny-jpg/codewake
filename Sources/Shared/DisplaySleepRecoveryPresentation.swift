import Foundation

extension AllDisplaysSleepPreparationFailure {
    /// Canonical keys are localized at the presentation boundary.
    var message: String {
        switch self {
        case .builtInUnavailable:
            return "The built-in display is not ready. Open the lid and wait for brightness to recover, then try again."
        case .brightnessUnavailable:
            return "Built-in brightness recovery failed. Raise the built-in display brightness and try again."
        case .topologyUnknown:
            return "Couldn’t confirm the lid or display state. Wait for the displays to reconnect and try again."
        case .invalidRecoveryRecord:
            return "The saved brightness recovery record could not be verified. It has been preserved; display sleep was not requested."
        case .recoveryUnavailable:
            return "The brightness recovery process is unavailable. Open the lid to restore brightness before trying again."
        case .recoveryFailed:
            return "Built-in display recovery encountered an error. The recovery record has been preserved."
        case .timedOut:
            return "Built-in display recovery is taking too long. Wait for brightness to recover and try again."
        }
    }
}

enum BuiltInDisplayRecoveryPresentation {
    static func message(
        status: DisplayBlackoutResponseStatus?,
        failure: AllDisplaysSleepPreparationFailure?,
        topology: AllDisplaysSleepTopology
    ) -> String {
        if let failure { return failure.message }
        switch status {
        case .builtInUnavailable:
            if topology.permitsDeferredBuiltInRecovery {
                return "The lid is closed. Built-in brightness will recover when opened; external displays can still be turned off."
            }
            return "The built-in display is offline. Brightness will be restored when it reconnects."
        case .brightnessUnavailable:
            return AllDisplaysSleepPreparationFailure.brightnessUnavailable.message
        case .topologyUnknown:
            return AllDisplaysSleepPreparationFailure.topologyUnknown.message
        default:
            return "Built-in display brightness recovery is pending."
        }
    }
}
