import Darwin
import Foundation

/// Small, versioned wire surface shared by the menu-bar app and the ephemeral
/// display watchdog. The watchdog is intentionally not a service: the app owns
/// two anonymous pipes and launches one watchdog for one blackout generation.
public enum DisplayBlackoutProtocol {
    public static let currentVersion = 1
    public static let currentVersionAdvertisement = "0.2.17+21;protocol=1"
    public static let maximumPayloadBytes = 4 * 1024
    public static let frameHeaderBytes = MemoryLayout<UInt32>.size
    public static let maximumTokenBytes = 128

    public static func makeToken() -> String {
        UUID().uuidString.lowercased()
    }

    public static func tokenIsValid(_ token: String) -> Bool {
        let bytes = token.utf8
        guard !bytes.isEmpty, bytes.count <= maximumTokenBytes else { return false }
        return bytes.allSatisfy { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x5F:
                return true
            default:
                return false
            }
        }
    }
}

public enum DisplayBlackoutRequestAction: String, Codable, Equatable {
    /// Probe current topology/API capability without changing brightness.
    case status
    /// Recover any durable journal left by an earlier process, then exit.
    case recover
    /// Recover stale state first, then start this request's blackout generation.
    case arm
    /// Restore the active generation. A mismatched token/generation is rejected.
    case restore
}

public struct DisplayBlackoutRequest: Codable, Equatable {
    public let protocolVersion: Int
    public let versionAdvertisement: String
    public let token: String
    public let generation: UInt64
    public let action: DisplayBlackoutRequestAction

    public init(
        token: String,
        generation: UInt64,
        action: DisplayBlackoutRequestAction,
        protocolVersion: Int = DisplayBlackoutProtocol.currentVersion,
        versionAdvertisement: String = DisplayBlackoutProtocol.currentVersionAdvertisement
    ) {
        self.protocolVersion = protocolVersion
        self.versionAdvertisement = versionAdvertisement
        self.token = token
        self.generation = generation
        self.action = action
    }

    public var validationFailure: DisplayBlackoutRequestValidationFailure? {
        guard protocolVersion == DisplayBlackoutProtocol.currentVersion,
              versionAdvertisement == DisplayBlackoutProtocol.currentVersionAdvertisement else {
            return .protocolMismatch
        }
        guard DisplayBlackoutProtocol.tokenIsValid(token), generation > 0 else {
            return .invalidIdentity
        }
        return nil
    }
}

public enum DisplayBlackoutRequestValidationFailure: String, Codable, Equatable {
    case protocolMismatch
    case invalidIdentity
}

/// Stable, localization-free state codes. User-facing strings remain in the
/// app. In particular, topology failure is never collapsed into "no external
/// display" because that would turn an observation failure into permission.
public enum DisplayBlackoutResponseStatus: String, Codable, Equatable {
    case ready
    case armed
    case restored
    case noRecoveryNeeded
    case externalDisplayConnected
    case topologyUnknown
    case builtInUnavailable
    case brightnessUnavailable
    case protocolMismatch
    case invalidRequest
    case staleGeneration
    case failed
}

public enum DisplayBlackoutRestoreTrigger: String, Codable, Equatable {
    case requested
    case startupRecovery
    case hidInput
    case externalDisplayConnected
    case parentPipeClosed
    case controlFailure
}

public enum DisplayBlackoutJournalPhase: String, Codable, Equatable {
    case prepared
    case armed
    case restoring
}

public struct DisplayBlackoutResponse: Codable, Equatable {
    public let protocolVersion: Int
    public let versionAdvertisement: String
    public let token: String
    public let generation: UInt64
    public let status: DisplayBlackoutResponseStatus
    public let trigger: DisplayBlackoutRestoreTrigger?
    public let journalPhase: DisplayBlackoutJournalPhase?
    /// True means the durable record remains and recovery must be retried. It is
    /// intentionally independent of `status`, which preserves the exact reason
    /// (for example `builtInUnavailable` rather than a vague pending state).
    public let recoveryPending: Bool
    public let failureCode: String?

    public init(
        token: String,
        generation: UInt64,
        status: DisplayBlackoutResponseStatus,
        trigger: DisplayBlackoutRestoreTrigger? = nil,
        journalPhase: DisplayBlackoutJournalPhase? = nil,
        recoveryPending: Bool = false,
        failureCode: String? = nil,
        protocolVersion: Int = DisplayBlackoutProtocol.currentVersion,
        versionAdvertisement: String = DisplayBlackoutProtocol.currentVersionAdvertisement
    ) {
        self.protocolVersion = protocolVersion
        self.versionAdvertisement = versionAdvertisement
        self.token = token
        self.generation = generation
        self.status = status
        self.trigger = trigger
        self.journalPhase = journalPhase
        self.recoveryPending = recoveryPending
        self.failureCode = failureCode
    }
}

public enum DisplayBlackoutFrameError: Error, Equatable {
    case emptyPayload
    case payloadTooLarge(Int)
    case incompleteFrame
    case trailingBytes
    case malformedPayload
    case inputBufferOverflow
    case ioFailure(Int32)
}

