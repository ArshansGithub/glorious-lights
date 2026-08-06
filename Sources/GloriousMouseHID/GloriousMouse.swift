import Foundation
import IOKit
import IOKit.hid
import GloriousMouseProtocol

/// IOHIDManager-based transport for the SinoWealth configuration protocol on
/// the wired Glorious Model O / O- (`258A:0036`).
///
/// Finds the *vendor* HID collection — the one whose device usage pairs include
/// usage page `0xFF00`, usage `0x01` — opens it non-seizing, and talks to it
/// with FEATURE reports only. No other collection is ever opened: seizing the
/// interface a mouse actually moves the cursor with is not something to risk on
/// a lighting app. Doc §1.1 **[measured]** records this device's three usage
/// pairs as `(0x01,0x06)`, `(0x0C,0x01)` and `(0xFF00,0x01)`.
///
/// Everything here is synchronous. Unlike the keyboard there is no interrupt
/// channel, no reply pacing and no run-loop scheduling: `SetReport` and
/// `GetReport` are the whole protocol (doc §1.2).
///
/// The class is not thread-safe; drive it from one thread.
public final class GloriousMouse {

    // MARK: - Device identity

    public static let vendorID = GloriousMouseDevice.vendorID
    public static let productID = GloriousMouseDevice.productID
    public static let vendorUsagePage = GloriousMouseDevice.vendorUsagePage
    public static let vendorUsage = GloriousMouseDevice.vendorUsage

    // MARK: - State

    private let manager: IOHIDManager
    private var device: IOHIDDevice?

    /// Whether a matching vendor collection is currently open.
    public private(set) var isConnected = false

    /// Raw byte count `IOHIDDeviceGetReport` reported for the last config read,
    /// before any interpretation — no nulling, no shift correction.
    ///
    /// Doc §11 item 2 asks whether macOS can observe this at all — IOKit takes
    /// the length as an in/out parameter, but whether the value coming back is
    /// the real transfer size or just the buffer size it was handed is
    /// unverified on this device. Recorded verbatim so bring-up can settle it:
    /// a value of 520 here **is** the answer to that question ("IOKit echoed
    /// the buffer size"), and must not be reported as "nothing came back".
    /// `nil` only means no config read has happened yet.
    ///
    /// Use ``lastConfigObservedLength`` for the interpreted value.
    public private(set) var lastConfigTransferLength: Int?

    /// The last config read's transfer length *after* interpretation: `nil`
    /// unless IOKit reported something other than the buffer size or zero and
    /// that something landed inside the documented `[123, 167]` window (doc §3).
    public private(set) var lastConfigObservedLength: Int?

    public init() {
        // `kIOHIDManagerOptionIndependentDevices` keeps `IOHIDManagerOpen` from
        // propagating to every VID/PID match — which would open the pointer
        // collection too. Devices are opened by hand instead. Same reasoning as
        // GMMKKeyboard, and it matters more here: the other collections on this
        // device are the ones carrying real mouse input.
        manager = IOHIDManagerCreate(kCFAllocatorDefault,
                                     IOHIDManagerOptions.independentDevices.rawValue)
    }

    deinit { close() }

    // MARK: - Lifecycle

    /// Finds and opens the vendor collection.
    ///
    /// - Throws: ``GloriousMouseHIDError/deviceNotFound`` or
    ///   ``GloriousMouseHIDError/openFailed(_:)``.
    public func open() throws {
        if isConnected { return }
        IOHIDManagerSetDeviceMatching(manager, Self.matchingDictionary() as CFDictionary)
        guard let found = Self.findVendorInterface(in: manager) else {
            throw GloriousMouseHIDError.deviceNotFound
        }
        let result = IOHIDDeviceOpen(found, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            throw GloriousMouseHIDError.openFailed(result)
        }
        device = found
        isConnected = true
    }

