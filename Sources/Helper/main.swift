import Foundation

// Entry point for the privileged helper (a LaunchDaemon running as root).
// It listens on a Mach service and serves LidlessHelperProtocol over XPC. The
// Mach service name, exact peer identity, and journal location are handed in by
// the generated LaunchDaemon plist. Environment injection keeps Debug/Release
// builds isolated and makes the default Kenny identity independent of upstream
// signing values.
let environment = ProcessInfo.processInfo.environment
let machLabel = environment[LidlessHelper.machLabelEnvKey]
    ?? LidlessHelper.runtimeFallbackLabel
let peerIdentity = LidlessHelper.configuredPeerIdentity(
    environment: environment,
    machLabel: machLabel
)
let journalStore = HelperLeaseJournalStore(
    fileURL: HelperLeaseRuntime.journalFileURL(environment: environment)
)
let service = HelperService(
    journalStore: journalStore,
    bootID: HelperLeaseRuntime.currentBootID(environment: environment)
)
let delegate = HelperListenerDelegate(service: service, peerIdentity: peerIdentity)
let listener = NSXPCListener(machServiceName: machLabel)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
