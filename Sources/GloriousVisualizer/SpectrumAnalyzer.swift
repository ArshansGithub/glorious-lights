import Accelerate
import Foundation

/// The FFT front end: a window of mono audio in, a magnitude spectrum out.
///
/// It does the transform and nothing else. Every level decision that used to
/// live here — a fixed pink-noise tilt across the bands, a per-band mean scaled
/// by a static weight — has moved to ``AdaptiveWhitening``, which learns the
/// tilt of *this* material instead of assuming one.
///
/// Window 2048 / hop 512 gives 93.75 Hz at 48 kHz. **Latency is set by the hop,
/// not the window**: shrinking the window to chase latency costs low-frequency
/// resolution, which is exactly where kick discrimination lives.
///
/// A class rather than a struct because it owns a `vDSP` FFT setup, a manually
/// managed allocation that must be destroyed exactly once.
public final class SpectrumAnalyzer {

    /// Window size, a power of two: 2048 is ~43 ms at 48 kHz, enough to resolve
    /// the bottom two octaves.
    public static let windowSize = 2048

    /// Band edges in Hz (§2.1). Eight bands, log-spaced, named for what they
    /// carry rather than for an arbitrary split.
    public static let bandEdges: [Float] = [20, 60, 120, 250, 500, 1_000, 2_500, 6_000, 16_000]

    /// Which bands each display register is formed from — a view of the band
    /// set, not a second analysis.
    public static let registerBands: [ClosedRange<Int>] = [0...1, 2...2, 3...3, 4...4, 5...6, 7...7]

    public let sampleRate: Float
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: [Float]

    /// Inclusive bin range per band, precomputed.
    public let bandBins: [(lower: Int, upper: Int)]

    public init(sampleRate: Float) {
        self.sampleRate = sampleRate
        self.log2n = vDSP_Length(log2(Float(Self.windowSize)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("vDSP_create_fftsetup failed for \(Self.windowSize) samples")
        }
        self.fftSetup = setup

        var hann = [Float](repeating: 0, count: Self.windowSize)
        vDSP_hann_window(&hann, vDSP_Length(Self.windowSize), Int32(vDSP_HANN_NORM))
        self.window = hann

        let binWidth = sampleRate / Float(Self.windowSize)
        let binCount = Self.windowSize / 2
        self.bandBins = (0..<(Self.bandEdges.count - 1)).map { index in
            // Bin 0 is DC; never let a band include it.
            let lower = max(1, min(Int(Self.bandEdges[index] / binWidth), binCount - 1))
            let upper = max(lower, min(Int(Self.bandEdges[index + 1] / binWidth), binCount - 1))
            return (lower, upper)
        }
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Number of spectrum bins produced.
    public var binCount: Int { Self.windowSize / 2 }

    /// The magnitude spectrum of one window.
    public func magnitudes(from samples: [Float]) -> [Float] {
        var real = [Float](repeating: 0, count: Self.windowSize)
        let count = min(samples.count, Self.windowSize)
        real.replaceSubrange(0..<count, with: samples[0..<count])
        vDSP_vmul(real, 1, window, 1, &real, 1, vDSP_Length(Self.windowSize))

        var imaginary = [Float](repeating: 0, count: Self.windowSize)
        var magnitudes = [Float](repeating: 0, count: Self.windowSize / 2)

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!,
                                            imagp: imaginaryPointer.baseAddress!)
                vDSP_fft_zip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(Self.windowSize / 2))
            }
        }

        var scale = 2 / Float(Self.windowSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(magnitudes.count))
        return magnitudes
    }

    /// Inclusive bin range covering a frequency span, clamped into the spectrum.
    public func binRange(forHz range: ClosedRange<Float>) -> (lower: Int, upper: Int) {
        let binWidth = sampleRate / Float(Self.windowSize)
        let lower = max(1, Int(range.lowerBound / binWidth))
        let upper = min(Self.windowSize / 2 - 1, Int(range.upperBound / binWidth))
        return (lower, max(lower, upper))
    }

    /// Spectral centroid in Hz of an already-whitened spectrum — the closest
    /// single number to how *bright* a sound is.
    public func centroid(of spectrum: [Double]) -> Double {
        let binWidth = Double(sampleRate) / Double(Self.windowSize)
        var weighted: Double = 0
        var total: Double = 0
        for bin in 1..<spectrum.count {
            weighted += Double(bin) * binWidth * spectrum[bin]
            total += spectrum[bin]
        }
        return total > 1e-9 ? weighted / total : 0
    }
}
