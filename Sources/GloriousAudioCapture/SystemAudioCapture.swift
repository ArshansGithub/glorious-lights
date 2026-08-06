import AVFoundation
import CoreAudio
import Foundation
import GloriousVisualizer

/// Captures the system output mix using a CoreAudio **process tap**.
///
/// This is the modern route (macOS 14.2+) and it is the right one for a
/// visualizer: it taps the global output mix directly in the HAL, so it needs
/// no video pipeline, no window server involvement, and — importantly — the
/// permission it asks for is *Audio Recording* rather than *Screen Recording*.
/// The ScreenCaptureKit alternative would work but demands a far broader grant
/// for the sake of an audio-only capture.
///
/// ## How it fits together
///
/// Three CoreAudio objects, torn down in reverse:
///
/// 1. A **tap** (`AudioHardwareCreateProcessTap`) described as a mono global
///    mixdown excluding nothing — every process's output, summed. Mono because
///    the analyzer immediately downmixes anyway.
/// 2. A **private aggregate device** whose sub-tap list contains that tap. A tap
///    is not a device and cannot be read from directly; an aggregate is the
///    documented way to give it an I/O path.
/// 3. An **IOProc** on the aggregate, which is where samples arrive.
///
/// ## Permission
///
/// The tap is gated by the `kTCCServiceAudioCapture` TCC service, declared by
/// `NSAudioCaptureUsageDescription` in the bundle's `Info.plist`. There is **no
/// public API to query or request it ahead of time** the way
/// `AVCaptureDevice.requestAccess(for:)` does for the microphone: the prompt
/// appears when a tap is first created. So ``authorization`` reports
/// `undetermined` until a start has been attempted, and a failure to create the
/// tap is reported as `denied` — which is the honest reading, since "refused"
/// and "not permitted" are the same observation from here.
///
/// ## Availability
///
/// Process taps arrived in macOS 14.2, and the app supports 14.0, so the whole
/// class is gated. Below 14.2 ``isSupported`` is false and the picker reports
/// the source as unavailable rather than offering something that cannot work —
/// the alternative would be raising the app's floor for one optional feature.
@available(macOS 14.2, *)
public final class SystemAudioCapture: AudioSourceCapturing {

    /// Set once a tap has been created successfully, so the menu can stop
    /// saying "not yet asked" after the first attempt.
    private static var hasSucceededOnce = false
    /// Set when tap creation has failed, which is as close to "denied" as this
    /// API gets.
    private static var hasFailed = false

    public static var authorization: AudioSourceAuthorization {
        if hasSucceededOnce { return .granted }
        if hasFailed { return .denied }
        return .undetermined
    }

    public init() {}

    /// Everything the transport noticed, for the diagnostic tool. A tap that is
    /// created and then starved looks identical to one that was never created
    /// unless somebody is counting.
    public struct Diagnostics: Sendable {
        public var tapID: UInt32 = 0
        public var aggregateID: UInt32 = 0
        public var tapUID: String = ""
        public var streamFormat: String = ""
        public var ioProcCallbacks = 0
        public var framesDelivered = 0
        public var emptyCallbacks = 0
        /// Non-fatal `OSStatus` values, in the order they happened. Teardown
        /// used to discard these entirely.
        public var statuses: [(stage: String, status: OSStatus)] = []
    }

    private let diagnosticsLock = NSLock()
    private var diagnosticsStorage = Diagnostics()

    public var diagnostics: Diagnostics {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return diagnosticsStorage
    }

    private func record(_ stage: String, _ status: OSStatus) {
        guard status != noErr else { return }
        diagnosticsLock.lock()
        diagnosticsStorage.statuses.append((stage, status))
        diagnosticsLock.unlock()
    }

