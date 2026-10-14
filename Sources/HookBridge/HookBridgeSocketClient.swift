import Darwin
import Foundation

enum HookBridgeSocketClient {
    static func send(_ data: Data, to socketURL: URL, deadline: TimeInterval) -> Bool {
        guard isPrivateSocket(socketURL.path) else { return false }

        let pathBytes = socketURL.path.utf8CString
        var address = sockaddr_un()
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var noSigPipe: Int32 = 1
        let noSigPipeResult = withUnsafePointer(to: &noSigPipe) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        guard noSigPipeResult == 0 else { return false }
        let previousFlags = Darwin.fcntl(descriptor, F_GETFL)
        guard previousFlags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, previousFlags | O_NONBLOCK) == 0 else {
            return false
        }

        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
            tuplePointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { chars in
                for (index, byte) in pathBytes.enumerated() { chars[index] = byte }
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult != 0 {
            guard errno == EINPROGRESS,
                  waitForWritable(descriptor, deadline: deadline),
                  socketError(descriptor) == 0 else { return false }
        }

        var framedData = data
        framedData.append(0x0A)
        let sentFrame = framedData.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return false }
            var sent = 0
            while sent < bytes.count, ProcessInfo.processInfo.systemUptime < deadline {
                let result = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: sent),
                    bytes.count - sent,
                    0
                )
                if result > 0 {
                    sent += result
                    continue
                }
                if result < 0, errno == EINTR { continue }
                if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    guard waitForWritable(descriptor, deadline: deadline) else { return false }
                    continue
                }
                return false
            }
            return sent == bytes.count
        }
        guard sentFrame else { return false }

        // Keep this short-lived bridge alive until the app has accepted the
        // frame. Without a receipt, the process can exit between connect/send
        // and LOCAL_PEERPID ancestry inspection, so a genuine Codex/Claude
        // event keeps the Mac awake but can never verify its product surface.
        // A clean close without the receipt remains success for rolling updates
        // against an older app server that does not yet write the byte.
        return waitForReceiptOrLegacyClose(descriptor, deadline: deadline)
    }

    /// The app creates its runtime directory as 0700 and socket as 0600. The
    /// client refuses symlinks, non-sockets, foreign owners, and broader modes.
    private static func isPrivateSocket(_ path: String) -> Bool {
        var info = stat()
        guard Darwin.lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == Darwin.geteuid(),
              (info.st_mode & 0o777) == 0o600 else {
            return false
        }
        return true
    }

    private static func waitForWritable(_ descriptor: Int32, deadline: TimeInterval) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let milliseconds = Int32(min(remaining * 1_000, Double(Int32.max)).rounded(.up))
        let result = Darwin.poll(&pollDescriptor, 1, milliseconds)
        return result > 0 && (pollDescriptor.revents & Int16(POLLOUT)) != 0
    }

    private static func waitForReceiptOrLegacyClose(
        _ descriptor: Int32,
        deadline: TimeInterval
    ) -> Bool {
        while ProcessInfo.processInfo.systemUptime < deadline {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let milliseconds = Int32(
                min(remaining * 1_000, Double(Int32.max)).rounded(.up)
            )
            let result = Darwin.poll(&pollDescriptor, 1, milliseconds)
            if result < 0, errno == EINTR { continue }
            guard result > 0,
                  (pollDescriptor.revents & Int16(POLLIN | POLLHUP)) != 0 else {
                return false
            }

            var receipt: UInt8 = 0
            let count = Darwin.recv(descriptor, &receipt, 1, 0)
            if count == 1 { return receipt == 0x06 }
            if count == 0 { return true }
            if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            return false
        }
        return false
    }

    private static func socketError(_ descriptor: Int32) -> Int32 {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let result = withUnsafeMutablePointer(to: &value) {
            Darwin.getsockopt(descriptor, SOL_SOCKET, SO_ERROR, $0, &length)
        }
        return result == 0 ? value : errno
    }
}
