import Foundation
import CoreBluetooth
import StripProtocol

/// CoreBluetooth transport for BLE strip controllers.
///
/// Event-driven and callback-based, like ``GloriousMouseHID/GloriousMouse``'s
/// hot-plug mode — the app drives it this way. `gmmk-cli` needs to block
/// instead, and gets that from the run-loop-pumping wrappers in
/// `StripCentral+Blocking.swift` rather than from a second transport.
///
/// ## Run loop
///
/// CoreBluetooth delivers every callback on a dispatch queue, and this class
/// deliberately uses the **main queue** (`CBCentralManager(delegate:queue:nil)`).
/// That makes the app's callbacks arrive on the thread its menu already lives
/// on, and it makes the CLI's blocking waits work by pumping the main run loop.
/// The cost is that a caller must not block the main thread by other means
/// while an operation is in flight.
///
/// ## Not thread-safe
///
/// Drive it from the main thread.
public final class StripCentral: NSObject {

    // MARK: - State

    private var manager: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// Discovered characteristics, so a write can reach the real object from
    /// the value-type report a caller holds.
    private var characteristics: [StripUUID: CBCharacteristic] = [:]

    private(set) public var state: CBManagerState = .unknown
    private(set) public var discovered: [UUID: StripScanResult] = [:]
    private(set) public var report: StripDeviceReport?

    /// Set once services and all their characteristics have arrived.
    private(set) public var isDiscoveryComplete = false
    private var pendingServiceCount = 0

    private(set) public var isConnected = false
    private var connectFailure: StripBLEError?

    /// The LEDnetWF sequence counter. One per connection, incremented on every
    /// frame that carries one; the family ignores it once connected, but a
    /// counter that is right costs nothing and a counter that is wrong is one
    /// more thing to rule out during bring-up.
    private(set) public var sequence: UInt8 = 0

    // MARK: - Callbacks

    public var onStateChange: ((CBManagerState) -> Void)?
    public var onDiscover: ((StripScanResult) -> Void)?
    public var onConnect: (() -> Void)?
    /// Fires on any disconnect, carrying the reason when there was one.
    public var onDisconnect: ((StripBLEError?) -> Void)?
    /// Notification data, with the characteristic it arrived on. During
    /// bring-up this is free evidence: a controller that answers at all is a
    /// controller that recognised something.
    public var onNotification: ((StripUUID, [UInt8]) -> Void)?
    /// Fires once service and characteristic discovery has finished, with the
    /// finished GATT dump.
    ///
    /// This is what makes the class usable from the app: the CLI can afford to
    /// pump the run loop until ``isDiscoveryComplete`` goes true, and a menu-bar
    /// app cannot block its main thread at all, so it needs to be told.
    public var onServicesDiscovered: ((StripDeviceReport) -> Void)?