    private func withDiagnostics(_ body: (inout Diagnostics) -> Void) {
        diagnosticsLock.lock()
        body(&diagnosticsStorage)
        diagnosticsLock.unlock()
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    public private(set) var isRunning = false
    public private(set) var sampleRate: Double = 48_000
    public var onSamples: (([Float]) -> Void)?

    public enum CaptureError: Error, CustomStringConvertible {
        case tapCreationFailed(OSStatus)
        case tapUnreadable(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case startFailed(OSStatus)

        public var description: String {
            switch self {
            case .tapCreationFailed(let status):
                return "Could not create the system-audio tap (\(status)). macOS asks for "
                     + "Audio Recording permission the first time; if you have not seen a "
                     + "prompt, grant it in System Settings › Privacy & Security › "
                     + "Audio Recording."
            case .tapUnreadable(let status):
                return "The system-audio tap was created but could not be described (\(status))."
            case .aggregateCreationFailed(let status):
                return "Could not create the aggregate device for the tap (\(status))."
            case .ioProcFailed(let status):
                return "Could not attach to the aggregate device (\(status))."
            case .startFailed(let status):
                return "Could not start the aggregate device (\(status))."
            }
        }
    }

    // MARK: - Lifecycle

    public func start() throws {
        guard !isRunning else { return }

        // A private tap: it exists only for this process and does not appear in
        // other apps' device lists. Unmuted, because muting the tap would mute
        // what the user is listening to.
        //
        // `isExclusive` is deliberately NOT touched here. The header defines the
        // `processes` array as the *exclusion* list for a "global tap but
        // exclude" description, and `exclusive == true` is what makes it mean
        // that. Setting it to false — which this code used to do — reinterprets
        // the same empty array as an *inclusion* list, so the tap captures
        // exactly no processes: created successfully, started successfully, and
        // silent forever. That was the bug behind "the recording indicator
        // appears briefly and then stops".
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "Glorious Lights Visualizer"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != kAudioObjectUnknown else {
            Self.hasFailed = true
            throw CaptureError.tapCreationFailed(tapStatus)
        }
        tapID = tap
        Self.hasSucceededOnce = true
        Self.hasFailed = false
        withDiagnostics { $0.tapID = tap }

        do {
            let format = try readTapFormat()
            sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
            let uid = try readTapUID()
            withDiagnostics {
                $0.tapUID = uid
                $0.streamFormat = String(format: "%.0f Hz, %u ch, %u bits, flags 0x%x",
                                         format.mSampleRate, format.mChannelsPerFrame,
                                         format.mBitsPerChannel, format.mFormatFlags)
            }
            try createAggregate(tapUID: uid)
            try attachIOProc()
        } catch {
            teardown()
            throw error
        }
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        teardown()
        isRunning = false
    }

    /// Tears down in reverse order of creation, **recording every status**.
    ///
    /// These four calls used to have their results discarded, which is part of
    /// why a broken session produced nothing in the log: a failure to stop or
    /// destroy leaves HAL objects alive and the next start inherits the mess,
    /// with no trace of why.
    private func teardown() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            record("AudioDeviceStop", AudioDeviceStop(aggregateID, ioProcID))
            record("AudioDeviceDestroyIOProcID",
                   AudioDeviceDestroyIOProcID(aggregateID, ioProcID))
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            record("AudioHardwareDestroyAggregateDevice",
                   AudioHardwareDestroyAggregateDevice(aggregateID))
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        // The tap goes last: the aggregate refers to it.
        if tapID != kAudioObjectUnknown {
            record("AudioHardwareDestroyProcessTap", AudioHardwareDestroyProcessTap(tapID))
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { teardown() }

    // MARK: - Tap properties

    private func readTapFormat() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { throw CaptureError.tapUnreadable(status) }
        return format
    }

    /// The tap's UID, which is how the aggregate device refers to it.
    ///
    /// CoreAudio writes a **+1 retained** `CFStringRef` into the out-parameter —
    /// the header says the caller owns it — so it is taken through `Unmanaged`
    /// and consumed. Binding a `CFString` variable directly, as this used to,
    /// leaks the string and overwrites the previous value without releasing it.
    private func readTapUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let unmanaged else {
            throw CaptureError.tapUnreadable(status == noErr ? -1 : status)
        }
        return unmanaged.takeRetainedValue() as String
    }

    // MARK: - Aggregate device

    private func createAggregate(tapUID: String) throws {
        // Private, so it does not appear in Sound settings or in other apps'
        // device pickers — this device exists only to give the tap an I/O path.
        let uid = "com.glorious-lights.visualizer.tap.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Glorious Lights Visualizer",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // Autostart means `AudioDeviceStart` waits for a tapped process to
            // actually produce audio before the device runs — so starting the
            // visualizer in silence is not a failure, it is a device politely
            // waiting. The header requires the private key alongside it, which
            // is set above.
            kAudioAggregateDeviceTapAutoStartKey: true,
            // No sub-devices: the tap is the only source, and naming a real
            // output device here would route audio through the aggregate rather
            // than merely observing it.
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID],
            ],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr, aggregate != kAudioObjectUnknown else {
            throw CaptureError.aggregateCreationFailed(status)
        }
        aggregateID = aggregate
        withDiagnostics { $0.aggregateID = aggregate }
    }

    private func attachIOProc() throws {
        // The block runs on CoreAudio's real-time I/O thread. It must not
        // allocate unpredictably, block, or touch UI — it converts and hands
        // off, and the visualizer's own lock is the only thing it waits on.
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            [weak self] _, inputData, _, _, _ in
            guard let self else { return }
            self.handle(inputData)
        }
        guard status == noErr, ioProcID != nil else { throw CaptureError.ioProcFailed(status) }

        let startStatus = AudioDeviceStart(aggregateID, ioProcID)
        guard startStatus == noErr else { throw CaptureError.startFailed(startStatus) }
    }

    private func handle(_ inputData: UnsafePointer<AudioBufferList>) {
        withDiagnostics { $0.ioProcCallbacks += 1 }
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData))
        guard let first = buffers.first, let data = first.mData else {
            withDiagnostics { $0.emptyCallbacks += 1 }
            return
        }

        let frameCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        guard frameCount > 0 else {
            withDiagnostics { $0.emptyCallbacks += 1 }
            return
        }
        withDiagnostics { $0.framesDelivered += frameCount }
        let samples = data.bindMemory(to: Float.self, capacity: frameCount)

        // A tap asked for mono usually delivers one channel, but the format is
        // whatever the HAL decided, so interleaved multi-channel is folded down
        // rather than analysed as if it were mono.
        let channels = max(1, Int(first.mNumberChannels))
        if channels == 1 {
            onSamples?(Array(UnsafeBufferPointer(start: samples, count: frameCount)))
            return
        }
        let frames = frameCount / channels
        var mono = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += samples[frame * channels + channel] }
            mono[frame] = sum / Float(channels)
        }
        onSamples?(mono)
    }
}

