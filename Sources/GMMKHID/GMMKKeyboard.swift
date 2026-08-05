import Foundation
import IOKit
import IOKit.hid
import GMMKProtocol

/// IOHIDManager-based transport for the GMMK v1 lighting protocol.
///
/// Finds the *vendor* HID interface of the keyboard — USB `0x0C45:0x652F`
/// whose device usage pairs include usage page `0xFF1C`, usage `0x92` — opens
/// it non-seizing, and sends 63-byte payloads as Output reports with report
/// ID 4. The boot-keyboard interface is never touched.
///
/// The class is not thread-safe; drive it from one thread (the main thread for
/// an app, the main thread for the CLI). Hot-plug callbacks are delivered on
/// the run loop the instance was started with.
public final class GMMKKeyboard {

    // MARK: - Device identity

    public static let vendorID = 0x0C45
    public static let productID = 0x652F
    /// Vendor-defined usage page of the lighting interface.
    public static let vendorUsagePage = 0xFF1C
    /// Vendor-defined usage of the lighting interface.
    public static let vendorUsage = 0x92
    /// The report ID lighting commands are sent on.
    public static let reportID: CFIndex = CFIndex(GMMKPacket.reportID)

    // MARK: - State

    private let manager: IOHIDManager
    private var device: IOHIDDevice?
    private var isStarted = false
    /// Run loop and mode ``start(on:mode:)`` scheduled on, so ``stop()`` can
    /// unschedule from exactly the same place instead of guessing.
    private var scheduledRunLoop: CFRunLoop?
    private var scheduledMode: CFRunLoopMode = .defaultMode
    /// Backing store for input reports. Heap-allocated and owned for the
    /// lifetime of the instance: IOKit keeps the pointer after registration,
    /// so it must not be a temporary from `withUnsafeMutableBufferPointer`.
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let inputBufferCapacity = 64
    /// The most recent input report, consumed by ``awaitReply(timeout:)``.
    private var latestReply: [UInt8]?

    /// Run-loop mode the device is *also* scheduled in, so ``send(packets:)``
    /// can pump for replies without running anything else.
    ///
    /// Pumping `.defaultMode` from the app's main thread would re-enter UI event
    /// delivery in the middle of a send — a menu action could run while its own
    /// transaction is still going out. A private mode contains exactly one
    /// source: this device's input reports.
    private static let replyMode = CFRunLoopMode("com.gmmklights.hid.reply" as CFString)

    /// Whether a matching device is currently open and ready for ``send(payload:)``.
    public private(set) var isConnected = false

    /// Called when a matching device appears and is successfully opened.
    public var onConnect: (() -> Void)?
    /// Called when the open device is removed.
    public var onDisconnect: (() -> Void)?
    /// Called when a matching device appeared but could not be opened
    /// (typically missing Input Monitoring permission).
    public var onOpenFailure: ((GMMKHIDError) -> Void)?
    /// Called with each Input report (report ID 4) the firmware sends back.
    /// Replies are not required for writes to take effect.
    public var onInputReport: (([UInt8]) -> Void)?

    /// Extra delay inserted between consecutive packets in ``send(packets:)``,
    /// *on top of* the wait for each packet's echo.
    ///
    /// Zero by default: waiting for the echo is itself the pacing, and it is
    /// what the Linux tools get accidentally from their blocking IN read. Raise
    /// it (the CLI's `GMMK_PACKET_DELAY_MS`) only to test timing hypotheses.
    public var interPacketDelay: TimeInterval = 0

    /// How long to wait for one packet's echo before re-sending it.
    public var replyTimeout: TimeInterval = ReplyPacer.defaultReplyTimeout

    /// Transmissions per packet before moving on without an echo.
    public var maxSendAttempts: Int = ReplyPacer.defaultMaxAttempts

    /// Gap between packets once the firmware has stopped answering and
    /// ``send(packets:)`` falls back to blind sending.
    ///
    /// ~350 ms wall-clock gaps were the other pacing observed to make config
    /// writes latch on firmware 1.08. Much slower than reply pacing, which is
    /// why it is the fallback and not the default.
    private static let blindPacingDelay: TimeInterval = 0.350

    /// Called for every packet that was sent ``maxSendAttempts`` times without
    /// the firmware ever answering. The write has probably still landed in
    /// config RAM, but it may not have been applied — worth surfacing in a
    /// bring-up log, not worth failing a transaction over.
    public var onUnacknowledgedPacket: ((_ packetIndex: Int, _ attempts: Int) -> Void)?

