#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A single tone of the on-air alphabet.
public enum ToneSymbol: Hashable, Sendable, CustomStringConvertible {
    /// Frame preamble marker.
    case start
    /// Frame terminator marker.
    case end
    /// Separator sent after every data tone so repeated nibbles stay distinguishable.
    case separator
    /// One 4-bit data value, 0...15.
    case data(UInt8)

    public var description: String {
        switch self {
        case .start: return "START"
        case .end: return "END"
        case .separator: return "SEP"
        case .data(let nibble): return "D\(nibble)"
        }
    }
}

public enum ConfigurationError: Error, Equatable, Sendable {
    case invalidSampleRate(Double)
    case frequencyAboveNyquistMargin(frequency: Double, sampleRate: Double)
    case tonesTooClose(spacingInBins: Double)
    case segmentTooShortForDetection(symbol: String, fullWindows: Int, required: Int)
    case invalidParameter(String)
}

/// Every timing, frequency and threshold of the modem. Sender and receiver must use the same values.
///
/// Defaults are deliberately conservative and audible (1.5–4.65 kHz) so ordinary iPhone speakers and
/// microphones reproduce them well. Throughput is roughly 2.3 bytes per second.
public struct FSKConfiguration: Equatable, Sendable {
    public static let dataToneCount = 16
    public static let bitsPerDataTone = 4

    public var dataBaseFrequency: Double = 1_500
    public var dataToneSpacing: Double = 150
    public var separatorFrequency: Double = 4_050
    public var startFrequency: Double = 4_350
    public var endFrequency: Double = 4_650

    public var dataToneDuration: Double = 0.12
    public var separatorDuration: Double = 0.10
    public var markerDuration: Double = 0.30
    public var leadingSilenceDuration: Double = 0.15
    public var trailingSilenceDuration: Double = 0.15
    /// Raised-cosine fade at both ends of every tone to avoid clicks and spectral splatter.
    public var rampDuration: Double = 0.005
    public var amplitude: Float = 0.5

    public var maxPayloadBytes: Int = 32

    /// Target analysis window; the real window is the nearest power of two in samples.
    public var analysisWindowDuration: Double = 0.04
    /// Hop = window / hopDivisor.
    public var hopDivisor: Int = 4
    /// Consecutive windows with the same classification needed to accept a tone.
    public var minimumRunWindows: Int = 3
    /// Best candidate's power must exceed the runner-up by this factor.
    public var minimumDominance: Float = 2.5
    /// Fraction of the window's energy that must sit in the winning tone (1.0 = pure on-bin tone).
    public var minimumToneEnergyFraction: Float = 0.25
    /// Windows quieter than this RMS (full scale = 1.0) are treated as silence.
    public var minimumRMS: Float = 0.0005
    /// A started frame with no accepted tone for this long is abandoned.
    public var frameTimeoutDuration: Double = 1.5

    public static let standard = FSKConfiguration()

    public init() {}

    public func frequency(for symbol: ToneSymbol) -> Double {
        switch symbol {
        case .start: return startFrequency
        case .end: return endFrequency
        case .separator: return separatorFrequency
        case .data(let nibble): return dataBaseFrequency + Double(nibble) * dataToneSpacing
        }
    }

    public func duration(for symbol: ToneSymbol) -> Double {
        switch symbol {
        case .start, .end: return markerDuration
        case .separator: return separatorDuration
        case .data: return dataToneDuration
        }
    }

    /// Every symbol the detector must discriminate between.
    public var allSymbols: [ToneSymbol] {
        (0..<UInt8(Self.dataToneCount)).map { ToneSymbol.data($0) } + [.separator, .start, .end]
    }

    public func analysisWindowSize(sampleRate: Double) -> Int {
        let target = max(analysisWindowDuration * sampleRate, 64)
        let exponent = Int((log2(target)).rounded())
        return 1 << exponent
    }

    public func hopSize(sampleRate: Double) -> Int {
        max(1, analysisWindowSize(sampleRate: sampleRate) / hopDivisor)
    }

    /// Checks that the configuration can be demodulated at `sampleRate`.
    public func validate(sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate >= 8_000 else {
            throw ConfigurationError.invalidSampleRate(sampleRate)
        }
        guard hopDivisor >= 1, minimumRunWindows >= 1, maxPayloadBytes >= 1, maxPayloadBytes <= 255,
              amplitude > 0, amplitude <= 1, rampDuration >= 0 else {
            throw ConfigurationError.invalidParameter("hopDivisor, minimumRunWindows, maxPayloadBytes (1...255), amplitude or rampDuration")
        }
        let frequencies = allSymbols.map(frequency(for:)).sorted()
        for frequency in frequencies where frequency >= 0.45 * sampleRate || frequency <= 0 {
            throw ConfigurationError.frequencyAboveNyquistMargin(frequency: frequency, sampleRate: sampleRate)
        }
        let window = analysisWindowSize(sampleRate: sampleRate)
        let binWidth = sampleRate / Double(window)
        let minimumSpacing = zip(frequencies, frequencies.dropFirst()).map { $1 - $0 }.min() ?? 0
        // The detector looks at ±1 bin around each tone; Hann's main lobe is ±2 bins.
        guard minimumSpacing / binWidth >= 4 else {
            throw ConfigurationError.tonesTooClose(spacingInBins: minimumSpacing / binWidth)
        }
        let hop = hopSize(sampleRate: sampleRate)
        for symbol in [ToneSymbol.start, .separator, .data(0)] {
            let segment = Int((duration(for: symbol) * sampleRate).rounded())
            // Worst-case alignment: windows fully inside the segment.
            let fullWindows = segment >= window ? (segment - window) / hop : 0
            guard fullWindows >= minimumRunWindows else {
                throw ConfigurationError.segmentTooShortForDetection(
                    symbol: symbol.description, fullWindows: fullWindows, required: minimumRunWindows)
            }
        }
    }
}
