import Darwin
import Foundation

private let maximumRuntime: TimeInterval = 1.0

private func providerFromArguments() -> HookProvider? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--provider"),
          arguments.indices.contains(index + 1) else { return nil }
    switch arguments[index + 1] {
    case "codex": return .codex
    case "claude": return .claudeCode
    default: return nil
    }
}

private func readStandardInput(limit: Int, deadline: TimeInterval) -> Data? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while data.count <= limit {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return nil }
        var pollDescriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(min(remaining * 1_000, Double(Int32.max)).rounded(.up))
        let pollResult = Darwin.poll(&pollDescriptor, 1, milliseconds)
        if pollResult < 0, errno == EINTR { continue }
        guard pollResult > 0,
              (pollDescriptor.revents & Int16(POLLIN | POLLHUP)) != 0 else { return nil }

        let count = Darwin.read(STDIN_FILENO, &buffer, min(buffer.count, limit + 1 - data.count))
        if count > 0 {
            data.append(buffer, count: count)
            continue
        }
        if count < 0, errno == EINTR { continue }
        if count == 0 { return data }
        return nil
    }
    return nil
}

private func configuredSocketURL() -> URL {
    if let path = ProcessInfo.processInfo.environment["LIDLESS_AI_SOCKET_PATH"],
       path.hasPrefix("/") {
        return URL(fileURLWithPath: path, isDirectory: false)
    }
    return HookIntegrationPaths.socketURL(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
}

private func configuredBundleIdentifier() -> String {
    let releaseID = "com.kenny.lidlessai"
    let developmentID = "com.kenny.lidlessai.dev"
    let configured = ProcessInfo.processInfo.environment["LIDLESS_AI_APP_BUNDLE_ID"]
    return configured == developmentID ? developmentID : releaseID
}

private func launchApplication(bundleIdentifier: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", "-b", bundleIdentifier]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

/// Launch the previously configured Codex notify command without waiting for
/// it. Relay parsing/sanitizing and downstream failures are deliberately
/// independent: a malformed Lidless payload can never suppress Computer Use,
/// and a failing Computer Use command can never suppress the sleep event.
private func forwardNotification(arguments: [String], rawPayload: String) {
    guard let executable = arguments.first, !executable.isEmpty else { return }
    let process = Process()
    if executable.hasPrefix("/") {
        process.executableURL = URL(fileURLWithPath: executable, isDirectory: false)
        process.arguments = Array(arguments.dropFirst()) + [rawPayload]
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env", isDirectory: false)
        process.arguments = arguments + [rawPayload]
    }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

private func sendWithLaunchFallback(
    _ payload: Data,
    socketURL: URL,
    bundleIdentifier: String,
    deadline: TimeInterval
) {
    if HookBridgeSocketClient.send(payload, to: socketURL, deadline: deadline) { return }

    guard ProcessInfo.processInfo.systemUptime < deadline else { return }
    launchApplication(bundleIdentifier: bundleIdentifier)
    while true {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return }
        usleep(useconds_t(min(20_000, max(1, Int(remaining * 1_000_000)))))
        guard ProcessInfo.processInfo.systemUptime < deadline else { return }
        if HookBridgeSocketClient.send(payload, to: socketURL, deadline: deadline) { return }
    }
}

private func runBridge() {
    let startedAt = ProcessInfo.processInfo.systemUptime
    let deadline = startedAt + maximumRuntime
    guard let provider = providerFromArguments(),
          let input = readStandardInput(
              limit: HookEventSanitizer.maximumInputBytes,
              deadline: deadline
          ),
          let payload = HookEventSanitizer.encodedPayload(from: input, provider: provider) else {
        return
    }

    sendWithLaunchFallback(
        payload,
        socketURL: configuredSocketURL(),
        bundleIdentifier: configuredBundleIdentifier(),
        deadline: deadline
    )
}

private func runNotifyRelay() {
    let deadline = ProcessInfo.processInfo.systemUptime + maximumRuntime
    guard let invocation = CodexNotifyRelayInvocation.parse(
        runtimeArguments: Array(CommandLine.arguments.dropFirst())
    ) else { return }

    // Preserve the exact raw JSON argv string. No decode/re-encode occurs on the
    // forwarding path, including when Lidless rejects a future payload schema.
    forwardNotification(
        arguments: invocation.forwardedArguments,
        rawPayload: invocation.rawPayloadArgument
    )

    guard let payload = CodexNotifyEventSanitizer.encodedPayload(
        from: invocation.rawPayloadArgument
    ) else { return }
    sendWithLaunchFallback(
        payload,
        socketURL: URL(fileURLWithPath: invocation.socketPath, isDirectory: false),
        bundleIdentifier: invocation.appBundleIdentifier,
        deadline: deadline
    )
}

// Hook failures must never interrupt an AI turn. Every path is intentionally
// silent and the process exits 0, including malformed input or unavailable app.
if CommandLine.arguments.dropFirst().first == "--notify-relay" {
    runNotifyRelay()
} else {
    runBridge()
}