    /// Which USB channel carries command packets. `.vendorOutput` is the
    /// documented default (Output report, ID 4, vendor interface). The other
    /// cases are hardware bring-up probes for firmware revisions that only
    /// listen on a different channel.
    public enum TransportProbe: String {
        /// Output report, ID 4, 63-byte payload, vendor interface (default).
        /// Confirmed correct by static analysis of the official editor
        /// (docs/protocol-tkl-notes.md §2.2).
        case vendorOutput = "vendor-output"
        /// Feature report, ID 4, 63-byte payload, vendor interface.
        /// Known to STALL on GMMK 1 firmware; kept only for bring-up notes.
        case vendorFeature = "vendor-feature"

        // A "boot-feature" case (feature reports on the boot-keyboard
        // interface) existed briefly during bring-up and was REMOVED on
        // purpose: that channel is the SN32 ISP-bootloader command door
        // (docs/protocol-tkl-notes.md §4). Never send feature reports to
        // interface 0 — the wrong 8 bytes reboot the board into the
        // bootloader and can lead to a soft-brick.
    }

    /// Bring-up escape hatch; leave at `.vendorOutput` in production.
    public var transportProbe: TransportProbe = .vendorOutput

    public init() {
        // `kIOHIDManagerOptionIndependentDevices` keeps `IOHIDManagerOpen` from
        // being propagated to every VID/PID match — otherwise starting the
        // manager would also open Interface A, the boot keyboard, which the
        // spec forbids. Devices are opened and scheduled by hand instead.
        manager = IOHIDManagerCreate(kCFAllocatorDefault,
                                     IOHIDManagerOptions.independentDevices.rawValue)
        inputBuffer.initialize(repeating: 0, count: inputBufferCapacity)
    }

    deinit {
        stop()
        inputBuffer.deallocate()
    }

    // MARK: - One-shot use (CLI)

    /// Finds and opens the vendor interface synchronously, without hot-plug
    /// callbacks.
    ///
    /// The device is scheduled on the *current* run loop in the private reply
    /// mode and its input-report callback registered, because ``send(packets:)``
    /// paces on those replies and would otherwise wait out a full timeout per
    /// packet. Nothing is scheduled in a public mode, so this does not disturb
    /// a caller that never runs its run loop.
    ///
    /// - Throws: ``GMMKHIDError/deviceNotFound`` or ``GMMKHIDError/openFailed(_:)``.
    public func open() throws {
        if isConnected { return }
        IOHIDManagerSetDeviceMatching(manager, Self.matchingDictionary() as CFDictionary)
        guard let found = Self.findVendorInterface(in: manager) else {
            throw GMMKHIDError.deviceNotFound
        }
        let result = IOHIDDeviceOpen(found, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            throw GMMKHIDError.openFailed(result)
        }
        device = found
        isConnected = true
        registerInputReportCallback(on: found)
        scheduledRunLoop = CFRunLoopGetCurrent()
        IOHIDDeviceScheduleWithRunLoop(found, CFRunLoopGetCurrent(), Self.replyMode.rawValue)
    }

