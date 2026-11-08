import XCTest
@testable import DataOverSoundCore

final class SynthesizerTests: XCTestCase {
    func testRenderedLengthAndBoundsAreDeterministic() throws {
        let configuration = FSKConfiguration.standard
        let symbols = try FrameCodec.encodeMessage("ok").symbols
        let audio = ToneSynthesizer.render(symbols: symbols, configuration: configuration, sampleRate: 48_000)
        // 0.15 s + START 0.3 s + 12 × (0.12 + 0.10) s + END 0.3 s + 0.15 s
        XCTAssertEqual(audio.count, Int(((0.15 + 0.3 + 12 * 0.22 + 0.3 + 0.15) * 48_000).rounded()))
        XCTAssertEqual(audio.count, ToneSynthesizer.sampleCount(for: symbols, configuration: configuration, sampleRate: 48_000))
        XCTAssertLessThanOrEqual(audio.map(abs).max() ?? 0, configuration.amplitude + 1e-6)
        XCTAssertTrue(audio.allSatisfy(\.isFinite))
        XCTAssertEqual(audio.prefix(Int(0.15 * 48_000)).map(abs).max(), 0, "leading silence")
        XCTAssertEqual(ToneSynthesizer.render(symbols: symbols, configuration: configuration, sampleRate: 48_000), audio)
    }

    func testSegmentsStartAndEndQuietlyToAvoidClicks() {
        var configuration = FSKConfiguration.standard
        configuration.leadingSilenceDuration = 0
        configuration.trailingSilenceDuration = 0
        let audio = ToneSynthesizer.render(symbols: [.data(0)], configuration: configuration, sampleRate: 48_000)
        XCTAssertLessThan(abs(audio.first!), 1e-6)
        XCTAssertLessThan(abs(audio.last!), 0.01)
    }
}
