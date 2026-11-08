public enum FrameError: Error, Equatable, Sendable {
    case emptyMessage
    case payloadTooLarge(bytes: Int, maximum: Int)
    case frameTooShort(bytes: Int)
    case unsupportedVersion(UInt8)
    case declaredLengthExceedsMaximum(declared: Int, maximum: Int)
    case lengthMismatch(expectedFrameBytes: Int, actualFrameBytes: Int)
    case oddNibbleCount(Int)
    case checksumMismatch(expected: UInt16, actual: UInt16)
    case invalidUTF8
    case timeout
    case unexpectedRestart
}

public struct EncodedMessage: Equatable, Sendable {
    public let payload: [UInt8]
    public let frame: [UInt8]
    public let symbols: [ToneSymbol]
    /// True when the input text did not fit and whole characters were dropped from the end.
    public let wasTruncated: Bool
}

/// Wire format (version 1), all multi-byte integers big-endian:
///
///     byte 0      version (0x01)
///     byte 1      payload length L (1...maxPayloadBytes)
///     bytes 2..   L bytes of UTF-8 text
///     last 2      CRC-16/CCITT-FALSE over bytes 0..<(2+L)
///
/// Each frame byte becomes two 4-bit nibbles, high nibble first. On air:
///
///     START, (DATA(nibble), SEP) × 2·(L+4), END
public enum FrameCodec {
    public static let version: UInt8 = 1
    public static let headerSize = 2
    public static let checksumSize = 2

    public static func frameSize(payloadLength: Int) -> Int {
        headerSize + payloadLength + checksumSize
    }

    /// Returns at most `maxBytes` of UTF-8, cutting only between whole characters (grapheme clusters).
    public static func truncatedUTF8(_ text: String, maxBytes: Int) -> (bytes: [UInt8], wasTruncated: Bool) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(text.utf8.count, max(maxBytes, 0)))
        for character in text {
            let encoded = Array(String(character).utf8)
            guard bytes.count + encoded.count <= maxBytes else {
                return (bytes, true)
            }
            bytes.append(contentsOf: encoded)
        }
        return (bytes, false)
    }

    public static func encodeMessage(_ text: String, configuration: FSKConfiguration = .standard) throws -> EncodedMessage {
        let (payload, truncated) = truncatedUTF8(text, maxBytes: configuration.maxPayloadBytes)
        let frame = try encodeFrame(payload: payload, maxPayloadBytes: configuration.maxPayloadBytes)
        return EncodedMessage(payload: payload, frame: frame, symbols: symbols(forFrame: frame), wasTruncated: truncated)
    }

    public static func encodeFrame(payload: [UInt8], maxPayloadBytes: Int) throws -> [UInt8] {
        guard !payload.isEmpty else { throw FrameError.emptyMessage }
        let limit = min(maxPayloadBytes, Int(UInt8.max))
        guard payload.count <= limit else {
            throw FrameError.payloadTooLarge(bytes: payload.count, maximum: limit)
        }
        var frame: [UInt8] = [version, UInt8(payload.count)]
        frame.append(contentsOf: payload)
        let crc = crc16(frame)
        frame.append(UInt8(crc >> 8))
        frame.append(UInt8(crc & 0xFF))
        return frame
    }

    /// Validates a complete frame and returns its payload bytes.
    public static func decodeFrame(_ frame: [UInt8], maxPayloadBytes: Int) throws -> [UInt8] {
        guard frame.count >= headerSize + checksumSize else {
            throw FrameError.frameTooShort(bytes: frame.count)
        }
        try validateHeader(version: frame[0], declaredLength: Int(frame[1]), maxPayloadBytes: maxPayloadBytes)
        let declared = Int(frame[1])
        let expected = frameSize(payloadLength: declared)
        guard frame.count == expected else {
            throw FrameError.lengthMismatch(expectedFrameBytes: expected, actualFrameBytes: frame.count)
        }
        let body = Array(frame[0..<(headerSize + declared)])
        let received = UInt16(frame[expected - 2]) << 8 | UInt16(frame[expected - 1])
        let computed = crc16(body)
        guard received == computed else {
            throw FrameError.checksumMismatch(expected: computed, actual: received)
        }
        return Array(body[headerSize...])
    }

    /// Header check usable as soon as the first two bytes are known, so a receiver can abort early.
    public static func validateHeader(version receivedVersion: UInt8, declaredLength: Int, maxPayloadBytes: Int) throws {
        guard receivedVersion == version else { throw FrameError.unsupportedVersion(receivedVersion) }
        guard declaredLength >= 1, declaredLength <= maxPayloadBytes else {
            throw FrameError.declaredLengthExceedsMaximum(declared: declaredLength, maximum: maxPayloadBytes)
        }
    }

    public static func decodeMessage(frame: [UInt8], maxPayloadBytes: Int) throws -> String {
        let payload = try decodeFrame(frame, maxPayloadBytes: maxPayloadBytes)
        guard let text = strictUTF8String(payload) else { throw FrameError.invalidUTF8 }
        return text
    }

    /// Decodes UTF-8, rejecting (rather than repairing) any malformed sequence.
    public static func strictUTF8String(_ bytes: [UInt8]) -> String? {
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        var scalars = String.UnicodeScalarView()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput: return String(scalars)
            case .error: return nil
            }
        }
    }

    public static func nibbles(of bytes: [UInt8]) -> [UInt8] {
        bytes.flatMap { [$0 >> 4, $0 & 0x0F] }
    }

    public static func bytes(fromNibbles nibbles: [UInt8]) throws -> [UInt8] {
        guard nibbles.count % 2 == 0 else { throw FrameError.oddNibbleCount(nibbles.count) }
        return stride(from: 0, to: nibbles.count, by: 2).map { (nibbles[$0] & 0x0F) << 4 | (nibbles[$0 + 1] & 0x0F) }
    }

    public static func symbols(forFrame frame: [UInt8]) -> [ToneSymbol] {
        var symbols: [ToneSymbol] = [.start]
        for nibble in nibbles(of: frame) {
            symbols.append(.data(nibble))
            symbols.append(.separator)
        }
        symbols.append(.end)
        return symbols
    }

    /// CRC-16/CCITT-FALSE: polynomial 0x1021, initial value 0xFFFF, no reflection, no final XOR.
    public static func crc16<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}