    /// Whether a matching vendor interface is currently attached. Does not open it.
    public static func isDevicePresent() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, matchingDictionary() as CFDictionary)
        return findVendorInterface(in: manager) != nil
    }

    // MARK: - Hot-plug driven use (app)

    /// Schedules the HID manager on `runLoop` and starts delivering matching /
    /// removal callbacks. Opens the device immediately if one is already attached.
    public func start(on runLoop: RunLoop = .current, mode: CFRunLoopMode = .defaultMode) {
        guard !isStarted else { return }
        isStarted = true

        IOHIDManagerSetDeviceMatching(manager, Self.matchingDictionary() as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<GMMKKeyboard>.fromOpaque(context).takeUnretainedValue()
                .handleDeviceMatched(device)
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<GMMKKeyboard>.fromOpaque(context).takeUnretainedValue()
                .handleDeviceRemoved(device)
        }, context)

        let cfRunLoop = runLoop.getCFRunLoop()
        scheduledRunLoop = cfRunLoop
        scheduledMode = mode
        IOHIDManagerScheduleWithRunLoop(manager, cfRunLoop, mode.rawValue)
        // Opens the manager only: with `kIOHIDManagerOptionIndependentDevices`
        // this does not open any matched device.
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            onOpenFailure?(.openFailed(result))
        }
    }

    /// Unschedules the manager, closes the device, and clears connection state.
    public func stop() {
        if let device {
            if let scheduledRunLoop {
                // Both modes the device may have been scheduled in: the caller's
                // (hot-plug path only) and the private reply mode (always).
                if isStarted {
                    IOHIDDeviceUnscheduleFromRunLoop(device, scheduledRunLoop, scheduledMode.rawValue)
                }
                IOHIDDeviceUnscheduleFromRunLoop(device, scheduledRunLoop, Self.replyMode.rawValue)
            }
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            self.device = nil
        }
        isConnected = false
        latestReply = nil
        if isStarted {
            if let scheduledRunLoop {
                IOHIDManagerUnscheduleFromRunLoop(manager, scheduledRunLoop, scheduledMode.rawValue)
            }
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            isStarted = false
        }
        scheduledRunLoop = nil
        scheduledMode = .defaultMode
    }

    // MARK: - Sending

    /// Sends one 63-byte payload as an Output report with report ID 4.
    ///
    /// The payload must **not** include the leading `0x04` report-ID byte —
    /// see ``GMMKPacket``'s payload convention. IOKit takes the ID separately.
    public func send(payload: [UInt8]) throws {
        guard payload.count == GMMKPacket.payloadLength else {
            throw GMMKHIDError.invalidPayloadLength(payload.count)
        }
        guard let device, isConnected else { throw GMMKHIDError.notConnected }

        let reportType: IOHIDReportType
        let reportID: CFIndex
        let bytes: [UInt8]
        switch transportProbe {
        case .vendorOutput:
            reportType = kIOHIDReportTypeOutput
            reportID = Self.reportID
            // Verified on hardware (fw 1.08): macOS does NOT prepend the
            // report ID on this interrupt pipe, and the firmware requires the
            // full 64-byte wire frame. Sending the bare 63-byte payload
            // arrives one byte short: the firmware then echoes an error reply
            // (status 0xFF) *without* an ID prefix, which macOS misparses as
            // phantom keypresses. Always send all 64 bytes, 0x04 first.
            bytes = [GMMKPacket.reportID] + payload
        case .vendorFeature:
            reportType = kIOHIDReportTypeFeature
            reportID = Self.reportID
            bytes = payload
        }

        let result = bytes.withUnsafeBufferPointer { buffer -> IOReturn in
            IOHIDDeviceSetReport(device,
                                 reportType,
                                 reportID,
                                 buffer.baseAddress!,
                                 buffer.count)
        }
        guard result == kIOReturnSuccess else {
            throw GMMKHIDError.setReportFailed(result)
        }
    }

    /// Sends a sequence of payloads (e.g. a whole `START` … `END` transaction),
    /// **waiting for each packet's echo before sending the next**.
    ///
    /// The pacing is not politeness, it is what makes the write take effect.
    /// Firmware 1.08 stores a blindly-bursted config write into config RAM but
    /// does not latch it into the running effect engine; the same packets apply
    /// instantly when each one waits for its echo. Echoes arrive within a few
    /// milliseconds, so a transaction still completes in well under the time a
    /// user would notice. See ``ReplyPacer`` and `docs/protocol-tkl-notes.md`
    /// §13.7.
    ///
    /// A packet the firmware never answers is re-sent up to ``maxSendAttempts``
    /// times and then skipped — ``onUnacknowledgedPacket`` reports it — because
    /// a missed echo does not mean a missed write. A packet the firmware
    /// *rejects* throws ``GMMKHIDError/commandRejected(status:packetIndex:)``.
    ///
    /// If a packet fails part way through a `START` … `END` run, a best-effort
    /// `END` is sent before rethrowing: the `END` is the commit, so aborting
    /// without one leaves the keyboard mid-transaction until it is replugged.
    public func send(packets: [[UInt8]]) throws {
        var sentAny = false
        // Set once the firmware has stopped answering. Waiting the full timeout
        // on every remaining packet would block this thread for
        // packets × attempts × timeout — 17 s for a solid-colour transaction,
        // on the main thread in the app. Once one packet has exhausted its
        // attempts the reply channel is not coming back mid-transaction, so the
        // rest go out on the other pacing that was observed to work: a fixed
        // ~350 ms gap, no waiting.
        var replyChannelIsSilent = false
        do {
            for (index, packet) in packets.enumerated() {
                if index > 0 {
                    let floor = replyChannelIsSilent
                        ? Swift.max(interPacketDelay, Self.blindPacingDelay)
                        : interPacketDelay
                    if floor > 0 { Thread.sleep(forTimeInterval: floor) }
                }
                // The official editor sleeps 10 ms before END (the commit) —
                // docs/protocol-tkl-notes.md §2.6. Match it.
                if index > 0, packet.count == GMMKPacket.payloadLength,
                   packet[2] == GMMKPacket.Command.end, packet[3] == 0 {
                    Thread.sleep(forTimeInterval: 0.010)
                }
                let outcome = try ReplyPacer.send(
                    maxAttempts: replyChannelIsSilent ? 1 : maxSendAttempts,
                    transmit: { [self] in
                        latestReply = nil
                        try send(payload: packet)
                        sentAny = true
                    },
                    awaitReply: { [self] in
                        replyChannelIsSilent ? nil : awaitReply(timeout: replyTimeout)
                    })
                switch outcome {
                case .acknowledged:
                    break
                case .rejected(let status, _):
                    throw GMMKHIDError.commandRejected(status: status, packetIndex: index)
                case .unacknowledged(let attempts):
                    replyChannelIsSilent = true
                    onUnacknowledgedPacket?(index, attempts)
                }
            }
        } catch {
            if sentAny, packets.first == GMMKPacket.start(), packets.last == GMMKPacket.end() {
                try? send(payload: GMMKPacket.end())
            }
            throw error
        }
    }

    /// Blocks until an input report arrives or `timeout` elapses, running only
    /// the private reply mode so nothing else on this run loop is serviced.
    ///
    /// Returns `nil` on timeout. Reports that arrive between sends are consumed
    /// here too: ``latestReply`` is cleared immediately before each
    /// transmission, so a stale echo can never satisfy the next packet's wait.
    private func awaitReply(timeout: TimeInterval) -> [UInt8]? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while latestReply == nil {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            let result = CFRunLoopRunInMode(Self.replyMode, min(remaining, 0.010), true)
            // `.finished` means the mode has no sources — the device is not
            // scheduled here at all, so waiting cannot help. Sleep out the
            // remaining time rather than spinning a hot loop on a live CPU.
            if result == .finished, latestReply == nil {
                Thread.sleep(forTimeInterval: min(remaining, 0.010))
            }
        }
        defer { latestReply = nil }
        return latestReply
    }

    // MARK: - Hot-plug handling

    private func handleDeviceMatched(_ candidate: IOHIDDevice) {
        guard device == nil, Self.isVendorInterface(candidate) else { return }
        let result = IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            onOpenFailure?(.openFailed(result))
            return
        }
        device = candidate
        isConnected = true
        registerInputReportCallback(on: candidate)
        // The manager is created with `kIOHIDManagerOptionIndependentDevices`,
        // so its scheduling is not propagated: schedule the device by hand or
        // its input reports never arrive. Two modes, both on this run loop —
        // the caller's, so handlers see replies during ordinary run-loop
        // running, and the private reply mode, which is the only one
        // `send(packets:)` pumps.
        if let scheduledRunLoop {
            IOHIDDeviceScheduleWithRunLoop(candidate, scheduledRunLoop, scheduledMode.rawValue)
            IOHIDDeviceScheduleWithRunLoop(candidate, scheduledRunLoop, Self.replyMode.rawValue)
        }
        onConnect?()
    }

    private func handleDeviceRemoved(_ removed: IOHIDDevice) {
        guard let device, device == removed else { return }
        self.device = nil
        isConnected = false
        onDisconnect?()
    }

    private func registerInputReportCallback(on device: IOHIDDevice) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device,
            inputBuffer,
            inputBufferCapacity,
            { context, _, _, _, _, report, length in
                guard let context else { return }
                let keyboard = Unmanaged<GMMKKeyboard>.fromOpaque(context).takeUnretainedValue()
                let bytes = Array(UnsafeBufferPointer(start: report, count: length))
                // Recorded unconditionally: `send(packets:)` paces on these,
                // whether or not anyone installed an `onInputReport` handler.
                keyboard.latestReply = bytes
                keyboard.onInputReport?(bytes)
            },
            context)
    }

    // MARK: - Matching

    private static func matchingDictionary() -> [String: Any] {
        [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID,
        ]
    }

    /// Enumerates VID/PID matches and returns the one exposing `(0xFF1C, 0x92)`.
    ///
    /// The usage pair cannot reliably be put in the matching dictionary because
    /// the interface's *primary* usage is the boot-keyboard pair `(1, 6)`; the
    /// vendor pair only appears in `DeviceUsagePairs`. So filter by hand.
    private static func findVendorInterface(in manager: IOHIDManager) -> IOHIDDevice? {
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }
        return set.first(where: isVendorInterface)
    }

    /// True if the device's usage pairs include usage page `0xFF1C` usage `0x92`.
    public static func isVendorInterface(_ device: IOHIDDevice) -> Bool {
        guard let pairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString)
                as? [[String: Any]] else {
            // Fall back to the primary usage if the pairs array is unavailable.
            let page = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int
            let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int
            return page == vendorUsagePage && usage == vendorUsage
        }
        return pairs.contains { pair in
            let page = pair[kIOHIDDeviceUsagePageKey as String] as? Int
            let usage = pair[kIOHIDDeviceUsageKey as String] as? Int
            return page == vendorUsagePage && usage == vendorUsage
        }
    }
}
