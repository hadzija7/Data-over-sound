#if canImport(Accelerate)
import Accelerate
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Computes Hann-windowed DFT power, |X[k]|², at selected bins of a fixed-size frame.
///
/// Implementations must return the unscaled DFT definition so thresholds are backend-independent.
/// Instances keep scratch buffers and are not thread-safe; use one per processing queue.
public protocol SpectrumAnalyzer: AnyObject {
    var size: Int { get }
    func binPowers(_ frame: ArraySlice<Float>, bins: [Int]) -> [Float]
}

public func hannWindow(size: Int) -> [Float] {
    // Periodic Hann, 0.5·(1 − cos(2πn/N)); matches vDSP_hann_window(..., vDSP_HANN_DENORM), not _NORM (which scales by 0.8165·2).
    (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) }
}

/// Production analyzer: Accelerate's vDSP real FFT on Apple platforms, Goertzel elsewhere.
public func makeDefaultSpectrumAnalyzer(size: Int) -> SpectrumAnalyzer {
    #if canImport(Accelerate)
    return AccelerateSpectrumAnalyzer(size: size)
    #else
    return GoertzelSpectrumAnalyzer(size: size)
    #endif
}

/// Portable reference implementation (per-bin Goertzel). Used for tests on Linux and to cross-check vDSP.
public final class GoertzelSpectrumAnalyzer: SpectrumAnalyzer {
    public let size: Int
    private let window: [Float]

    public init(size: Int) {
        precondition(size > 0)
        self.size = size
        self.window = hannWindow(size: size)
    }

    public func binPowers(_ frame: ArraySlice<Float>, bins: [Int]) -> [Float] {
        precondition(frame.count == size, "frame length \(frame.count) != analyzer size \(size)")
        let start = frame.startIndex
        return bins.map { bin in
            let coefficient = 2 * cos(2 * Double.pi * Double(bin) / Double(size))
            var s1 = 0.0
            var s2 = 0.0
            for n in 0..<size {
                let s0 = Double(frame[start + n] * window[n]) + coefficient * s1 - s2
                s2 = s1
                s1 = s0
            }
            return Float(max(0, s1 * s1 + s2 * s2 - coefficient * s1 * s2))
        }
    }
}

#if canImport(Accelerate)
/// vDSP radix-2 real FFT. Size must be a power of two.
public final class AccelerateSpectrumAnalyzer: SpectrumAnalyzer {
    public let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var powers: [Float]

    public init(size: Int) {
        precondition(size >= 4 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        self.log2n = vDSP_Length(size.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed for size \(size)")
        }
        self.setup = setup
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
        self.window = window
        self.windowed = [Float](repeating: 0, count: size)
        self.real = [Float](repeating: 0, count: size / 2)
        self.imaginary = [Float](repeating: 0, count: size / 2)
        self.powers = [Float](repeating: 0, count: size / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    public func binPowers(_ frame: ArraySlice<Float>, bins: [Int]) -> [Float] {
        precondition(frame.count == size, "frame length \(frame.count) != analyzer size \(size)")
        let half = size / 2
        frame.withUnsafeBufferPointer { input in
            vDSP_vmul(input.baseAddress!, 1, window, 1, &windowed, 1, vDSP_Length(size))
        }
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &powers, 1, vDSP_Length(half))
            }
        }
        // vDSP's forward real FFT returns 2·X[k], so power is 4·|X[k]|². Bin 0 packs DC/Nyquist and is never queried.
        return bins.map { bin in
            precondition(bin > 0 && bin < half, "bin \(bin) out of range")
            return powers[bin] * 0.25
        }
    }
}
#endif
