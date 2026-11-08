#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Renders a symbol sequence into mono Float32 PCM in -1...1.
public enum ToneSynthesizer {
    public static func sampleCount(for symbols: [ToneSymbol], configuration: FSKConfiguration, sampleRate: Double) -> Int {
        silenceSamples(configuration.leadingSilenceDuration, sampleRate)
            + symbols.reduce(0) { $0 + segmentSamples(configuration.duration(for: $1), sampleRate) }
            + silenceSamples(configuration.trailingSilenceDuration, sampleRate)
    }

    public static func render(symbols: [ToneSymbol], configuration: FSKConfiguration, sampleRate: Double) -> [Float] {
        var output = [Float](repeating: 0, count: sampleCount(for: symbols, configuration: configuration, sampleRate: sampleRate))
        var index = silenceSamples(configuration.leadingSilenceDuration, sampleRate)
        // Phase is carried across segments so tone changes do not introduce discontinuities.
        var phase = 0.0
        let ramp = Int((configuration.rampDuration * sampleRate).rounded())
        let amplitude = Double(configuration.amplitude)

        for symbol in symbols {
            let count = segmentSamples(configuration.duration(for: symbol), sampleRate)
            let increment = 2 * Double.pi * configuration.frequency(for: symbol) / sampleRate
            let segmentRamp = min(ramp, count / 2)
            for i in 0..<count {
                var gain = 1.0
                if segmentRamp > 0 {
                    if i < segmentRamp {
                        gain = 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(segmentRamp))
                    } else if i >= count - segmentRamp {
                        gain = 0.5 - 0.5 * cos(Double.pi * Double(count - 1 - i) / Double(segmentRamp))
                    }
                }
                output[index + i] = Float(amplitude * gain * sin(phase))
                phase += increment
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            }
            index += count
        }
        return output
    }

    private static func segmentSamples(_ duration: Double, _ sampleRate: Double) -> Int {
        max(1, Int((duration * sampleRate).rounded()))
    }

    private static func silenceSamples(_ duration: Double, _ sampleRate: Double) -> Int {
        max(0, Int((duration * sampleRate).rounded()))
    }
}
