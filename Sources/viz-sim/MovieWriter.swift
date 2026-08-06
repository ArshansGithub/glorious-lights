import AVFoundation
import CoreGraphics
import Foundation

/// Writes rendered frames to an H.264 `.mp4` at the display frame rate.
///
/// Stills cannot answer the question this redesign is about. "Does it flow with
/// the music" is a statement about motion over seconds, so the simulator has to
/// produce something that moves — otherwise every judgement needs the human, a
/// keyboard and a stereo, which is exactly the loop this tooling exists to
/// break.
final class MovieWriter {

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let frameRate: Double
    private var frameIndex: Int64 = 0

    init(url: URL, size: CGSize, frameRate: Double) throws {
        // AVAssetWriter refuses to overwrite, and a tuning loop reruns the same
        // command constantly.
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        self.frameRate = frameRate

        // Dimensions must be even for H.264.
        let width = Int(size.width) & ~1
        let height = Int(size.height) & ~1

        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                // The board is flat colour on a dark field, so quality costs
                // little and blocking artefacts would be mistaken for the
                // visualizer doing something.
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ],
        ])
        input.expectsMediaDataInRealTime = false

        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])

        guard writer.canAdd(input) else { throw SimError.movieFailed(url.path) }
        writer.add(input)
        guard writer.startWriting() else {
            throw SimError.movieFailed(writer.error?.localizedDescription ?? url.path)
        }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ image: CGImage) throws {
        guard let pool = adaptor.pixelBufferPool else {
            throw SimError.movieFailed("no pixel buffer pool")
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let pixelBuffer = buffer else {
            throw SimError.movieFailed("could not allocate a pixel buffer")
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
            throw SimError.movieFailed("could not draw into the pixel buffer")
        }
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: CVPixelBufferGetWidth(pixelBuffer),
                                       height: CVPixelBufferGetHeight(pixelBuffer)))

        // The writer is not real-time, so waiting is correct rather than
        // dropping frames — every frame of the analysis should appear.
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.002)
        }
        let time = CMTime(value: frameIndex, timescale: CMTimeScale(frameRate.rounded()))
        guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
            throw SimError.movieFailed(writer.error?.localizedDescription ?? "append failed")
        }
        frameIndex += 1
    }

    func finish() throws {
        input.markAsFinished()
        let waiter = DispatchSemaphore(value: 0)
        writer.finishWriting { waiter.signal() }
        waiter.wait()
        if writer.status == .failed {
            throw SimError.movieFailed(writer.error?.localizedDescription ?? "unknown")
        }
    }
}
