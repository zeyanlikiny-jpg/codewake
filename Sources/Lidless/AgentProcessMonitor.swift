import Darwin
import Foundation

/// Process evidence is deliberately secondary to lifecycle hooks. It can prove
/// that a known agent process still exists or has consumed more CPU, but low CPU
/// is never interpreted as completion (agents often wait on tools or approval).
struct AgentProcessIdentity: Hashable, Sendable {
    let pid: pid_t
    let startTimeMicroseconds: UInt64
}

struct AgentProcessSnapshot: Equatable, Sendable {
    let identity: AgentProcessIdentity
    let parentPID: pid_t
    let executableName: String
    let executionSurface: AgentExecutionSurface
    /// Optional diagnostics only. A task-info read can race process teardown or
    /// be denied even after path/name reads succeeded; that must not erase valid
    /// process-presence evidence.
    let cumulativeCPUNanoseconds: UInt64?
}

/// Product surface that launched a real lifecycle-hook bridge. Codex Desktop
/// embeds the same `codex` executable name as the standalone CLI, so the
/// executable path is used only in memory to distinguish them. Paths never
/// enter the hook payload, persisted recovery state, or UI.
enum AgentExecutionSurface: String, Equatable, Sendable {
    case codexDesktop
    case codexCLI
    case claudeCodeCLI

    var provider: AgentProcessProvider {
        switch self {
        case .codexDesktop, .codexCLI: return .codex
        case .claudeCodeCLI: return .claude
        }
    }

    /// A long-lived Codex Desktop app-server process is presence evidence for a
    /// hook event, not evidence that any task is active. Only standalone CLIs
    /// may create the process-fallback's anonymous discovery session.
    var supportsStandaloneDiscovery: Bool {
        self != .codexDesktop
    }
}

/// A successful system-wide PID enumeration plus the agent snapshots that were
/// readable during it. `nil` means the enumeration itself failed; callers must
/// not reinterpret that as every previously observed process exiting.
struct AgentProcessScan: Sendable {
    let snapshots: [AgentProcessSnapshot]
    let listedPIDs: Set<pid_t>
    let startTimesByPID: [pid_t: UInt64]
}

/// Monotonic token shared by manual and periodic scans. libproc work may finish
/// out of order; only the newest request may mutate process/session state.
struct AgentProcessScanGenerationGate {
    private(set) var current: UInt64 = 0

    mutating func begin() -> UInt64 {
        current &+= 1
        return current
    }

    mutating func invalidate() {
        current &+= 1
    }

    func accepts(_ generation: UInt64) -> Bool {
        generation == current
    }
}

/// Codex product surfaces observed by one complete process scan. This is only
/// presence information: neither a Desktop/CLI process nor its CPU usage says
/// that a Codex task is working, waiting, or complete.
enum CodexProcessPresence: String, Equatable, Sendable {
    case desktopOnly
    case cliOnly
    case both
    case notDetected
    case scanFailed

    init(scan: AgentProcessScan?) {
        guard let scan else {
            self = .scanFailed
            return
        }

        self.init(snapshots: scan.snapshots)
    }

    init(snapshots: [AgentProcessSnapshot]) {

        var desktopDetected = false
        var cliDetected = false
        for snapshot in snapshots {
            switch snapshot.executionSurface {
            case .codexDesktop:
                desktopDetected = true
            case .codexCLI:
                cliDetected = true
            case .claudeCodeCLI:
                continue
            }
        }

        switch (desktopDetected, cliDetected) {
        case (true, true): self = .both
        case (true, false): self = .desktopOnly
        case (false, true): self = .cliOnly
        case (false, false): self = .notDetected
        }
    }
}

extension AgentProcessScan {
    var codexPresence: CodexProcessPresence {
        CodexProcessPresence(scan: self)
    }
}

/// Associates privacy-opaque hook sessions with agent process identities learned
/// from the Unix-socket peer's parent chain. A session is ended only after every
/// associated identity is absent from two consecutive complete process scans;
/// transient libproc gaps therefore cannot manufacture completion.
struct AgentProcessAssociationTracker {
    private var identitiesBySession: [AgentSessionKey: Set<AgentProcessIdentity>] = [:]
    private var consecutiveMissesBySession: [AgentSessionKey: [AgentProcessIdentity: Int]] = [:]

    mutating func associate(_ identity: AgentProcessIdentity, with session: AgentSessionKey) {
        identitiesBySession[session, default: []].insert(identity)
        consecutiveMissesBySession[session, default: [:]][identity] = 0
    }

    mutating func remove(session: AgentSessionKey) {
        identitiesBySession.removeValue(forKey: session)
        consecutiveMissesBySession.removeValue(forKey: session)
    }

    mutating func observe(currentIdentities: Set<AgentProcessIdentity>) -> Set<AgentSessionKey> {
        var ended: Set<AgentSessionKey> = []
        for session in Array(identitiesBySession.keys) {
            guard var identities = identitiesBySession[session] else { continue }
            var misses = consecutiveMissesBySession[session] ?? [:]
            for identity in identities {
                if currentIdentities.contains(identity) {
                    misses[identity] = 0
                    continue
                }
                let count = (misses[identity] ?? 0) + 1
                misses[identity] = count
                if count >= 2 {
                    identities.remove(identity)
                    misses.removeValue(forKey: identity)
                }
            }
            if identities.isEmpty {
                identitiesBySession.removeValue(forKey: session)
                consecutiveMissesBySession.removeValue(forKey: session)
                ended.insert(session)
            } else {
                identitiesBySession[session] = identities
                consecutiveMissesBySession[session] = misses
            }
        }
        return ended
    }
}

enum AgentProcessProvider: String, Equatable, Sendable {
    case codex
    case claude

