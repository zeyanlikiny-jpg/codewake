import Darwin
import Foundation

/// A tiny local-only transport for lifecycle hook events.
///
/// The socket lives inside a mode-0700 directory and is mode 0600. Each client
/// sends one newline-delimited JSON object and disconnects. Payloads over 64 KiB
/// are rejected before decoding so malformed hooks cannot grow app memory.
final class AgentEventSocketServer {
    static let maximumPayloadBytes = 64 * 1024

    enum ServerError: LocalizedError {
        case pathTooLong
        case unsafeRuntimeDirectory
        case unsafeExistingPath
        case posix(operation: String, code: Int32)

        var errorDescription: String? {
            switch self {
            case .pathTooLong:
                return "The AI event socket path is too long."
            case .unsafeRuntimeDirectory:
                return "The AI event runtime directory has unsafe ownership or permissions."
            case .unsafeExistingPath:
                return "The AI event socket path is occupied by a non-socket file."
            case .posix(let operation, let code):
                return "\(operation) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    let socketURL: URL
    private let queue = DispatchQueue(label: "com.kenny.lidlessai.agent-events")
    private let clientQueue = DispatchQueue(
        label: "com.kenny.lidlessai.agent-event-clients",
        attributes: .concurrent
    )
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var eventHandler: ((Data, AgentProcessSnapshot?) -> Void)?
    /// Identity of the pathname created by this instance. During app relaunch,
    /// the new process deliberately replaces the old socket. The old process
    /// must not unlink that newer inode from its later `deinit`.
    private var boundSocketIdentity: (device: dev_t, inode: ino_t)?

    init(socketURL: URL = AgentEventSocketServer.defaultSocketURL()) {
        self.socketURL = socketURL
    }

    static func defaultSocketURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        HookIntegrationPaths.socketURL(
            homeDirectory: home,
            appBundleIdentifier: Bundle.main.bundleIdentifier
                ?? HookIntegrationPaths.releaseAppBundleIdentifier
        )
    }

    func start(onEvent: @escaping (Data) -> Void) throws {
        try startServer { data, _ in onEvent(data) }
    }

    func start(onEventWithProcess: @escaping (Data, AgentProcessSnapshot?) -> Void) throws {
        try startServer(onEventWithProcess)
    }

    private func startServer(_ onEvent: @escaping (Data, AgentProcessSnapshot?) -> Void) throws {
        guard source == nil else { return }
        eventHandler = onEvent

        let directory = socketURL.deletingLastPathComponent()
        var directoryInfo = stat()
        if Darwin.lstat(directory.path, &directoryInfo) != 0 {
            guard errno == ENOENT else {
                throw ServerError.posix(operation: "lstat runtime directory", code: errno)
            }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard Darwin.lstat(directory.path, &directoryInfo) == 0 else {
                throw ServerError.posix(operation: "lstat runtime directory", code: errno)
            }
        }
        guard (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == Darwin.geteuid(),
              (directoryInfo.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            throw ServerError.unsafeRuntimeDirectory
        }
        guard Darwin.chmod(directory.path, 0o700) == 0 else {
            throw ServerError.posix(operation: "chmod directory", code: errno)
        }
        try removeStaleSocketIfSafe()

        let pathBytes = socketURL.path.utf8CString
        var address = sockaddr_un()
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ServerError.pathTooLong
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.posix(operation: "socket", code: errno) }
        descriptor = fd

        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
            tuplePointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { chars in
                for (index, byte) in pathBytes.enumerated() { chars[index] = byte }
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            closeDescriptor()
            throw ServerError.posix(operation: "bind", code: code)
        }
        var boundInfo = stat()
        guard Darwin.lstat(socketURL.path, &boundInfo) == 0,
              (boundInfo.st_mode & S_IFMT) == S_IFSOCK else {
            let code = errno
            closeDescriptor()
            throw ServerError.posix(operation: "lstat bound socket", code: code == 0 ? EIO : code)
        }
        boundSocketIdentity = (boundInfo.st_dev, boundInfo.st_ino)
        guard Darwin.chmod(socketURL.path, 0o600) == 0 else {
            let code = errno
            closeDescriptor()
            removeBoundSocketIfOwned()
            throw ServerError.posix(operation: "chmod socket", code: code)
        }
        guard Darwin.listen(fd, 16) == 0 else {
            let code = errno
            closeDescriptor()
            removeBoundSocketIfOwned()
            throw ServerError.posix(operation: "listen", code: code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in self?.acceptPendingClients() }
        readSource.setCancelHandler { Darwin.close(fd) }
        source = readSource
        readSource.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
        eventHandler = nil
        removeBoundSocketIfOwned()
    }

    deinit { stop() }

    private func acceptPendingClients() {
        while descriptor >= 0 {
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            var noSigPipe: Int32 = 1
            let noSigPipeResult = withUnsafePointer(to: &noSigPipe) {
                Darwin.setsockopt(
                    client,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    $0,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
            let canReply = noSigPipeResult == 0
            let process = Self.peerPID(for: client).flatMap {
                AgentProcessMonitor.nearestAgentAncestor(of: $0)
            }
            clientQueue.async { [weak self] in
                let payload = Self.readOneEvent(from: client)
                guard let payload, let self else {
                    if canReply { Self.sendReceipt(0x15, to: client) }
                    Darwin.close(client)
                    return
                }
                // Enqueue while retaining both the server and frame before
                // acknowledging transport receipt. A 0x06 therefore means the
                // complete frame cannot disappear merely because stop/deinit
                // races this client queue; semantic decoding remains AppState's
                // responsibility on the serial queue.
                self.queue.async { [self] in self.eventHandler?(payload, process) }
                if canReply { Self.sendReceipt(0x06, to: client) }
                Darwin.close(client)
            }
        }
    }

    private static func peerPID(for client: Int32) -> pid_t? {
        var value: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        let result = withUnsafeMutablePointer(to: &value) {
            Darwin.getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, $0, &length)
        }
        guard result == 0, value > 0 else { return nil }
        return value
    }

    private static func readOneEvent(from client: Int32) -> Data? {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        let flags = Darwin.fcntl(client, F_GETFL)
        guard flags >= 0, Darwin.fcntl(client, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return nil
        }
        var payload = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while payload.count <= Self.maximumPayloadBytes {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            var pollDescriptor = pollfd(
                fd: client,
                events: Int16(POLLIN),
                revents: 0
            )
            let milliseconds = Int32(
                min(remaining * 1_000, Double(Int32.max)).rounded(.up)
            )
            let pollResult = Darwin.poll(&pollDescriptor, 1, milliseconds)
            if pollResult < 0, errno == EINTR { continue }
            guard pollResult > 0,
                  (pollDescriptor.revents & Int16(POLLIN | POLLHUP)) != 0 else {
                return nil
            }

            let count = Darwin.recv(client, &buffer, buffer.count, 0)
            if count > 0 {
                payload.append(buffer, count: count)
                if let newline = payload.firstIndex(of: 0x0A) {
                    payload = payload.prefix(upTo: newline)
                    break
                }
                continue
            }
            if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            if count == 0 { break }
            return nil
        }
        guard !payload.isEmpty, payload.count <= Self.maximumPayloadBytes else { return nil }
        return payload
    }

    private static func sendReceipt(_ byte: UInt8, to client: Int32) {
        var receipt = byte
        let deadline = ProcessInfo.processInfo.systemUptime + 0.1
        while ProcessInfo.processInfo.systemUptime < deadline {
            let count = Darwin.send(client, &receipt, 1, 0)
            if count == 1 { return }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                var pollDescriptor = pollfd(fd: client, events: Int16(POLLOUT), revents: 0)
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return }
                let milliseconds = Int32(
                    min(remaining * 1_000, Double(Int32.max)).rounded(.up)
                )
                _ = Darwin.poll(&pollDescriptor, 1, milliseconds)
                continue
            }
            return
        }
    }

    private func removeStaleSocketIfSafe() throws {
        guard FileManager.default.fileExists(atPath: socketURL.path) else { return }
        guard isSocket(at: socketURL.path) else { throw ServerError.unsafeExistingPath }
        guard Darwin.unlink(socketURL.path) == 0 else {
            throw ServerError.posix(operation: "unlink stale socket", code: errno)
        }
    }

    private func isSocket(at path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFSOCK
    }

    private func removeBoundSocketIfOwned() {
        guard let expected = boundSocketIdentity else { return }
        defer { boundSocketIdentity = nil }
        var info = stat()
        guard Darwin.lstat(socketURL.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_dev == expected.device,
              info.st_ino == expected.inode else { return }
        _ = Darwin.unlink(socketURL.path)
    }

    private func closeDescriptor() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }
}