/// Availability-independent entry points, so the menu and the visualizer can
/// ask about system audio without an `if #available` at every call site.
public enum SystemAudio {

    /// Whether this macOS has process taps at all (14.2+).
    public static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// The current authorization, or ``AudioSourceAuthorization/unavailable``
    /// on a system too old for process taps.
    public static var authorization: AudioSourceAuthorization {
        guard #available(macOS 14.2, *) else { return .unavailable }
        return SystemAudioCapture.authorization
    }

    /// A capture object, or `nil` if this system cannot do it.
    public static func makeCapture() -> AudioSourceCapturing? {
        guard #available(macOS 14.2, *) else { return nil }
        return SystemAudioCapture()
    }

    /// Formatted transport diagnostics for a capture this module produced, or
    /// `nil` if it is not a process tap.
    ///
    /// Returning lines rather than the struct keeps the availability check here
    /// instead of at every call site, and keeps `SystemAudioCapture` itself out
    /// of a tool's type-checking.
    public static func diagnosticLines(for capture: AudioSourceCapturing) -> [String]? {
        guard #available(macOS 14.2, *), let tap = capture as? SystemAudioCapture else {
            return nil
        }
        let diagnostics = tap.diagnostics
        var lines = [
            "tap object:        \(diagnostics.tapID)",
            "aggregate device:  \(diagnostics.aggregateID)",
            "tap UID:           \(diagnostics.tapUID)",
            "stream format:     \(diagnostics.streamFormat)",
            "IO proc callbacks: \(diagnostics.ioProcCallbacks)",
            "frames delivered:  \(diagnostics.framesDelivered)",
            "empty callbacks:   \(diagnostics.emptyCallbacks)",
        ]
        if diagnostics.statuses.isEmpty {
            lines.append("no non-zero OSStatus values")
        } else {
            lines += diagnostics.statuses.map { "\($0.stage) -> OSStatus \($0.status)" }
        }
        return lines
    }
}