    public override init() {
        super.init()
        // Constructing the manager is what prompts for Bluetooth permission,
        // so nothing is created until a caller actually wants the radio.
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    deinit { manager?.stopScan() }

    // MARK: - Scanning

    /// Starts scanning. Results arrive through ``onDiscover`` and accumulate in
    /// ``discovered``.
    ///
    /// Scans for everything rather than filtering by service UUID, and that is
    /// deliberate: the ELK controllers advertise the HID service `0x1812`,
    /// which they do not implement, and do **not** advertise `FFF0`, which they
    /// do. A service-filtered scan would miss the single most likely family.
    public func startScan() throws {
        try requirePoweredOn()
        discovered.removeAll()
        manager.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() { manager.stopScan() }

    // MARK: - Connecting

    public func connect(_ result: StripScanResult) throws {
        try requirePoweredOn()
        guard let found = manager.retrievePeripherals(withIdentifiers: [result.identifier]).first
        else {
            throw StripBLEError.deviceNotFound(result.displayName, seen: [])
        }
        manager.stopScan()
        connectFailure = nil
        isDiscoveryComplete = false
        characteristics.removeAll()
        report = nil
        sequence = 0
        found.delegate = self
        peripheral = found
        manager.connect(found, options: nil)
    }

    /// Cancels the connection. Safe to call when not connected.
    ///
    /// CoreBluetooth keeps a connection alive until it is cancelled explicitly
    /// or the process exits, and these controllers accept **one** central at a
    /// time — a connection left open is a strip the phone app cannot reach.
    /// Every exit path in the CLI calls this.
    public func disconnect() {
        if let peripheral { manager.cancelPeripheralConnection(peripheral) }
    }

    /// Starts service discovery. Discovers everything, for the same reason the
    /// scan does.
    public func discoverServices() throws {
        guard let peripheral, isConnected else { throw StripBLEError.notConnected }
        isDiscoveryComplete = false
        peripheral.discoverServices(nil)
    }

    // MARK: - Writing

    /// Writes one frame.
    ///
    /// Write type follows the characteristic's own properties
    /// (``StripCharacteristicReport/writeType``): without-response wherever
    /// allowed, which is what every one of these protocols uses and what keeps
    /// a controller that never answers from stalling the caller.
    public func write(_ bytes: [UInt8], to target: StripCharacteristicReport) throws {
        guard let peripheral, isConnected else { throw StripBLEError.notConnected }
        guard let characteristic = characteristics[target.uuid] else {
            throw StripBLEError.deviceNotFound(target.uuid.shortDescription, seen: [])
        }
        guard let writeType = target.writeType else {
            throw StripBLEError.characteristicNotWritable(target.uuid.shortDescription)
        }
        peripheral.writeValue(Data(bytes), for: characteristic, type: writeType)
    }

    /// Subscribes to notifications, when the characteristic supports them.
    public func subscribe(to target: StripCharacteristicReport) {
        guard let peripheral, isConnected,
              let characteristic = characteristics[target.uuid],
              target.isNotifying else { return }
        peripheral.setNotifyValue(true, for: characteristic)
    }

    /// Returns the current sequence counter and advances it.
    public func nextSequence() -> UInt8 {
        defer { sequence = sequence &+ 1 }
        return sequence
    }

    // MARK: - Helpers

    func requirePoweredOn() throws {
        if let error = StripBLEError.forState(state) { throw error }
        guard state == .poweredOn else { throw StripBLEError.stateNeverResolved(state) }
    }
}

// MARK: - CBCentralManagerDelegate

extension StripCentral: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
        onStateChange?(central.state)
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .compactMap { StripUUID($0.uuidString) }
        let connectable =
            (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true

        let result = StripScanResult(identifier: peripheral.identifier,
                                     name: peripheral.name,
                                     advertisedName: advertisedName,
                                     rssi: RSSI.intValue,
                                     advertisedServiceUUIDs: serviceUUIDs,
                                     isConnectable: connectable)
        discovered[peripheral.identifier] = result
        onDiscover?(result)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        onConnect?()
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        isConnected = false
        connectFailure = .connectFailed(peripheral.name ?? "device",
                                        underlying: error?.localizedDescription)
        onDisconnect?(connectFailure)
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        isConnected = false
        isDiscoveryComplete = false
        characteristics.removeAll()
        self.peripheral = nil
        // A disconnect with no error is the one this project asked for.
        onDisconnect?(error.map {
            .disconnected(peripheral.name ?? "device", underlying: $0.localizedDescription)
        })
    }
}

// MARK: - CBPeripheralDelegate

extension StripCentral: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            connectFailure = .serviceDiscoveryFailed(
                error?.localizedDescription ?? "no services returned")
            isDiscoveryComplete = true
            return
        }
        pendingServiceCount = services.count
        guard pendingServiceCount > 0 else {
            buildReport()
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if let uuid = StripUUID(characteristic.uuid.uuidString) {
                characteristics[uuid] = characteristic
            }
        }
        pendingServiceCount -= 1
        if pendingServiceCount <= 0 { buildReport() }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard error == nil, let data = characteristic.value,
              let uuid = StripUUID(characteristic.uuid.uuidString) else { return }
        onNotification?(uuid, [UInt8](data))
    }

    private func buildReport() {
        guard let peripheral else { return }
        let services: [StripServiceReport] = (peripheral.services ?? []).compactMap { service in
            guard let uuid = StripUUID(service.uuid.uuidString) else { return nil }
            let chars: [StripCharacteristicReport] =
                (service.characteristics ?? []).compactMap { characteristic in
                    guard let cuuid = StripUUID(characteristic.uuid.uuidString) else { return nil }
                    return StripCharacteristicReport(uuid: cuuid,
                                                     properties: characteristic.properties)
                }
            return StripServiceReport(uuid: uuid,
                                      isPrimary: service.isPrimary,
                                      characteristics: chars)
        }
        let scan = discovered[peripheral.identifier]
        let built = StripDeviceReport(identifier: peripheral.identifier,
                                      name: peripheral.name,
                                      advertisedName: scan?.advertisedName,
                                      rssi: scan?.rssi,
                                      advertisedServiceUUIDs: scan?.advertisedServiceUUIDs ?? [],
                                      services: services)
        report = built
        isDiscoveryComplete = true
        onServicesDiscovered?(built)
    }
}