    public func close() {
        if let device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            self.device = nil
        }
        isConnected = false
    }

    /// Whether a matching vendor collection is attached. Does not open it.
    public static func isDevicePresent() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, matchingDictionary() as CFDictionary)
        return findVendorInterface(in: manager) != nil
    }

    // MARK: - Command channel (report 5)

    /// Sends a six-byte command frame — libratbag's `sinowealth_query_write`.
    ///
    /// Every frame passes ``MouseISPGuard`` first. That check is an allow-list:
    /// anything outside the documented safe verbs is refused, because the
    /// bootloader's DFU verb `0x75` lives on this very report (doc §9). It also
    /// pins byte 0 to report `0x05`, so this entry point cannot be used to put
    /// a six-byte payload on the 520-byte config report and bypass
    /// ``writeConfig(_:)``'s length, report-ID and write-marker guards.
    public func send(commandReport report: [UInt8]) throws {
        guard report.count == GloriousMouseDevice.commandReportLength else {
            throw GloriousMouseHIDError.invalidReportLength(
                reportID: GloriousMouseDevice.commandReportID,
                expected: GloriousMouseDevice.commandReportLength,
                got: report.count)
        }
        if let violation = MouseISPGuard.check(commandReport: report) {
            throw GloriousMouseHIDError.ispHazard(violation)
        }
        try setFeature(report, reportID: report[0])
    }

    /// Sends a command and reads its six-byte reply — `sinowealth_query_read`.
    ///
    /// - Throws: ``GloriousMouseHIDError/commandNotEchoed(sent:echoed:)`` when
    ///   byte 1 does not echo the command. For ``MouseCommand/debounce`` that
    ///   means "unsupported on this unit" rather than a transport fault
    ///   (doc §7); use ``debounceMilliseconds()``, which reports it as `nil`.
    public func query(_ command: MouseCommand) throws -> [UInt8] {
        let request = MouseCommandReport.make(command)
        try send(commandReport: request)
        let reply = try getFeature(reportID: GloriousMouseDevice.commandReportID,
                                   length: GloriousMouseDevice.commandReportLength).bytes
        guard MouseCommandReport.replyEchoes(command, in: reply) else {
            throw GloriousMouseHIDError.commandNotEchoed(sent: command.rawValue,
                                                         echoed: reply.count > 1 ? reply[1] : 0)
        }
        return reply
    }

    /// Firmware version string, e.g. `V103` (doc §12 step 2).
    public func firmwareVersion() throws -> String? {
        MouseCommandReport.firmwareVersion(fromReply: try query(.firmwareVersion))
    }

    /// The profile the mouse is currently running.
    public func activeProfile() throws -> MouseProfile? {
        MouseCommandReport.activeProfile(fromReply: try query(.activeProfile))
    }

    /// Debounce time in milliseconds, or `nil` if command `0x1a` is not
    /// supported here — which doc §11 item 4 flags as genuinely open, and which
    /// this read settles non-destructively.
    public func debounceMilliseconds() throws -> Int? {
        let request = MouseCommandReport.readDebounce
        try send(commandReport: request)
        let reply = try getFeature(reportID: GloriousMouseDevice.commandReportID,
                                   length: GloriousMouseDevice.commandReportLength).bytes
        return MouseCommandReport.debounceMilliseconds(fromReply: reply)
    }

    // MARK: - Configuration blob (report 4)

    /// Reads a profile's configuration blob (doc §3).
    ///
    /// Two transfers on two report IDs, in this order and no other: a report-5
    /// `SetFeature` arming the read, then a bare `GetFeature` on report 4.
    /// Skipping the first returns whatever the previous command left armed.
    public func readConfig(profile: MouseProfile = .one) throws -> MouseConfigBlob {
        try send(commandReport: MouseCommandReport.readConfig(profile))

        let read = try getFeature(reportID: GloriousMouseDevice.configReportID,
                                  length: GloriousMouseDevice.configReportLength)
        lastConfigTransferLength = read.rawTransferLength

        // Doc §3's length sanity check, on the only value that can carry it:
        // libratbag rejects a config read outside [123, 167]. A report of 0 or
        // of the buffer size is IOKit telling us nothing (doc §11 item 2), so
        // only a length that is informative *and* too short is an error.
        if let usable = read.usableTransferLength,
           usable < GloriousMouseDevice.configSizeMin {
            throw GloriousMouseHIDError.configReadTooShort(usable)
        }

        var bytes = read.bytes
        bytes[MouseConfigBlob.Offset.reportID] = GloriousMouseDevice.configReportID
        guard bytes[MouseConfigBlob.Offset.command] == profile.rawValue else {
            throw GloriousMouseHIDError.configReadNotEchoed(
                expected: profile.rawValue,
                got: bytes[MouseConfigBlob.Offset.command])
        }

        // Only trust the transfer length when it lands inside the documented
        // window. IOKit reporting back the buffer size it was handed (520) is
        // not an observation of the config size, and treating it as one would
        // put a nonsense write marker on the next write.
        let observed = read.usableTransferLength.flatMap { length -> Int? in
            (GloriousMouseDevice.configSizeMin...GloriousMouseDevice.configSizeMax)
                .contains(length) ? length : nil
        }
        lastConfigObservedLength = observed
        return try MouseConfigBlob(report: bytes, observedReadLength: observed)
    }

    /// Writes a configuration blob back (doc §4).
    ///
    /// The blob write **is** the commit: there is no separate save or apply
    /// command, and the settings survive a replug. The blob must already carry
    /// its write marker — see
    /// ``MouseConfigBlob/preparedForWrite(profile:configSize:)`` — because a
    /// marker of `0x00` means "read" and the device would ignore the write
    /// silently.
    public func writeConfig(_ blob: MouseConfigBlob) throws {
        guard blob.bytes.count == GloriousMouseDevice.configReportLength else {
            throw GloriousMouseHIDError.invalidReportLength(
                reportID: GloriousMouseDevice.configReportID,
                expected: GloriousMouseDevice.configReportLength,
                got: blob.bytes.count)
        }
        guard blob.bytes[MouseConfigBlob.Offset.reportID] == GloriousMouseDevice.configReportID else {
            throw GloriousMouseHIDError.invalidReportLength(
                reportID: blob.bytes[MouseConfigBlob.Offset.reportID],
                expected: GloriousMouseDevice.configReportLength,
                got: blob.bytes.count)
        }
        guard blob.profile != nil else {
            throw GloriousMouseHIDError.configWriteNotAProfile(
                blob.bytes[MouseConfigBlob.Offset.command])
        }
        guard blob.isMarkedForWrite else {
            throw GloriousMouseHIDError.blobNotMarkedForWrite
        }
        if let violation = MouseISPGuard.check(reportID: GloriousMouseDevice.configReportID) {
            throw GloriousMouseHIDError.ispHazard(violation)
        }
        try setFeature(blob.bytes, reportID: GloriousMouseDevice.configReportID)
    }

    // MARK: - Raw transfers

    private func setFeature(_ bytes: [UInt8], reportID: UInt8) throws {
        guard let device, isConnected else { throw GloriousMouseHIDError.notConnected }
        if let violation = MouseISPGuard.check(reportID: reportID) {
            throw GloriousMouseHIDError.ispHazard(violation)
        }
        let result = bytes.withUnsafeBufferPointer { buffer -> IOReturn in
            IOHIDDeviceSetReport(device,
                                 kIOHIDReportTypeFeature,
                                 CFIndex(reportID),
                                 buffer.baseAddress!,
                                 buffer.count)
        }
        guard result == kIOReturnSuccess else {
            throw GloriousMouseHIDError.setReportFailed(reportID: reportID, result)
        }
    }

    private struct FeatureRead {
        /// Always `length` bytes, report ID restored at index 0.
        var bytes: [UInt8]
        /// What IOKit said it transferred, verbatim.
        var rawTransferLength: Int
        /// The same value corrected for a reinstated report-ID byte, or `nil`
        /// when IOKit reported the buffer size or zero — neither of which is an
        /// observation of anything (doc §11 item 2).
        var usableTransferLength: Int?
    }

    /// `GetFeature`, normalising the two shapes macOS may hand back.
    ///
    /// IOKit fills a caller-sized buffer and it is not documented whether the
    /// leading report-ID byte is included for a numbered report. Both sources
    /// this protocol comes from index the buffer *with* the ID at 0, so a reply
    /// that arrives without it is shifted back and the ID reinstated, rather
    /// than having every offset in the file be conditional.
    ///
    /// **The shift decision is made on the report-ID byte alone**, never on the
    /// expected command byte. The buffer is pre-seeded with `reportID` at index
    /// 0, so index 0 still holding it means the device wrote payload from index
    /// 1 (ID included); anything else means the payload started at index 0.
    /// Keying on the command byte instead would (a) miss the shift whenever the
    /// byte that lands at index 1 coincidentally equals the expected command —
    /// silently misaligning every field of a 520-byte blob — and (b) make the
    /// caller's `buf[1]` echo check tautological, since the shift would be the
    /// very thing that put the expected byte there. Doc §2's `-EIO` oracle is
    /// only worth anything if this layer cannot fake it.
    private func getFeature(reportID: UInt8, length: Int) throws -> FeatureRead {
        guard let device, isConnected else { throw GloriousMouseHIDError.notConnected }
        if let violation = MouseISPGuard.check(reportID: reportID) {
            throw GloriousMouseHIDError.ispHazard(violation)
        }

        var buffer = [UInt8](repeating: 0, count: length)
        // Pre-set the report ID the way OpenRGB does; some HID backends read it
        // back out of the buffer rather than the argument.
        buffer[0] = reportID
        var reportLength = CFIndex(length)
        let result = buffer.withUnsafeMutableBufferPointer { pointer -> IOReturn in
            IOHIDDeviceGetReport(device,
                                 kIOHIDReportTypeFeature,
                                 CFIndex(reportID),
                                 pointer.baseAddress!,
                                 &reportLength)
        }
        guard result == kIOReturnSuccess else {
            throw GloriousMouseHIDError.getReportFailed(reportID: reportID, result)
        }

        let rawTransferLength = Int(reportLength)
        // A report equal to the buffer size, or zero, is indistinguishable from
        // "IOKit handed back what it was given", so it is not an observation.
        var usableTransferLength: Int? =
            (rawTransferLength == length || rawTransferLength == 0) ? nil : rawTransferLength

        if buffer.count >= 2, buffer[0] != reportID {
            // The ID was not included: shift right and reinstate it.
            buffer = [reportID] + buffer.dropLast()
            usableTransferLength = usableTransferLength.map { $0 + 1 }
        }
        return FeatureRead(bytes: buffer,
                           rawTransferLength: rawTransferLength,
                           usableTransferLength: usableTransferLength)
    }

    // MARK: - Matching

    private static func matchingDictionary() -> [String: Any] {
        [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID,
        ]
    }

    /// Every VID/PID match exposing `(0xFF00, 0x01)`, in a stable order.
    ///
    /// The usage pair cannot go in the matching dictionary: the vendor pair is
    /// one of three in `DeviceUsagePairs` and need not be the primary. Same
    /// filtering approach as `GMMKKeyboard`.
    ///
    /// `IOHIDManagerCopyDevices` returns an unordered `Set`, so the candidates
    /// are sorted by registry entry ID: two mice, or a unit exposing the vendor
    /// pair on more than one collection, would otherwise be picked between
    /// arbitrarily and differently on each run — and doc §1.1 says the
    /// collection that answers must be found by probing, which this transport
    /// does not do. A stable choice at least makes a failure reproducible.
    static func vendorInterfaces(in manager: IOHIDManager) -> [IOHIDDevice] {
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return set.filter(isVendorInterface).sorted { registryID(of: $0) < registryID(of: $1) }
    }

    /// The IORegistry entry ID: unique per collection and stable for as long as
    /// the device stays plugged in, which is what makes the sort above a
    /// repeatable choice rather than a different arbitrary one each run.
    private static func registryID(of device: IOHIDDevice) -> UInt64 {
        let service = IOHIDDeviceGetService(device)
        guard service != 0 else { return 0 }
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { return 0 }
        return id
    }

    private static func findVendorInterface(in manager: IOHIDManager) -> IOHIDDevice? {
        vendorInterfaces(in: manager).first
    }

    /// How many collections currently match VID/PID *and* `(0xFF00, 0x01)`.
    /// More than one means ``open()``'s choice is a guess: doc §1.1 says the
    /// right collection is the one that answers `05 11 …`, and nothing here
    /// probes for that.
    public static func vendorInterfaceCount() -> Int {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, matchingDictionary() as CFDictionary)
        return vendorInterfaces(in: manager).count
    }

    /// True if the device's usage pairs include usage page `0xFF00` usage `0x01`.
    ///
    /// Note there is **no fall-back to the primary usage** here, unlike the
    /// keyboard's equivalent. A device with no usage-pairs array would be
    /// matched by whatever its primary pair happens to be, and on this device
    /// two of the three measured pairs (doc §1.1) belong to collections that
    /// carry real mouse input. Refusing to match rather than guessing is the
    /// conservative choice; which pair is primary is not recorded anywhere.
    public static func isVendorInterface(_ device: IOHIDDevice) -> Bool {
        guard let pairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString)
                as? [[String: Any]] else {
            return false
        }
        return pairs.contains { pair in
            let page = pair[kIOHIDDeviceUsagePageKey as String] as? Int
            let usage = pair[kIOHIDDeviceUsageKey as String] as? Int
            return page == vendorUsagePage && usage == vendorUsage
        }
    }
}
