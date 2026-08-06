import Accelerate
import Foundation

/// Turns a window of mono audio into one level per display column.
///
/// A real-time FFT with the parameters chosen for *this* display rather than
/// for analysis: 17 columns of at most 5 rows is a very low-resolution output,
/// so the job is to land energy in the right column and be stable frame to
/// frame, not to resolve pitch.
///
/// ## Log-spaced bands
///
/// FFT bins are linear in frequency and hearing is not: with 2048 samples at
/// 48 kHz each bin is ~23 Hz, so a linear split would give the bottom two
/// octaves a single column and the top octave nine. The band edges are
/// therefore geometric between ``minimumFrequency`` and ``maximumFrequency``,
/// which puts roughly one musical octave-and-a-bit in each column and makes
/// bass, mids and treble all visibly move.
///
/// A class rather than a struct because it owns a `vDSP` FFT setup, which is a
/// manually-managed allocation that has to be destroyed exactly once.
public final class SpectrumAnalyzer {

    /// Window size. A power of two for the FFT, and at 48 kHz about 43 ms —
    /// long enough to resolve bass, short enough that a fifteen-frames-a-second
    /// display is not showing stale audio.
    public static let windowSize = 2048

    /// Bottom of the displayed range. Below this is mostly rumble and DC.
    public static let minimumFrequency: Float = 40
    /// Top of the displayed range. Above this there is little musical energy
    /// and the columns would sit dark.
    public static let maximumFrequency: Float = 16_000

    public let sampleRate: Float
    public let bandCount: Int

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: [Float]
    /// Inclusive bin range for each band, precomputed once.
    private let bandBins: [(lower: Int, upper: Int)]

    /// - Parameters:
    ///   - sampleRate: the capture rate, e.g. 48000.
    ///   - bandCount: how many columns the display has.
    public init(sampleRate: Float, bandCount: Int) {
        precondition(bandCount > 0, "a spectrum needs at least one band")
        self.sampleRate = sampleRate
        self.bandCount = bandCount
        self.log2n = vDSP_Length(log2(Float(Self.windowSize)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("vDSP_create_fftsetup failed for \(Self.windowSize) samples")
        }
        self.fftSetup = setup

        // Hann: the spectrum is displayed, not measured, so leakage into
        // neighbouring columns matters more than amplitude accuracy.
        var hann = [Float](repeating: 0, count: Self.windowSize)
        vDSP_hann_window(&hann, vDSP_Length(Self.windowSize), Int32(vDSP_HANN_NORM))
        self.window = hann

        self.bandBins = Self.bandBinRanges(sampleRate: sampleRate, bandCount: bandCount)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Geometric band edges converted to inclusive FFT bin ranges.
    ///
    /// Exposed for testing: the mapping from bins to columns is the part of this
    /// file that can be wrong in a way nobody notices except that the display
    /// looks bass-heavy.
    static func bandBinRanges(sampleRate: Float, bandCount: Int) -> [(lower: Int, upper: Int)] {
        let binCount = windowSize / 2
        let binWidth = sampleRate / Float(windowSize)
        let ratio = pow(maximumFrequency / minimumFrequency, 1 / Float(bandCount))

        var ranges: [(lower: Int, upper: Int)] = []
        ranges.reserveCapacity(bandCount)
        var lowerFrequency = minimumFrequency
        for _ in 0..<bandCount {
            let upperFrequency = lowerFrequency * ratio
            var lower = Int((lowerFrequency / binWidth).rounded(.down))
            var upper = Int((upperFrequency / binWidth).rounded(.down))
            // Bin 0 is DC; never let a band include it.
            lower = max(1, min(lower, binCount - 1))
            upper = max(lower, min(upper, binCount - 1))
            ranges.append((lower, upper))
            lowerFrequency = upperFrequency
        }
        return ranges
    }

    /// One magnitude per band for a window of samples, each roughly `0…1` for
    /// ordinary programme material — but **not clamped**, because the caller's
    /// gain stage is what decides what counts as full scale.
    ///
    /// Fewer samples than ``windowSize`` are zero-padded; more are truncated.
    public func levels(from samples: [Float]) -> [Float] {
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

        // Normalise out the transform length so the scale does not depend on
        // the window size, then take each band's mean.
        var scale = 2 / Float(Self.windowSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(magnitudes.count))

        return bandBins.map { range in
            let slice = magnitudes[range.lower...range.upper]
            var mean: Float = 0
            vDSP_meanv(Array(slice), 1, &mean, vDSP_Length(slice.count))
            return mean
        }
    }
}
