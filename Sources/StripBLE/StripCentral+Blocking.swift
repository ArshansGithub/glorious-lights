import Foundation
import CoreBluetooth
import StripProtocol

/// Blocking wrappers, for `gmmk-cli`.
///
/// CoreBluetooth has no synchronous API and needs a live run loop, so these
/// pump the main run loop until a condition holds or a deadline passes. That is
/// the same shape the keyboard's bring-up probes already use in
/// `Sources/gmmk-cli/main.swift`, and it is correct here for the same reason:
/// a command-line tool has one thread, nothing else wants it, and the
/// alternative is a semaphore that would deadlock against callbacks delivered
/// on the very queue it blocked.
///
/// **The app must not use any of these.** Blocking the main thread is exactly
/// what a menu-bar app cannot do; it drives ``StripCentral`` through its
/// callbacks instead.
extension StripCentral {

    /// Pumps the run loop until `condition` holds.
    func wait(for condition: () -> Bool,
              timeout: TimeInterval,
              during label: String) throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() {
            guard Date() < deadline else {
                throw StripBLEError.timedOut(during: label, seconds: timeout)
            }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    /// Pumps the run loop for a fixed interval, letting callbacks land.
    ///
    /// `Thread.sleep` would not do: it stops the run loop that CoreBluetooth
    /// needs to deliver anything, so a sleeping CLI is a deaf one.
    public func idle(for seconds: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: deadline)
        }
    }

    /// Waits for CoreBluetooth to report a usable state.
    ///
    /// The state is `.unknown` for a moment after the manager is created, so
    /// every entry point has to come through here first. An unusable state is
    /// thrown as the specific error it is — permission, powered off, or
    /// unsupported all need different things from the user.
    public func waitForPoweredOn(timeout: TimeInterval = 5) throws {
        try wait(for: { self.state != .unknown && self.state != .resetting },
                 timeout: timeout,
                 during: "waiting for Bluetooth to become available")
        try requirePoweredOn()
    }

    /// Scans for `seconds`, then returns everything seen, strongest signal
    /// first.
    ///
    /// `onEach` fires as devices appear, so a caller can print a live list
    /// rather than making the user watch nothing happen for ten seconds.
    @discardableResult
    public func scan(seconds: TimeInterval,
                     onEach: ((StripScanResult) -> Void)? = nil) throws -> [StripScanResult] {
        try waitForPoweredOn()
        let previous = onDiscover
        onDiscover = { result in
            previous?(result)
            onEach?(result)
        }
        defer {
            stopScan()
            onDiscover = previous
        }
        try startScan()
        idle(for: seconds)
        return discovered.values.sorted { $0.rssi > $1.rssi }
    }

    /// Scans, then picks the one device matching `query`.
    ///
    /// `query` matches a full identifier UUID, or a case-insensitive substring
    /// of the name. A substring matching several devices is an error rather
    /// than a silent pick — writing frames to the wrong strip is the one
    /// mistake this command cannot take back.
    public func findDevice(matching query: String,
                           scanSeconds: TimeInterval) throws -> StripScanResult {
        let results = try scan(seconds: scanSeconds)
        guard !results.isEmpty else {
            throw StripBLEError.noDevicesFound(scanSeconds: scanSeconds)
        }
        if let uuid = UUID(uuidString: query), let match = results.first(
            where: { $0.identifier == uuid }) {
            return match
        }
        let wanted = query.lowercased()
        let matches = results.filter { $0.displayName.lowercased().contains(wanted) }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw StripBLEError.deviceNotFound(query,
                                                   seen: results.map(\.displayName))
        default: throw StripBLEError.ambiguousDevice(
            query, matches: matches.map { "\($0.displayName) (\($0.identifier.uuidString))" })
        }
    }

    /// Connects and discovers everything, returning the full GATT dump.
    public func connectAndDiscover(_ result: StripScanResult,
                                   timeout: TimeInterval = 15) throws -> StripDeviceReport {
        try connect(result)
        try wait(for: { self.isConnected },
                 timeout: timeout,
                 during: "connecting to \(result.displayName)")
        try discoverServices()
        try wait(for: { self.isDiscoveryComplete },
                 timeout: timeout,
                 during: "discovering services on \(result.displayName)")
        guard let report else {
            throw StripBLEError.serviceDiscoveryFailed("no report was built")
        }
        return report
    }

    /// Scan, connect, discover — the whole opening move, in one call.
    public func open(matching query: String,
                     scanSeconds: TimeInterval) throws -> StripDeviceReport {
        try connectAndDiscover(try findDevice(matching: query, scanSeconds: scanSeconds))
    }

    /// Sends a family's connect-time writes and subscribes to notifications.
    ///
    /// Two things happen here, both from the sources rather than from taste:
    /// MELK units ignore every command until their two three-byte login writes
    /// have gone out, and LEDnetWF units are documented as refusing commands
    /// until notifications are enabled. Subscribing happens for every family
    /// because a notification during bring-up is free evidence that the
    /// controller understood something.
    public func prepare(for family: StripFamily, on report: StripDeviceReport) throws {
        if let notify = report.notifyCharacteristic(for: family) {
            subscribe(to: notify)
            // The CCCD write needs a moment to land before the device is
            // considered ready; LEDnetWF's own integration sleeps 0.1s here.
            idle(for: 0.15)
        } else if family.requiresNotifications {
            throw StripBLEError.noWritableCharacteristic(
                family: family, found: report.allCharacteristicUUIDs.map(\.shortDescription))
        }
        guard !family.loginWrites.isEmpty else { return }
        guard let write = report.writeCharacteristic(for: family) else {
            throw StripBLEError.noWritableCharacteristic(
                family: family, found: report.allCharacteristicUUIDs.map(\.shortDescription))
        }
        for frame in family.loginWrites {
            try self.write(frame, to: write)
            idle(for: 0.1)
        }
    }

    /// Writes one family frame, resolving the write characteristic from the
    /// report. Returns the characteristic used and the bytes sent, for logging.
    @discardableResult
    public func send(_ frame: [UInt8],
                     as family: StripFamily,
                     on report: StripDeviceReport) throws -> StripCharacteristicReport {
        guard let target = report.writeCharacteristic(for: family) else {
            throw StripBLEError.noWritableCharacteristic(
                family: family, found: report.allCharacteristicUUIDs.map(\.shortDescription))
        }
        try write(frame, to: target)
        return target
    }

    /// Disconnects and waits for the callback, so the process does not exit
    /// with the link still up.
    public func disconnectAndWait(timeout: TimeInterval = 3) {
        guard isConnected else { return }
        disconnect()
        try? wait(for: { !self.isConnected }, timeout: timeout, during: "disconnecting")
    }
}