    static func detect(executableName: String) -> AgentProcessProvider? {
        let name = executableName.lowercased()
        if name == "codex" || name == "codex-cli"
            || (name.hasPrefix("codex-") && name.hasSuffix("-apple-darwin")) {
            return .codex
        }
        if name == "claude" { return .claude }
        return nil
    }

    static func executionSurface(
        executableName: String,
        executablePath: String,
        parentExecutablePath: String?
    ) -> AgentExecutionSurface? {
        guard let provider = detect(executableName: executableName) else { return nil }
        let embeddedApp = containingAppBundle(executablePath)
        switch provider {
        case .codex:
            // `command -v codex` may itself point into ChatGPT.app. That binary
            // is still the CLI when Terminal/zsh launches it. Treat it as the
            // Desktop surface only when its parent belongs to the same outer app
            // bundle; this matches the Desktop app-server process tree without
            // retaining or transmitting either path.
            let parentApp = parentExecutablePath.flatMap(containingAppBundle)
            return embeddedApp.map(isCodexDesktopBundle) == true
                && embeddedApp == parentApp
                ? .codexDesktop
                : .codexCLI
        case .claude:
            // Claude Desktop is not Claude Code and must never become an AI
            // wake source merely because an embedded helper is named `claude`.
            return embeddedApp == nil ? .claudeCodeCLI : nil
        }
    }

    private static func containingAppBundle(_ path: String) -> String? {
        let lowered = path.lowercased()
        guard let marker = lowered.range(of: ".app/contents/") else { return nil }
        return String(lowered[..<marker.lowerBound]) + ".app"
    }

    private static func isCodexDesktopBundle(_ path: String) -> Bool {
        let bundleName = URL(fileURLWithPath: path).lastPathComponent
        return bundleName == "chatgpt.app" || bundleName == "codex.app"
    }
}

enum AgentProcessMonitor {
    /// Resolve the short-lived hook bridge's nearest agent ancestor without
    /// adding PID/path data to the privacy-minimized socket payload.
    static func nearestAgentAncestor(of pid: pid_t, maximumDepth: Int = 12)
        -> AgentProcessSnapshot? {
        var current = pid
        var visited: Set<pid_t> = []
        for _ in 0..<max(1, maximumDepth) {
            guard current > 1, visited.insert(current).inserted,
                  let basic = basicInfo(pid: current) else { return nil }
            if let agent = snapshot(pid: current, basic: basic) { return agent }
            guard basic.parentPID != current else { return nil }
            current = basic.parentPID
        }
        return nil
    }

    /// Uses libproc instead of shelling out to `ps`, retaining PID start time so
    /// a recycled PID can never be mistaken for the previous agent process.
    static func scan() -> AgentProcessScan? {
        let requestedCapacity = proc_listallpids(nil, 0)
        guard requestedCapacity > 0 else { return nil }
        var capacity = max(Int(requestedCapacity) + 64, 256)
        var completePIDs: [pid_t]?
        for _ in 0..<4 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes { bytes -> Int32 in
                proc_listallpids(bytes.baseAddress, Int32(bytes.count))
            }
            guard count > 0 else { return nil }
            if Int(count) < capacity {
                completePIDs = Array(pids.prefix(Int(count)))
                break
            }
            capacity = min(capacity * 2, 1_048_576)
        }
        guard let completePIDs else { return nil }

        let listedPIDs = Set(completePIDs.filter { $0 > 0 })
        var starts: [pid_t: UInt64] = [:]
        var snapshots: [AgentProcessSnapshot] = []
        for pid in listedPIDs {
            guard let basic = basicInfo(pid: pid) else { continue }
            starts[pid] = basic.startTimeMicroseconds
            if let snapshot = snapshot(pid: pid, basic: basic) {
                snapshots.append(snapshot)
            }
        }
        return AgentProcessScan(
            snapshots: snapshots,
            listedPIDs: listedPIDs,
            startTimesByPID: starts
        )
    }

    private struct BasicProcessInfo {
        let parentPID: pid_t
        let startTimeMicroseconds: UInt64
    }

    private static func basicInfo(pid: pid_t) -> BasicProcessInfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let infoSize = MemoryLayout<proc_bsdinfo>.size
        let readInfo = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(infoSize))
        }
        guard readInfo == infoSize else { return nil }
        return BasicProcessInfo(
            parentPID: pid_t(info.pbi_ppid),
            startTimeMicroseconds: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
        )
    }

    private static func snapshot(pid: pid_t, basic: BasicProcessInfo) -> AgentProcessSnapshot? {
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 else { return nil }
        let name = String(cString: nameBuffer)
        guard AgentProcessProvider.detect(executableName: name) != nil else { return nil }

        // libproc's recommended pid-path buffer macro is not imported by every
        // Swift SDK; four PATH_MAX buffers matches its Darwin definition.
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }
        let path = String(cString: pathBuffer)
        guard let executionSurface = AgentProcessProvider.executionSurface(
            executableName: name,
            executablePath: path,
            parentExecutablePath: executablePath(pid: basic.parentPID)
        ) else { return nil }

        var task = proc_taskinfo()
        let taskSize = MemoryLayout<proc_taskinfo>.size
        let readTask = withUnsafeMutablePointer(to: &task) {
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, Int32(taskSize))
        }
        let cumulativeCPUNanoseconds = readTask == taskSize
            ? task.pti_total_user &+ task.pti_total_system
            : nil

        return AgentProcessSnapshot(
            identity: AgentProcessIdentity(
                pid: pid,
                startTimeMicroseconds: basic.startTimeMicroseconds
            ),
            parentPID: basic.parentPID,
            executableName: name,
            executionSurface: executionSurface,
            cumulativeCPUNanoseconds: cumulativeCPUNanoseconds
        )
    }

    private static func executablePath(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
