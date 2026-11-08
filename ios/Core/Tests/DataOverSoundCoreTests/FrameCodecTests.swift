import XCTest
@testable import DataOverSoundCore

final class FrameCodecTests: XCTestCase {
    func testCRC16MatchesCCITTFalseCheckValue() {
        XCTAssertEqual(FrameCodec.crc16(Array("123456789".utf8)), 0x29B1)
        XCTAssertEqual(FrameCodec.crc16([UInt8]()), 0xFFFF)
    }

    func testFrameLayoutIsVersionLengthPayloadCRC() throws {
        let frame = try FrameCodec.encodeFrame(payload: Array("Hi".utf8), maxPayloadBytes: 32)
        let crc = FrameCodec.crc16([0x01, 0x02, 0x48, 0x69])
        XCTAssertEqual(frame, [0x01, 0x02, 0x48, 0x69, UInt8(crc >> 8), UInt8(crc & 0xFF)])
    }

    func testRoundTripOfMultiByteUTF8() throws {
        for text in ["Hello", "Zdravo, svijete! čćžšđ", "日本語", "🙂👋", "a\u{0301}"] {
            let encoded = try FrameCodec.encodeMessage(text)
            XCTAssertFalse(encoded.wasTruncated, text)
            XCTAssertEqual(try FrameCodec.decodeMessage(frame: encoded.frame, maxPayloadBytes: 32), text)
        }
    }

    func testTruncationNeverSplitsACharacter() {
        let ascii = FrameCodec.truncatedUTF8("abcdef", maxBytes: 4)
        XCTAssertEqual(ascii.bytes, Array("abcd".utf8))
        XCTAssertTrue(ascii.wasTruncated)

        // "é" is 2 bytes: 3 + 2 > 4, so it is dropped entirely rather than cut in half.
        let twoByte = FrameCodec.truncatedUTF8("abcé", maxBytes: 4)
        XCTAssertEqual(twoByte.bytes, Array("abc".utf8))
        XCTAssertTrue(twoByte.wasTruncated)

        let emoji = FrameCodec.truncatedUTF8("ab🙂", maxBytes: 5)
        XCTAssertEqual(emoji.bytes, Array("ab".utf8))

        // Decomposed "é" (e + U+0301) is one grapheme of 3 bytes and must stay together.
        let combining = FrameCodec.truncatedUTF8("xe\u{0301}", maxBytes: 3)
        XCTAssertEqual(combining.bytes, Array("x".utf8))

        let fits = FrameCodec.truncatedUTF8("čć", maxBytes: 4)
        XCTAssertEqual(fits.bytes, Array("čć".utf8))
        XCTAssertFalse(fits.wasTruncated)

        for limit in 0...20 {
            let result = FrameCodec.truncatedUTF8("Ωmega 🙂 naïve 日本", maxBytes: limit)
            XCTAssertLessThanOrEqual(result.bytes.count, limit)
            XCTAssertNotNil(FrameCodec.strictUTF8String(result.bytes), "limit \(limit) produced invalid UTF-8")
        }
    }

    func testEncodeMessageTruncatesToConfiguredMaximum() throws {
        let encoded = try FrameCodec.encodeMessage(String(repeating: "ž", count: 40))
        XCTAssertTrue(encoded.wasTruncated)
        XCTAssertEqual(encoded.payload.count, 32)
        XCTAssertEqual(FrameCodec.strictUTF8String(encoded.payload), String(repeating: "ž", count: 16))
    }

    func testEmptyAndOversizedPayloadsAreRejected() {
        XCTAssertThrowsError(try FrameCodec.encodeMessage("")) { XCTAssertEqual($0 as? FrameError, .emptyMessage) }
        XCTAssertThrowsError(try FrameCodec.encodeFrame(payload: [UInt8](repeating: 65, count: 33), maxPayloadBytes: 32)) {
            XCTAssertEqual($0 as? FrameError, .payloadTooLarge(bytes: 33, maximum: 32))
        }
    }

