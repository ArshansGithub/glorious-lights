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

    /// Delay inserted between consecutive packets in ``send(packets:)``.
    ///
    /// The Linux tools throttle naturally by doing a blocking IN read after
    /// every OUT; without that a small pause keeps the firmware's queue happy,
    /// especially during a per-key burst.
    public var interPacketDelay: TimeInterval = 0.002

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

    /// Finds and opens the vendor interface synchronously, without scheduling
    /// a run loop or hot-plug callbacks.
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
                IOHIDDeviceUnscheduleFromRunLoop(device, scheduledRunLoop, scheduledMode.rawValue)
            }
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            self.device = nil
        }
        isConnected = false
        if isStarted {
            if let scheduledRunLoop {
                IOHIDManagerUnscheduleFromRunLoop(manager, scheduledRunLoop, scheduledMode.rawValue)
            }
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            scheduledRunLoop = nil
            scheduledMode = .defaultMode
            isStarted = false
        }
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

        let result = payload.withUnsafeBufferPointer { buffer -> IOReturn in
            IOHIDDeviceSetReport(device,
                                 kIOHIDReportTypeOutput,
                                 Self.reportID,
                                 buffer.baseAddress!,
                                 buffer.count)
        }
        guard result == kIOReturnSuccess else {
            throw GMMKHIDError.setReportFailed(result)
        }
    }

    /// Sends a sequence of payloads (e.g. a whole `START` … `END` transaction),
    /// pausing ``interPacketDelay`` between them.
    ///
    /// If a packet fails part way through a `START` … `END` run, a best-effort
    /// `END` is sent before rethrowing: the `END` is the commit, so aborting
    /// without one leaves the keyboard mid-transaction until it is replugged.
    public func send(packets: [[UInt8]]) throws {
        var sentAny = false
        do {
            for (index, packet) in packets.enumerated() {
                if index > 0, interPacketDelay > 0 {
                    Thread.sleep(forTimeInterval: interPacketDelay)
                }
                try send(payload: packet)
                sentAny = true
            }
        } catch {
            if sentAny, packets.first == GMMKPacket.start(), packets.last == GMMKPacket.end() {
                try? send(payload: GMMKPacket.end())
            }
            throw error
        }
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
        // its input reports never arrive.
        if let scheduledRunLoop {
            IOHIDDeviceScheduleWithRunLoop(candidate, scheduledRunLoop, scheduledMode.rawValue)
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
                guard let handler = keyboard.onInputReport else { return }
                handler(Array(UnsafeBufferPointer(start: report, count: length)))
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
