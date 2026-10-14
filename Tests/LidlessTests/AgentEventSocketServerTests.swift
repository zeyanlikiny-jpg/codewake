import Darwin
import XCTest

final class AgentEventSocketServerTests: XCTestCase {
    private func temporarySocketURL() -> (root: URL, socket: URL) {
        // sockaddr_un.sun_path is intentionally short on macOS. Keep fixtures
        // under /tmp so the test validates transport rather than the runner's
        // very long per-user temporary-directory prefix.
        let suffix = String(UUID().uuidString.prefix(8))
        let root = URL(fileURLWithPath: "/tmp/lai-\(suffix)", isDirectory: true)
        let socket = root
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("events.sock", isDirectory: false)
        return (root, socket)
    }

    func testSocketUsesPrivateDirectoryAndModeAndDeliversOneFrame() throws {
        let paths = temporarySocketURL()
        let server = AgentEventSocketServer(socketURL: paths.socket)
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: paths.root)
        }

        let received = expectation(description: "event delivered")
        let payload = Data("{\"schemaVersion\":1}".utf8)
        try server.start { data in
            XCTAssertEqual(data, payload)
            received.fulfill()
        }

        XCTAssertEqual(try permissions(at: paths.socket.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try permissions(at: paths.socket), 0o600)
        XCTAssertTrue(HookBridgeSocketClient.send(
            payload,
            to: paths.socket,
            deadline: ProcessInfo.processInfo.systemUptime + 1
        ))
        wait(for: [received], timeout: 1)
    }

    func testOversizedFrameIsDroppedAndServerContinues() throws {
        let paths = temporarySocketURL()
        let server = AgentEventSocketServer(socketURL: paths.socket)
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: paths.root)
        }

        let validReceived = expectation(description: "valid event after oversized frame")
        let valid = Data("{}".utf8)
        try server.start { data in
            XCTAssertEqual(data, valid, "oversized frame must never reach the decoder")
            validReceived.fulfill()
        }

        XCTAssertFalse(HookBridgeSocketClient.send(
            Data(repeating: 0x41, count: AgentEventSocketServer.maximumPayloadBytes + 1),
            to: paths.socket,
            deadline: ProcessInfo.processInfo.systemUptime + 1
        ))
        XCTAssertTrue(HookBridgeSocketClient.send(
            valid,
            to: paths.socket,
            deadline: ProcessInfo.processInfo.systemUptime + 1
        ))
        wait(for: [validReceived], timeout: 1)
    }

    func testExistingRegularFileIsNotDeletedOrReplaced() throws {
        let paths = temporarySocketURL()
        try FileManager.default.createDirectory(
            at: paths.socket.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let marker = Data("do not delete".utf8)
        try marker.write(to: paths.socket)
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let server = AgentEventSocketServer(socketURL: paths.socket)
        XCTAssertThrowsError(try server.start { _ in }) { error in
            guard case AgentEventSocketServer.ServerError.unsafeExistingPath = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: paths.socket), marker)
    }

    func testRuntimeDirectorySymlinkIsRejectedWithoutFollowingIt() throws {
        let paths = temporarySocketURL()
        let target = paths.root.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        _ = Darwin.chmod(target.path, 0o755)
        try FileManager.default.createSymbolicLink(
            at: paths.socket.deletingLastPathComponent(),
            withDestinationURL: target
        )
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let server = AgentEventSocketServer(socketURL: paths.socket)
        XCTAssertThrowsError(try server.start { _ in }) { error in
            guard case AgentEventSocketServer.ServerError.unsafeRuntimeDirectory = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try permissions(at: target), 0o755)
    }

    func testOldServerStopDoesNotDeleteReplacementSocket() throws {
        let paths = temporarySocketURL()
        let oldServer = AgentEventSocketServer(socketURL: paths.socket)
        let replacement = AgentEventSocketServer(socketURL: paths.socket)
        defer {
            oldServer.stop()
            replacement.stop()
            try? FileManager.default.removeItem(at: paths.root)
        }

        try oldServer.start { _ in }
        let received = expectation(description: "replacement receives event")
        let payload = Data("replacement".utf8)
        try replacement.start { data in
            XCTAssertEqual(data, payload)
            received.fulfill()
        }

        oldServer.stop()
        XCTAssertTrue(HookBridgeSocketClient.send(
            payload,
            to: paths.socket,
            deadline: ProcessInfo.processInfo.systemUptime + 1
        ))
        wait(for: [received], timeout: 1)
    }

    func testStalledClientCannotBlockAValidHook() throws {
        let paths = temporarySocketURL()
        let server = AgentEventSocketServer(socketURL: paths.socket)
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: paths.root)
        }

        let received = expectation(description: "valid hook bypasses stalled client")
        let valid = Data("valid".utf8)
        try server.start { data in
            XCTAssertEqual(data, valid)
            received.fulfill()
        }

        let stalled = try connectedSocket(to: paths.socket)
        defer { Darwin.close(stalled) }
        var byte: UInt8 = 0x7B
        XCTAssertEqual(Darwin.send(stalled, &byte, 1, 0), 1)

        XCTAssertTrue(HookBridgeSocketClient.send(
            valid,
            to: paths.socket,
            deadline: ProcessInfo.processInfo.systemUptime + 1
        ))
        wait(for: [received], timeout: 0.5)
    }

    func testClientAcceptsCleanCloseFromLegacyServerWithoutReceipt() throws {
        let paths = temporarySocketURL()
        try FileManager.default.createDirectory(
            at: paths.socket.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let listener = try listeningSocket(at: paths.socket)
        defer {
            Darwin.close(listener)
            try? FileManager.default.removeItem(at: paths.root)
        }

        let legacyRead = expectation(description: "legacy server read frame")
        DispatchQueue.global().async {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 256)
            _ = Darwin.recv(client, &buffer, buffer.count, 0)
            Darwin.close(client)
            legacyRead.fulfill()
        }

        XCTAssertTrue(HookBridgeSocketClient.send(
            Data("legacy".utf8),
            to: paths.socket,
            deadline: ProcessInfo.processInfo.systemUptime + 1
        ))
        wait(for: [legacyRead], timeout: 1)
    }

    func testClientWaitsForDelayedReceipt() throws {
        let paths = temporarySocketURL()
        try FileManager.default.createDirectory(
            at: paths.socket.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let listener = try listeningSocket(at: paths.socket)
        defer {
            Darwin.close(listener)
            try? FileManager.default.removeItem(at: paths.root)
        }

        let replied = expectation(description: "delayed receipt sent")
        DispatchQueue.global().async {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 256)
            _ = Darwin.recv(client, &buffer, buffer.count, 0)
            usleep(50_000)
            var receipt: UInt8 = 0x06
            _ = Darwin.send(client, &receipt, 1, 0)
            Darwin.close(client)
            replied.fulfill()
        }

        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(HookBridgeSocketClient.send(
            Data("delayed".utf8),
            to: paths.socket,
            deadline: started + 1
        ))
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 0.04)
        wait(for: [replied], timeout: 1)
    }

    func testClientRejectsNegativeReceipt() throws {
        let paths = temporarySocketURL()
        try FileManager.default.createDirectory(
            at: paths.socket.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let listener = try listeningSocket(at: paths.socket)
        defer {
            Darwin.close(listener)
            try? FileManager.default.removeItem(at: paths.root)
        }

        let rejected = expectation(description: "negative receipt sent")
        DispatchQueue.global().async {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 256)
            _ = Darwin.recv(client, &buffer, buffer.count, 0)
            var receipt: UInt8 = 0x15
            _ = Darwin.send(client, &receipt, 1, 0)
            Darwin.close(client)
            rejected.fulfill()
        }

        XCTAssertFalse(HookBridgeSocketClient.send(
            Data("invalid".utf8),
            to: paths.socket,
            deadline: ProcessInfo.processInfo.systemUptime + 1
        ))
        wait(for: [rejected], timeout: 1)
    }

    func testClientTimesOutBeforeLateLegacyClose() throws {
        let paths = temporarySocketURL()
        try FileManager.default.createDirectory(
            at: paths.socket.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let listener = try listeningSocket(at: paths.socket)
        defer {
            Darwin.close(listener)
            try? FileManager.default.removeItem(at: paths.root)
        }

        let closed = expectation(description: "late legacy close")
        DispatchQueue.global().async {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 256)
            _ = Darwin.recv(client, &buffer, buffer.count, 0)
            usleep(100_000)
            Darwin.close(client)
            closed.fulfill()
        }

        XCTAssertFalse(HookBridgeSocketClient.send(
            Data("timeout".utf8),
            to: paths.socket,
            deadline: ProcessInfo.processInfo.systemUptime + 0.02
        ))
        wait(for: [closed], timeout: 1)
    }

    func testLegacyFireAndForgetClientDoesNotBreakNewServer() throws {
        let paths = temporarySocketURL()
        let server = AgentEventSocketServer(socketURL: paths.socket)
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: paths.root)
        }

        let received = expectation(description: "legacy event delivered")
        try server.start { data in
            XCTAssertEqual(data, Data("legacy-event".utf8))
            received.fulfill()
        }
        let client = try connectedSocket(to: paths.socket)
        var frame = Data("legacy-event\n".utf8)
        let sent = frame.withUnsafeMutableBytes { bytes in
            Darwin.send(client, bytes.baseAddress, bytes.count, 0)
        }
        XCTAssertEqual(sent, frame.count)
        Darwin.close(client)
        wait(for: [received], timeout: 1)
    }

    private func connectedSocket(to url: URL) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        let path = url.path.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: path.count) { buffer in
                for (index, value) in path.enumerated() { buffer[index] = value }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return descriptor
    }

    private func listeningSocket(at url: URL) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        let path = url.path.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: path.count) { buffer in
                for (index, value) in path.enumerated() { buffer[index] = value }
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bound == 0,
              Darwin.chmod(url.path, 0o600) == 0,
              Darwin.listen(descriptor, 1) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return descriptor
    }

    private func permissions(at url: URL) throws -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return info.st_mode & 0o777
    }
}