    func testDecodeRejectsCorruptFrames() throws {
        let frame = try FrameCodec.encodeFrame(payload: Array("test".utf8), maxPayloadBytes: 32)

        var flipped = frame
        flipped[3] ^= 0x01
        XCTAssertThrowsError(try FrameCodec.decodeFrame(flipped, maxPayloadBytes: 32)) {
            guard case .checksumMismatch = $0 as? FrameError else { return XCTFail("\($0)") }
        }

        var wrongVersion = frame
        wrongVersion[0] = 2
        XCTAssertThrowsError(try FrameCodec.decodeFrame(wrongVersion, maxPayloadBytes: 32)) {
            XCTAssertEqual($0 as? FrameError, .unsupportedVersion(2))
        }

        XCTAssertThrowsError(try FrameCodec.decodeFrame(Array(frame.dropLast()), maxPayloadBytes: 32)) {
            XCTAssertEqual($0 as? FrameError, .lengthMismatch(expectedFrameBytes: 8, actualFrameBytes: 7))
        }
        XCTAssertThrowsError(try FrameCodec.decodeFrame(frame + [0], maxPayloadBytes: 32)) {
            XCTAssertEqual($0 as? FrameError, .lengthMismatch(expectedFrameBytes: 8, actualFrameBytes: 9))
        }

        var tooLong = frame
        tooLong[1] = 200
        XCTAssertThrowsError(try FrameCodec.decodeFrame(tooLong, maxPayloadBytes: 32)) {
            XCTAssertEqual($0 as? FrameError, .declaredLengthExceedsMaximum(declared: 200, maximum: 32))
        }

        XCTAssertThrowsError(try FrameCodec.decodeFrame([1, 0, 0], maxPayloadBytes: 32)) {
            XCTAssertEqual($0 as? FrameError, .frameTooShort(bytes: 3))
        }
    }

    func testValidCRCButInvalidUTF8IsRejected() throws {
        let frame = try FrameCodec.encodeFrame(payload: [0xC3, 0x28], maxPayloadBytes: 32)
        XCTAssertThrowsError(try FrameCodec.decodeMessage(frame: frame, maxPayloadBytes: 32)) {
            XCTAssertEqual($0 as? FrameError, .invalidUTF8)
        }
    }

    func testStrictUTF8Decoder() {
        XCTAssertEqual(FrameCodec.strictUTF8String(Array("čž🙂".utf8)), "čž🙂")
        XCTAssertNil(FrameCodec.strictUTF8String([0xC0, 0xAF]), "overlong encoding")
        XCTAssertNil(FrameCodec.strictUTF8String([0x80]), "lone continuation byte")
        XCTAssertNil(FrameCodec.strictUTF8String([0xF0, 0x9F, 0x99]), "truncated 4-byte sequence")
        XCTAssertNil(FrameCodec.strictUTF8String([0xED, 0xA0, 0x80]), "UTF-16 surrogate")
    }

    func testNibbleOrderAndSymbolSequence() throws {
        XCTAssertEqual(FrameCodec.nibbles(of: [0xA5, 0x0F]), [0xA, 0x5, 0x0, 0xF])
        XCTAssertEqual(try FrameCodec.bytes(fromNibbles: [0xA, 0x5, 0x0, 0xF]), [0xA5, 0x0F])
        XCTAssertThrowsError(try FrameCodec.bytes(fromNibbles: [1, 2, 3])) {
            XCTAssertEqual($0 as? FrameError, .oddNibbleCount(3))
        }

        let symbols = FrameCodec.symbols(forFrame: [0x12])
        XCTAssertEqual(symbols, [.start, .data(1), .separator, .data(2), .separator, .end])

        let encoded = try FrameCodec.encodeMessage("abc")
        XCTAssertEqual(encoded.symbols.count, 2 + 2 * 2 * FrameCodec.frameSize(payloadLength: 3))
    }
}
