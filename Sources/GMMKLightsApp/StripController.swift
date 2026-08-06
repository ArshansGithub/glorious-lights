import Foundation
import StripProtocol
import StripBLE

/// Owns the Bluetooth strip transport and turns look changes into frames.
///
/// Main-thread only, like ``KeyboardController`` and ``MouseController``.
///
/// **Not yet wired into the menu, the visualizer or ``SyncCoordinator``.** This
/// is the seam those hookups will use, written ahead of the hardware; the strip
/// arrives before it can be connected to anything, and connecting a visualizer
/// to a device whose protocol family is still a guess would mean debugging two
/// unknowns at once. Identify the strip with `gmmk-cli strip` first, then wire
/// this in.
///
/// ## Why this one is asynchronous when the other two are not
///
/// The keyboard and the mouse are synchronous HID: a write is a syscall that
/// either worked or did not, and ``SyncCoordinator`` can drive both inline.
/// Bluetooth is nothing like that. Scanning takes seconds, connecting takes
/// hundreds of milliseconds, and a write is queued rather than performed. So
/// everything here is callback-driven and every accessor is a snapshot of
/// state, never a blocking question.
///
/// ## Write pacing
///
/// ``minimumWriteInterval`` caps writes at 20 Hz, and this is the number most
/// worth getting right when the visualizer is eventually connected.
///
/// A BLE connection carries one packet per *connection interval*, which macOS
/// negotiates to somewhere in the 15–30 ms range for a peripheral like this.
/// Frames written faster than that do not travel faster — they queue in the
/// controller's buffer, and every one of them adds latency to the frame behind
/// it. A visualizer running at 60 Hz into a 30 Hz link does not produce a fast
/// strip; it produces a strip that is a growing number of frames behind the
/// music, which reads as the effect drifting out of sync and never recovering.
///
/// So writes are dropped, not queued: if a colour arrives before the interval
/// has elapsed it replaces any colour still waiting, and only the newest is
/// sent when the window opens. For a visualizer, the newest frame is the only
/// one that was ever worth sending.
@MainActor
final class StripController {

    // MARK: - Configuration

    /// The floor between writes. 20 Hz — see the note above; this is a latency
    /// ceiling, not a throughput target.
    static let minimumWriteInterval: TimeInterval = 1.0 / 20.0

    /// How long a scan runs when looking for the configured strip.
    static let scanSeconds: TimeInterval = 6

    // MARK: - State

    private let central = StripCentral()

    /// The device this controller is configured to drive, by name or
    /// identifier. `nil` disables the controller entirely — which is the state
    /// it ships in until a user has identified their strip.
    private(set) var deviceQuery: String?

    /// The family to speak. Set explicitly rather than identified at runtime:
    /// the CLI is where identification belongs, because that is where a human
    /// can watch the strip and say which frame worked.
    private(set) var family: StripFamily?

    private(set) var report: StripDeviceReport?
    private(set) var isConnected = false
    private(set) var lastError: String?

    /// The colour last actually written, as opposed to last requested.
    private(set) var currentColor: StripRGB?

    /// Fires whenever any of the above changes, so a menu can redraw.
    var onStatusChange: (() -> Void)?

    /// Whether this controller has enough configuration to do anything.
    var isConfigured: Bool { deviceQuery != nil && family != nil }

    /// Whether a strip is present and ready to take frames.
    var isAvailable: Bool { isConnected && report != nil && family != nil }

    // MARK: - Pacing

    private var isScanning = false
    private var scanTimeoutTimer: Timer?

    private var lastWriteTime: Date?
    /// A colour that arrived inside the pacing window and is waiting for it to
    /// open. At most one — a newer colour replaces it rather than queueing
    /// behind it.
    private var pendingColor: StripRGB?
    private var flushTimer: Timer?

    // MARK: - Lifecycle

