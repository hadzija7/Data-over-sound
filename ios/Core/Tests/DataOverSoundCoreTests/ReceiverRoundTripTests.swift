import XCTest
@testable import DataOverSoundCore

/// Synthesizer → (simulated channel) → streaming receiver. No audio hardware involved.
final class ReceiverRoundTripTests: XCTestCase {
    private let configuration = FSKConfiguration.standard

    func testRoundTripAtCommonSampleRates() throws {
        for rate in [44_100.0, 48_000] {
            let events = try receive(render("Hi čž🙂", rate), rate: rate, chunkSize: 4096)
            XCTAssertEqual(events, [.frameStarted, .messageReceived("Hi čž🙂")], "\(rate) Hz")
        }
    }

    func testChunkBoundariesDoNotAffectDecoding() throws {
        let audio = render("chunk", 48_000)
        for chunkSize in [1, 333, 4096] {
            XCTAssertEqual(try receive(audio, rate: 48_000, chunkSize: chunkSize), [.frameStarted, .messageReceived("chunk")], "chunk \(chunkSize)")
        }
        var rng = DeterministicRandom(seed: 42)
        let receiver = try FrameReceiver(configuration: configuration, sampleRate: 48_000)
        var events: [ReceiverEvent] = []
        var index = 0
        while index < audio.count {
            let end = min(audio.count, index + rng.nextInt(in: 1...5000))
            events += receiver.process(audio[index..<end])
            index = end
        }
        XCTAssertEqual(events, [.frameStarted, .messageReceived("chunk")])
    }

    func testSurvivesAttenuationNoiseEchoAndOffset() throws {
        let rate = 48_000.0
        var rng = DeterministicRandom(seed: 9)
        var audio = [Float](repeating: 0, count: 7_919) + render("noisy room", rate)
        let echoDelay = Int(0.012 * rate)
        for i in stride(from: audio.count - 1, through: echoDelay, by: -1) {
            audio[i] += 0.3 * audio[i - echoDelay]
        }
        audio = audio.map { $0 * 0.05 + rng.nextSignedUnit() * 0.004 }
        XCTAssertEqual(try receive(audio, rate: rate, chunkSize: 1024), [.frameStarted, .messageReceived("noisy room")])
    }

    func testBackToBackMessagesAndTruncatedPayload() throws {
        let long = String(repeating: "é", count: 20)
        let first = try FrameCodec.encodeMessage(long)
        XCTAssertTrue(first.wasTruncated)
        let audio = ToneSynthesizer.render(symbols: first.symbols, configuration: configuration, sampleRate: 48_000)
            + render("second", 48_000)
        XCTAssertEqual(try receive(audio, rate: 48_000, chunkSize: 2048), [
            .frameStarted, .messageReceived(String(repeating: "é", count: 16)),
            .frameStarted, .messageReceived("second"),
        ])
    }

    func testCorruptedSymbolIsRejectedNotDelivered() throws {
        var symbols = try FrameCodec.encodeMessage("abc").symbols
        // Index 9 is the high nibble of the first payload byte ('a' = 0x61).
        guard case .data(let nibble) = symbols[9] else { return XCTFail("unexpected layout") }
        symbols[9] = .data(nibble ^ 0x4)
        let audio = ToneSynthesizer.render(symbols: symbols, configuration: configuration, sampleRate: 48_000)
        let events = try receive(audio, rate: 48_000, chunkSize: 4096)
        XCTAssertEqual(events.count, 2)
        guard case .frameRejected(.checksumMismatch) = events.last else { return XCTFail("\(events)") }
    }

    func testMissingSeparatorCausesRejection() throws {
        var symbols = try FrameCodec.encodeMessage("abc").symbols
        symbols.remove(at: 10)
        let audio = ToneSynthesizer.render(symbols: symbols, configuration: configuration, sampleRate: 48_000)
        let events = try receive(audio, rate: 48_000, chunkSize: 4096)
        guard case .frameRejected = events.last else { return XCTFail("\(events)") }
        XCTAssertFalse(events.contains { if case .messageReceived = $0 { return true } else { return false } })
    }

    func testBadHeaderIsRejectedEarly() throws {
        let symbols: [ToneSymbol] = [.start, .data(0), .separator, .data(2), .separator, .data(0), .separator, .data(1), .separator]
        let audio = ToneSynthesizer.render(symbols: symbols, configuration: configuration, sampleRate: 48_000)
        XCTAssertEqual(try receive(audio, rate: 48_000, chunkSize: 4096), [.frameStarted, .frameRejected(.unsupportedVersion(2))])
    }

    func testFrameWithoutEndTimesOut() throws {
        var symbols = try FrameCodec.encodeMessage("x").symbols
        symbols.removeLast()
        let audio = ToneSynthesizer.render(symbols: symbols, configuration: configuration, sampleRate: 48_000)
            + [Float](repeating: 0, count: 48_000 * 2)
        XCTAssertEqual(try receive(audio, rate: 48_000, chunkSize: 4096), [.frameStarted, .frameRejected(.timeout)])
    }

    func testDataWithoutPreambleIsIgnoredAndResetDropsPartialFrame() throws {
        var symbols = try FrameCodec.encodeMessage("x").symbols
        symbols.removeFirst()
        let headless = ToneSynthesizer.render(symbols: symbols, configuration: configuration, sampleRate: 48_000)
        XCTAssertEqual(try receive(headless, rate: 48_000, chunkSize: 4096), [])

        let audio = render("reset", 48_000)
        let receiver = try FrameReceiver(configuration: configuration, sampleRate: 48_000)
        _ = receiver.process(audio[0..<(audio.count / 2)])
        XCTAssertTrue(receiver.isReceivingFrame)
        receiver.reset()
        XCTAssertFalse(receiver.isReceivingFrame)
        XCTAssertEqual(receiver.process(audio[(audio.count / 2)...]), [])
        XCTAssertEqual(receiver.process(audio), [.frameStarted, .messageReceived("reset")])
    }

    func testSilenceAndNoiseProduceNoEvents() throws {
        var rng = DeterministicRandom(seed: 5)
        let noise = (0..<(48_000 * 2)).map { _ in rng.nextSignedUnit() * 0.3 }
        XCTAssertEqual(try receive([Float](repeating: 0, count: 48_000) + noise, rate: 48_000, chunkSize: 4096), [])
    }

    private func render(_ text: String, _ rate: Double) -> [Float] {
        let encoded = try! FrameCodec.encodeMessage(text, configuration: configuration)
        return ToneSynthesizer.render(symbols: encoded.symbols, configuration: configuration, sampleRate: rate)
    }

    private func receive(_ audio: [Float], rate: Double, chunkSize: Int) throws -> [ReceiverEvent] {
        let receiver = try FrameReceiver(configuration: configuration, sampleRate: rate)
        var events: [ReceiverEvent] = []
        var index = 0
        while index < audio.count {
            let end = min(audio.count, index + chunkSize)
            events += receiver.process(audio[index..<end])
            index = end
        }
        return events
    }
}
