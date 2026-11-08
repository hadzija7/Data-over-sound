#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Classifies one analysis window as one of the configured tones, or nil (silence, noise, speech,
/// a tone transition, or anything else that is not clearly a single alphabet tone).
public final class ToneDetector {
    public let configuration: FSKConfiguration
    public let sampleRate: Double
    public let windowSize: Int
    public let hopSize: Int

    private let analyzer: SpectrumAnalyzer
    private let candidates: [ToneSymbol]
    private let queriedBins: [Int]
    /// For each candidate, indices into `queriedBins` of its centre bin and immediate neighbours.
    private let candidateBinIndices: [[Int]]
    private let window: [Float]
    /// |X[k]|² / Σ(x·w)² for a pure on-bin sinusoid, i.e. (Σw)² / (2·Σw²).
    private let pureToneRatio: Float

    public init(configuration: FSKConfiguration, sampleRate: Double, analyzer: SpectrumAnalyzer? = nil) throws {
        try configuration.validate(sampleRate: sampleRate)
        self.configuration = configuration
        self.sampleRate = sampleRate
        self.windowSize = configuration.analysisWindowSize(sampleRate: sampleRate)
        self.hopSize = configuration.hopSize(sampleRate: sampleRate)
        let analyzer = analyzer ?? makeDefaultSpectrumAnalyzer(size: windowSize)
        precondition(analyzer.size == windowSize, "analyzer size must equal the analysis window size")
        self.analyzer = analyzer

        let binWidth = sampleRate / Double(windowSize)
        candidates = configuration.allSymbols
        var bins: [Int] = []
        var indices: [[Int]] = []
        for symbol in candidates {
            let centre = Int((configuration.frequency(for: symbol) / binWidth).rounded())
            var own: [Int] = []
            for bin in (centre - 1)...(centre + 1) where bin > 0 && bin < windowSize / 2 {
                own.append(bins.count)
                bins.append(bin)
            }
            indices.append(own)
        }
        queriedBins = bins
        candidateBinIndices = indices

        window = hannWindow(size: windowSize)
        let sum = window.reduce(0, +)
        let sumOfSquares = window.reduce(0) { $0 + $1 * $1 }
        pureToneRatio = sum * sum / (2 * sumOfSquares)
    }

    public func classify(_ frame: ArraySlice<Float>) -> ToneSymbol? {
        precondition(frame.count == windowSize, "frame length \(frame.count) != window size \(windowSize)")
        var sumOfSquares: Float = 0
        var windowedEnergy: Float = 0
        let start = frame.startIndex
        for n in 0..<windowSize {
            let sample = frame[start + n]
            sumOfSquares += sample * sample
            let weighted = sample * window[n]
            windowedEnergy += weighted * weighted
        }
        let rms = (sumOfSquares / Float(windowSize)).squareRoot()
        guard rms.isFinite, rms >= configuration.minimumRMS, windowedEnergy > 0 else { return nil }

        let powers = analyzer.binPowers(frame, bins: queriedBins)
        var best = -1
        var bestPower: Float = 0
        var secondPower: Float = 0
        for (candidate, binIndices) in candidateBinIndices.enumerated() {
            let power = binIndices.reduce(Float(0)) { max($0, powers[$1]) }
            if power > bestPower {
                secondPower = bestPower
                bestPower = power
                best = candidate
            } else if power > secondPower {
                secondPower = power
            }
        }
        guard best >= 0, bestPower.isFinite else { return nil }
        let energyFraction = bestPower / (windowedEnergy * pureToneRatio)
        guard energyFraction >= configuration.minimumToneEnergyFraction else { return nil }
        guard secondPower == 0 || bestPower >= configuration.minimumDominance * secondPower else { return nil }
        return candidates[best]
    }
}