    init() {
        central.onDisconnect = { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isConnected = false
                self.report = nil
                self.currentColor = nil
                self.pendingColor = nil
                self.lastError = error?.description
                self.onStatusChange?()
            }
        }
        central.onDiscover = { [weak self] result in
            MainActor.assumeIsolated { self?.considerScanResult(result) }
        }
        central.onConnect = { [weak self] in
            MainActor.assumeIsolated { try? self?.central.discoverServices() }
        }
        central.onServicesDiscovered = { [weak self] report in
            MainActor.assumeIsolated { self?.finishConnecting(with: report) }
        }
    }

    deinit {
        flushTimer?.invalidate()
        scanTimeoutTimer?.invalidate()
    }

    // MARK: - Connecting

    /// Starts looking for the configured strip. Returns immediately.
    ///
    /// Deliberately callback-driven rather than using ``StripBLE``'s blocking
    /// helpers, which exist for `gmmk-cli`. Those pump the current thread's run
    /// loop, so on the main thread they would freeze the menu, and on a
    /// background thread they would wait forever — CoreBluetooth delivers to
    /// the *main* queue, which a background thread cannot pump.
    func connect() {
        guard isConfigured, !isConnected, !isScanning else { return }
        guard central.state == .poweredOn else {
            // Nothing to do yet. The state callback will not fire again if it
            // is already settled, so record why rather than waiting silently.
            lastError = StripBLEError.forState(central.state)?.description
                ?? "Bluetooth is not ready yet."
            onStatusChange?()
            return
        }
        do {
            try central.startScan()
            isScanning = true
            lastError = nil
            scanTimeoutTimer?.invalidate()
            scanTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Self.scanSeconds,
                                                    repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.scanTimedOut() }
            }
        } catch {
            lastError = "\(error)"
        }
        onStatusChange?()
    }

    private func considerScanResult(_ result: StripScanResult) {
        guard isScanning, let query = deviceQuery else { return }
        let matchesName = result.displayName.lowercased().contains(query.lowercased())
        let matchesID = result.identifier.uuidString.caseInsensitiveCompare(query) == .orderedSame
        guard matchesName || matchesID else { return }

        endScan()
        do {
            try central.connect(result)
        } catch {
            lastError = "\(error)"
            onStatusChange?()
        }
    }

    private func scanTimedOut() {
        guard isScanning else { return }
        endScan()
        lastError = """
            No strip matching "\(deviceQuery ?? "")" advertised within \
            \(Int(Self.scanSeconds))s. These controllers only advertise while powered and \
            not already connected to something else.
            """
        onStatusChange?()
    }

    private func endScan() {
        isScanning = false
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = nil
        central.stopScan()
    }

    /// Runs the family's connect-time requirements, then declares the strip
    /// ready.
    ///
    /// MELK controllers ignore everything until their two login writes have
    /// gone out, and LEDnetWF ignores everything until notifications are on.
    /// The login writes are spaced by a timer rather than a sleep for the usual
    /// reason: this is the main thread.
    private func finishConnecting(with report: StripDeviceReport) {
        guard let family else { return }
        self.report = report

        if let notify = report.notifyCharacteristic(for: family) {
            central.subscribe(to: notify)
        } else if family.requiresNotifications {
            lastError = StripBLEError.noWritableCharacteristic(
                family: family,
                found: report.allCharacteristicUUIDs.map(\.shortDescription)).description
            onStatusChange?()
            return
        }

        let logins = family.loginWrites
        guard !logins.isEmpty, let target = report.writeCharacteristic(for: family) else {
            isConnected = true
            lastError = nil
            onStatusChange?()
            return
        }
        for (step, frame) in logins.enumerated() {
            Timer.scheduledTimer(withTimeInterval: 0.1 * Double(step + 1),
                                 repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    try? self.central.write(frame, to: target)
                    if step == logins.count - 1 {
                        self.isConnected = true
                        self.lastError = nil
                        self.onStatusChange?()
                    }
                }
            }
        }
    }

    /// Points the controller at a device and a family. Does not connect.
    func configure(deviceQuery: String?, family: StripFamily?) {
        self.deviceQuery = deviceQuery
        self.family = family
        onStatusChange?()
    }

    /// Disconnects. These controllers accept one central at a time, so holding
    /// a connection open is holding the strip away from the user's phone.
    func disconnect() {
        endScan()
        flushTimer?.invalidate()
        flushTimer = nil
        pendingColor = nil
        // The non-blocking form: the state is cleared by `onDisconnect`, not
        // by waiting here. `disconnectAndWait` pumps a run loop and belongs to
        // the CLI.
        central.disconnect()
        isConnected = false
        report = nil
        onStatusChange?()
    }

    // MARK: - Colour

    /// Requests a colour, subject to pacing.
    ///
    /// Safe to call at any rate: frames arriving faster than
    /// ``minimumWriteInterval`` coalesce, and only the most recent is sent.
    /// Returns immediately either way.
    func setColor(_ rgb: StripRGB) {
        guard isAvailable else { return }

        let now = Date()
        if let last = lastWriteTime, now.timeIntervalSince(last) < Self.minimumWriteInterval {
            pendingColor = rgb
            scheduleFlush(after: Self.minimumWriteInterval - now.timeIntervalSince(last))
            return
        }
        write(rgb)
    }

    /// Sets power. Not paced — a power change is a user action, not a stream.
    func setPower(on: Bool) {
        guard isAvailable, let family, let report else { return }
        guard let frame = family.powerFrame(on: on, sequence: central.nextSequence()) else {
            return
        }
        do {
            try central.send(frame, as: family, on: report)
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        onStatusChange?()
    }

    private func scheduleFlush(after delay: TimeInterval) {
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: max(0, delay),
                                          repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flushTimer = nil
                if let pending = self.pendingColor {
                    self.pendingColor = nil
                    self.write(pending)
                }
            }
        }
    }

    private func write(_ rgb: StripRGB) {
        guard let family, let report else { return }
        guard let frame = family.colorFrame(rgb, sequence: central.nextSequence()) else { return }
        do {
            try central.send(frame, as: family, on: report)
            lastWriteTime = Date()
            currentColor = rgb
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        onStatusChange?()
    }
}
