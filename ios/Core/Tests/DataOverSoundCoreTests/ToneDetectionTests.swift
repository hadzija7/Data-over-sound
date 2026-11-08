import XCTest
@testable import DataOverSoundCore

final class ToneDetectionTests: XCTestCase {
    private let configuration = FSKConfiguration.standard

    func testConfigurationIsValidForCommonIPhoneSampleRates() throws {
        for rate in [16_000.0, 44_100, 48_000] {
            XCTAssertNoThrow(try configuration.validate(sampleRate: rate), "\(rate)")
        }
        XCTAssertEqual(configuration.analysisWindowSize(sampleRate: 48_000), 2048)
        XCTAssertEqual(configuration.analysisWindowSize(sampleRate: 44_100), 2048)
        XCTAssertEqual(configuration.hopSize(sampleRate: 48_000), 512)
        XCTAssertThrowsError(try configuration.validate(sampleRate: 8_000))
        XCTAssertThrowsError(try configuration.validate(sampleRate: 0))
    }

    func testAllSymbolFrequenciesAreDistinctAndAudible() {
        let frequencies = configuration.allSymbols.map(configuration.frequency(for:))
        XCTAssertEqual(Set(frequencies).count, frequencies.count)
        XCTAssertEqual(frequencies.min(), 1_500)
        XCTAssertEqual(frequencies.max(), 4_650)
    }

    func testTooShortSeparatorIsRejectedByValidation() {
        var config = configuration
        config.separatorDuration = 0.03
        XCTAssertThrowsError(try config.validate(sampleRate: 48_000)) {
            guard case .segmentTooShortForDetection = $0 as? ConfigurationError else { return XCTFail("\($0)") }
        }
    }

    func testEveryToneIsClassifiedAtBothSampleRates() throws {
        for rate in [44_100.0, 48_000] {
            let detector = try ToneDetector(configuration: configuration, sampleRate: rate)
            for symbol in configuration.allSymbols {
                let frame = sine(configuration.frequency(for: symbol), rate, count: detector.windowSize, amplitude: 0.3)
                XCTAssertEqual(detector.classify(frame[...]), symbol, "\(symbol) at \(rate) Hz")
            }
        }
    }

    func testDetectionIsAmplitudeIndependentAboveTheSilenceGate() throws {
        let detector = try ToneDetector(configuration: configuration, sampleRate: 48_000)
        for amplitude: Float in [0.002, 0.05, 1.0] {
            let frame = sine(configuration.frequency(for: .data(7)), 48_000, count: detector.windowSize, amplitude: amplitude)
            XCTAssertEqual(detector.classify(frame[...]), .data(7), "amplitude \(amplitude)")
        }
    }

    func testRejectsSilenceNoiseOffBandAndMixedTones() throws {
        let detector = try ToneDetector(configuration: configuration, sampleRate: 48_000)
        let n = detector.windowSize
        XCTAssertNil(detector.classify([Float](repeating: 0, count: n)[...]))

        var rng = DeterministicRandom(seed: 1)
        let noise = (0..<n).map { _ in rng.nextSignedUnit() * 0.2 }
        XCTAssertNil(detector.classify(noise[...]), "white noise")

        XCTAssertNil(detector.classify(sine(1_000, 48_000, count: n, amplitude: 0.5)[...]), "off-band 1 kHz")
        XCTAssertNil(detector.classify(sine(6_000, 48_000, count: n, amplitude: 0.5)[...]), "off-band 6 kHz")

        let a = sine(configuration.frequency(for: .data(3)), 48_000, count: n, amplitude: 0.3)
        let b = sine(configuration.frequency(for: .separator), 48_000, count: n, amplitude: 0.3)
        XCTAssertNil(detector.classify(zip(a, b).map { $0 + $1 }[...]), "two equal tones")
    }

    func testToneIsFoundUnderModerateNoise() throws {
        let detector = try ToneDetector(configuration: configuration, sampleRate: 48_000)
        var rng = DeterministicRandom(seed: 7)
        let tone = sine(configuration.frequency(for: .data(12)), 48_000, count: detector.windowSize, amplitude: 0.3)
        let noisy = tone.map { $0 + rng.nextSignedUnit() * 0.1 }
        XCTAssertEqual(detector.classify(noisy[...]), .data(12))
    }

    /// Guards the vDSP scaling assumption: on Apple platforms the default analyzer is Accelerate's FFT,
    /// and it must report the same |X[k]|² as the reference Goertzel implementation.
    func testDefaultAnalyzerMatchesReferenceGoertzel() {
        let size = 2048
        let reference = GoertzelSpectrumAnalyzer(size: size)
        let production = makeDefaultSpectrumAnalyzer(size: size)
        var rng = DeterministicRandom(seed: 3)
        let frame = zip(sine(2_100, 48_000, count: size, amplitude: 0.4), (0..<size).map { _ in rng.nextSignedUnit() * 0.05 })
            .map { $0 + $1 }
        let bins = [10, 85, 89, 90, 91, 150, 199, 500]
        let expected = reference.binPowers(frame[...], bins: bins)
        let actual = production.binPowers(frame[...], bins: bins)
        for (e, a) in zip(expected, actual) {
            XCTAssertEqual(a, e, accuracy: max(1e-3, e * 1e-3))
        }
    }
}

func sine(_ frequency: Double, _ sampleRate: Double, count: Int, amplitude: Float) -> [Float] {
    (0..<count).map { Float(Double(amplitude) * sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
}

/// SplitMix64: reproducible noise without relying on platform random generators.
struct DeterministicRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [-1, 1).
    mutating func nextSignedUnit() -> Float {
        Float(Double(next() >> 11) / Double(1 << 53) * 2 - 1)
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}