/// Four-byte, big-endian length prefix followed by one JSON value. The strict
/// 4 KiB cap applies before allocation and to both requests and responses.
public enum DisplayBlackoutFrameCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(value)
        guard !payload.isEmpty else { throw DisplayBlackoutFrameError.emptyPayload }
        guard payload.count <= DisplayBlackoutProtocol.maximumPayloadBytes else {
            throw DisplayBlackoutFrameError.payloadTooLarge(payload.count)
        }

        var networkLength = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &networkLength) { Data($0) }
        frame.append(payload)
        return frame
    }

    public static func decode<T: Decodable>(_ type: T.Type, from frame: Data) throws -> T {
        guard frame.count >= DisplayBlackoutProtocol.frameHeaderBytes else {
            throw DisplayBlackoutFrameError.incompleteFrame
        }
        let length = frame.prefix(DisplayBlackoutProtocol.frameHeaderBytes).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard length > 0 else { throw DisplayBlackoutFrameError.emptyPayload }
        guard length <= UInt32(DisplayBlackoutProtocol.maximumPayloadBytes) else {
            throw DisplayBlackoutFrameError.payloadTooLarge(Int(length))
        }
        let expectedCount = DisplayBlackoutProtocol.frameHeaderBytes + Int(length)
        guard frame.count >= expectedCount else { throw DisplayBlackoutFrameError.incompleteFrame }
        guard frame.count == expectedCount else { throw DisplayBlackoutFrameError.trailingBytes }

        do {
            return try JSONDecoder().decode(type, from: frame.dropFirst(
                DisplayBlackoutProtocol.frameHeaderBytes
            ))
        } catch {
            throw DisplayBlackoutFrameError.malformedPayload
        }
    }

    /// Synchronous first-frame reader used before any brightness mutation. EOF
    /// before the first header byte is a clean "no request" result; every partial
    /// frame is rejected.
    public static func read<T: Decodable>(
        _ type: T.Type,
        from descriptor: Int32
    ) throws -> T? {
        guard let header = try readExactly(
            count: DisplayBlackoutProtocol.frameHeaderBytes,
            from: descriptor,
            cleanEOFAllowed: true
        ) else { return nil }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0 else { throw DisplayBlackoutFrameError.emptyPayload }
        guard length <= UInt32(DisplayBlackoutProtocol.maximumPayloadBytes) else {
            throw DisplayBlackoutFrameError.payloadTooLarge(Int(length))
        }
        guard let payload = try readExactly(
            count: Int(length),
            from: descriptor,
            cleanEOFAllowed: false
        ) else {
            throw DisplayBlackoutFrameError.incompleteFrame
        }

        var frame = Data(header)
        frame.append(payload)
        return try decode(type, from: frame)
    }

    public static func write<T: Encodable>(_ value: T, to descriptor: Int32) throws {
        let frame = try encode(value)
        try frame.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw DisplayBlackoutFrameError.emptyPayload
            }
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    bytes.count - written
                )
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw DisplayBlackoutFrameError.ioFailure(errno)
                }
            }
        }
    }

    private static func readExactly(
        count: Int,
        from descriptor: Int32,
        cleanEOFAllowed: Bool
    ) throws -> Data? {
        var result = Data()
        result.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: min(count, 1_024))

        while result.count < count {
            let requested = min(buffer.count, count - result.count)
            let readCount = Darwin.read(descriptor, &buffer, requested)
            if readCount > 0 {
                result.append(buffer, count: readCount)
                continue
            }
            if readCount == 0 {
                if cleanEOFAllowed, result.isEmpty { return nil }
                throw DisplayBlackoutFrameError.incompleteFrame
            }
            if errno == EINTR { continue }
            throw DisplayBlackoutFrameError.ioFailure(errno)
        }
        return result
    }
}

/// Incremental counterpart used after arming so a parent that dies halfway
/// through a control frame cannot block HID/topology recovery checks.
public struct DisplayBlackoutFrameStreamDecoder {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        guard !data.isEmpty else { return [] }
        let hardLimit = DisplayBlackoutProtocol.maximumPayloadBytes
            + DisplayBlackoutProtocol.frameHeaderBytes
        guard buffer.count + data.count <= hardLimit else {
            throw DisplayBlackoutFrameError.inputBufferOverflow
        }
        buffer.append(data)

        guard buffer.count >= DisplayBlackoutProtocol.frameHeaderBytes else { return [] }
        let length = buffer.prefix(DisplayBlackoutProtocol.frameHeaderBytes).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard length > 0 else { throw DisplayBlackoutFrameError.emptyPayload }
        guard length <= UInt32(DisplayBlackoutProtocol.maximumPayloadBytes) else {
            throw DisplayBlackoutFrameError.payloadTooLarge(Int(length))
        }
        let frameLength = DisplayBlackoutProtocol.frameHeaderBytes + Int(length)
        guard buffer.count >= frameLength else { return [] }
        guard buffer.count == frameLength else {
            // One active watchdog accepts exactly one post-arm control request.
            throw DisplayBlackoutFrameError.trailingBytes
        }
        let frame = buffer
        buffer.removeAll(keepingCapacity: false)
        return [frame]
    }

    public func finish() throws {
        guard buffer.isEmpty else { throw DisplayBlackoutFrameError.incompleteFrame }
    }
}
