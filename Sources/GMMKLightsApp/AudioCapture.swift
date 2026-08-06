import AVFoundation
import Foundation

/// Microphone capture for the visualizer: a tap on the input node that hands
/// mono `Float` windows to a callback.
///
/// Deliberately thin. It knows nothing about spectra or keyboards — it starts an
/// engine, downmixes whatever the device gives it, and calls back. Everything
/// interesting happens downstream, where it can be tested without a microphone.
final class AudioCapture {

    /// Whether the user has granted, denied, or not yet been asked.
    enum Authorization {
        case granted
        case denied
        case undetermined

        /// The current state, without prompting.
        static var current: Authorization {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:            return .granted
            case .denied, .restricted:   return .denied
            case .notDetermined:         return .undetermined
            @unknown default:            return .denied
            }
        }
    }

    /// Samples per callback. Matches the analyzer's window so a frame is one
    /// window rather than a re-buffered fraction of one.
    static let bufferSize: AVAudioFrameCount = 2048

    private let engine = AVAudioEngine()
    private(set) var isRunning = false

    /// Called on AVAudioEngine's own render thread with mono samples. Keep it
    /// short — it must not block, and it must not touch UI.
    var onSamples: (([Float]) -> Void)?

    /// The sample rate the input is actually running at, once started.
    private(set) var sampleRate: Double = 48_000

    enum StartError: Error, CustomStringConvertible {
        case notAuthorized
        case noInput
        case engineFailed(String)

        var description: String {
            switch self {
            case .notAuthorized:
                return "Microphone access has not been granted."
            case .noInput:
                return "No audio input device is available."
            case .engineFailed(let message):
                return "The audio engine did not start: \(message)"
            }
        }
    }

    /// Asks for microphone access, prompting the first time.
    ///
    /// The completion is delivered on the main queue: AVFoundation calls back on
    /// an arbitrary one, and every caller here goes on to touch the menu.
    static func requestAuthorization(_ completion: @escaping (Authorization) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted ? .granted : .denied) }
        }
    }

    /// Starts the engine and installs the tap.
    ///
    /// - Throws: ``StartError`` — the caller shows this rather than failing
    ///   silently, because "the visualizer does nothing" is otherwise
    ///   indistinguishable from silence in the room.
    func start() throws {
        guard !isRunning else { return }
        guard Authorization.current == .granted else { throw StartError.notAuthorized }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw StartError.noInput }
        sampleRate = format.sampleRate

        input.installTap(onBus: 0, bufferSize: Self.bufferSize, format: format) {
            [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }

            // Downmix by averaging: a stereo input whose channels are out of
            // phase would cancel if summed, and the display should show what is
            // playing rather than the mid signal only.
            let channelCount = Int(buffer.format.channelCount)
            var mono = [Float](repeating: 0, count: frames)
            for channel in 0..<channelCount {
                let samples = channels[channel]
                for frame in 0..<frames { mono[frame] += samples[frame] }
            }
            if channelCount > 1 {
                let scale = 1 / Float(channelCount)
                for frame in 0..<frames { mono[frame] *= scale }
            }
            self.onSamples?(mono)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw StartError.engineFailed(error.localizedDescription)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    deinit { stop() }
}
